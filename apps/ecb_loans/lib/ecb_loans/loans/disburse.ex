defmodule ECBLoans.Loans.Disburse do
  @moduledoc """
  Paying out an approved loan, following Fineract's `LoanTransactionValidatorImpl.validateDisbursement` and
  `LoanWritePlatformServiceJpaRepositoryImpl.disburseLoan`, for a loan paid out in one go.

  The loan becomes active on the date it is disbursed; the repayment schedule is worked out again from that
  date; a disbursement transaction is recorded, its journal entries are posted and, for the products that
  book their interest at disbursement (see `ECBLoans.Loans.Accruals`), an accrual transaction for the whole
  interest on the same date.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Accruals, Counters, Derived, Journal, Transitions}
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @supported ~w(actualDisbursementDate externalId note locale dateFormat transactionAmount netDisbursalAmount
                fixedEmiAmount adjustRepaymentDate paymentTypeId accountNumber checkNumber routingCode
                receiptNumber bankNumber postDatedChecks linkAccountId originators)
  @beyond_core ~w(fixedEmiAmount adjustRepaymentDate postDatedChecks linkAccountId originators)
  @payment_fields ~w(accountNumber checkNumber routingCode receiptNumber bankNumber)

  @doc "Disburses loan `id`; the result carries the id of the disbursement transaction."
  @spec disburse!(struct, integer, Params.t()) :: Result.t()
  def disburse!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    refuse_beyond_core!(p)
    on = Params.date(p, "actualDisbursementDate")
    note = Params.string(p, "note")
    amount = Params.decimal_with_locale(p, "transactionAmount")

    v =
      Validation.new("loan.disbursement")
      |> Validation.param("actualDisbursementDate", on)
      |> Validation.not_null()
      |> Validation.param("note", note)
      |> Validation.max_length(1000)
      |> Validation.param("transactionAmount", amount)
      |> Validation.ignore_if_null()
      |> Validation.positive_amount()
      |> Validation.param(
        "netDisbursalAmount",
        Params.decimal_with_locale(p, "netDisbursalAmount")
      )
      |> Validation.ignore_if_null()
      |> Validation.positive_amount()
      |> payment_details(p)

    loan = Loans.fetch!(id)
    active_client!(loan)
    check_amount!(loan, amount)
    v = check_state(v, loan)
    check_dates!(loan, on)
    Validation.raise_if_errors!(v)

    check_future!(loan, on)
    check_accounting!(loan)
    payment_detail_id = payment_detail!(p)
    paid_out!(user, loan, on, payment_detail_id, Params.string(p, "externalId"))
    Loans.add_note(id, loan.client_id, note, user.id)

    tx_id = disbursement_transaction_id(id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: id,
      subresource_id: tx_id,
      resource_external_id: loan.external_id,
      changes: changes(p, loan, note)
    )
  end

  defp refuse_beyond_core!(p) do
    asked =
      for name <- @beyond_core,
          Params.exists?(p, name),
          Params.value(p, name) not in [nil, []],
          do: name

    if asked != [] do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "These loan disbursement settings are not supported yet by E-CoreBank: " <>
            Enum.join(Enum.sort(asked), ", "),
        args: Enum.sort(asked)
    end
  end

  # the payment details are optional; each text is at most 50 characters
  defp payment_details(v, p) do
    Enum.reduce(@payment_fields, v, fn name, v ->
      v |> Validation.param(name, Params.string(p, name)) |> Validation.max_length(50)
    end)
  end

  defp active_client!(loan) do
    client = Clients.fetch!(loan.client_id)

    if client.status_enum != Clients.status(:active) do
      raise DomainRuleViolation,
        code: "error.msg.client.not.active.exception",
        message: "The Client with id `#{client.id}` is not active",
        args: [client.id]
    end
  end

  # the whole approved principal is paid out in one go
  defp check_amount!(loan, amount) do
    total =
      cond do
        amount == nil -> loan.principal_disbursed_derived
        Decimal.eq?(loan.principal_disbursed_derived, 0) -> amount
        true -> Decimal.add(loan.principal_disbursed_derived, amount)
      end

    if Decimal.compare(total, loan.approved_principal) == :gt do
      raise DomainRuleViolation,
        code: "error.msg.loan.disburse.amount.must.be.less.than.approved.principal",
        message: "Loan can't be disbursed, disburse amount is exceeding approved principal.",
        args: [total, loan.approved_principal]
    end
  end

  defp check_state(v, loan) do
    if loan.loan_status_id == Loans.status(:approved) do
      v
    else
      Validation.add_error(
        v,
        "error.msg.loan.disbursal.account.is.not.approve.not.disbursed.state",
        "Loan Disbursal is not allowed. Loan Account is not in approved and not disbursed state.",
        "id",
        []
      )
    end
  end

  defp check_dates!(_loan, nil), do: :ok

  defp check_dates!(loan, on) do
    ECBLoans.Schedule.Request.check_calendar!(
      Clients.fetch!(loan.client_id),
      loan.expected_disbursedon_date
    )

    if loan.approvedon_date && Date.compare(on, loan.approvedon_date) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.disbursal.cannot.be.before.approval.date",
        message:
          "The date on which a loan is disbursed cannot be before its approval date: #{loan.approvedon_date}",
        args: [Date.to_iso8601(on), Date.to_iso8601(loan.approvedon_date)]
    end
  end

  defp check_future!(loan, on) do
    if Date.compare(on, BusinessDate.current()) == :gt do
      # Fineract has saved the disbursement transaction by now; the failed save has used up an id
      TenantRepo.query!("SELECT nextval(pg_get_serial_sequence('m_loan_transaction', 'id'))")

      raise DomainRuleViolation,
        code: "error.msg.loan.disbursal.cannot.be.a.future.date",
        message:
          "The date on which a loan with identifier : #{loan.account_no} is disbursed cannot be in the future.",
        args: [Date.to_iso8601(on)]
    end
  end

  defp check_accounting!(loan),
    do: Journal.check_supported!(ECBLoans.LoanProducts.fetch!(loan.product_id), "Disbursing")

  # --- the payment ------------------------------------------------------------------------------

  defp payment_detail!(p) do
    type_id = ECBPlatform.Json.long(p, "paymentTypeId")
    given? = Enum.any?(@payment_fields, &(Params.string(p, &1) not in [nil, ""]))

    if type_id == nil and not given?, do: nil, else: insert_payment_detail!(p, type_id)
  end

  defp insert_payment_detail!(p, type_id) do
    if type_id, do: ECBOrg.PaymentTypes.fetch!(type_id)

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_payment_detail",
        [
          %{
            payment_type_id: type_id,
            account_number: Params.string(p, "accountNumber") || "",
            check_number: Params.string(p, "checkNumber") || "",
            receipt_number: Params.string(p, "receiptNumber") || "",
            bank_number: Params.string(p, "bankNumber") || "",
            routing_code: Params.string(p, "routingCode") || ""
          }
        ],
        returning: [:id]
      )

    id
  end

  defp paid_out!(user, loan, on, payment_detail_id, external_id) do
    now = DateTime.utc_now()
    id = loan.id

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [
        loan_status_id: Loans.status(:active),
        disbursedon_date: on,
        disbursedon_userid: user.id,
        last_modified_by: user.id,
        last_modified_on_utc: now
      ]
    )

    tx = %{
      type: 1,
      date: on,
      amount: loan.principal_amount,
      balance: loan.principal_amount,
      payment_detail_id: payment_detail_id,
      external_id: external_id
    }

    Counters.assign!(loan, on)
    tx_id = insert_transaction!(user, loan, tx)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    Journal.disbursement!(user, loan, product, Map.put(tx, :id, tx_id))

    Transitions.regenerate!(id, user, disbursed_on: on)
    Derived.refresh!(id, user)
    Accruals.on_disbursement!(user, Loans.fetch!(id), product, on)
    :ok
  end

  @doc false
  def insert_transaction!(user, loan, t) do
    now = DateTime.utc_now()

    row = %{
      loan_id: loan.id,
      office_id: loan.client_office_id,
      payment_detail_id: t[:payment_detail_id],
      is_reversed: false,
      external_id: t[:external_id],
      transaction_type_enum: t.type,
      transaction_date: t.date,
      amount: t.amount,
      principal_portion_derived: t[:principal],
      interest_portion_derived: t[:interest],
      fee_charges_portion_derived: t[:fees],
      penalty_charges_portion_derived: t[:penalties],
      overpayment_portion_derived: t[:overpayment],
      unrecognized_income_portion: t[:unrecognized],
      outstanding_loan_balance_derived: t[:balance],
      submitted_on_date: BusinessDate.current(),
      manually_adjusted_or_reversed: false,
      created_by: user.id,
      last_modified_by: user.id,
      created_on_utc: now,
      last_modified_on_utc: now,
      version: 1
    }

    {1, [%{id: id}]} = TenantRepo.insert_all("m_loan_transaction", [row], returning: [:id])
    id
  end

  defp disbursement_transaction_id(loan_id) do
    TenantRepo.one(
      from(t in "m_loan_transaction",
        where: t.loan_id == ^loan_id and t.transaction_type_enum == 1 and not t.is_reversed,
        order_by: [desc: t.id],
        limit: 1,
        select: t.id
      )
    )
  end

  defp changes(p, loan, note) do
    %{
      "locale" => Params.string(p, "locale"),
      "dateFormat" => Params.string(p, "dateFormat"),
      "actualDisbursementDate" => Params.string(p, "actualDisbursementDate"),
      "status" => Loans.status_json(Loans.status(:active))
    }
    |> put_payment(p)
    |> then(&if(blank?(note), do: &1, else: Map.put(&1, "note", note)))
    |> then(&if(loan.id, do: &1, else: &1))
  end

  defp put_payment(changes, p) do
    changes =
      case ECBPlatform.Json.long(p, "paymentTypeId") do
        nil -> changes
        id -> Map.put(changes, "paymentTypeId", id)
      end

    Enum.reduce(@payment_fields, changes, fn name, acc ->
      case Params.value(p, name) do
        value when value in [nil, ""] -> acc
        value -> Map.put(acc, name, to_string(value))
      end
    end)
  end

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""
end
