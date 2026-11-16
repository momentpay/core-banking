defmodule ECBLoans.Loans.Repay do
  @moduledoc """
  A repayment on a loan, following Fineract's `LoanTransactionValidatorImpl.validateNewRepaymentTransaction`,
  `LoanWritePlatformServiceJpaRepositoryImpl.makeLoanRepayment` and the `mifos-standard-strategy` allocation
  (`FineractStyleLoanRepaymentScheduleTransactionProcessor`).

  The money is applied installment by installment, oldest first, paying each one's penalties, then fees, then
  interest, then principal; whatever is left once every installment is paid is an overpayment. An installment
  paid before its due date adds to what was "paid in advance", one paid after it to what was "paid late". A
  loan with nothing left to pay is closed (obligations met), or overpaid when the money ran over.

  A product with accounting on is refused, as for disbursement, until its journal entries are built.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Derived, Disburse, Journal}
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @supported ~w(transactionDate transactionAmount externalId note locale dateFormat paymentTypeId accountNumber
                checkNumber routingCode receiptNumber bankNumber)
  @payment_fields ~w(accountNumber checkNumber routingCode receiptNumber bankNumber)

  @doc "Records a repayment on loan `id`; the result carries the new transaction's id."
  @spec repay!(struct, integer, Params.t()) :: Result.t()
  def repay!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    on = Params.date(p, "transactionDate")
    amount = Params.decimal_with_locale(p, "transactionAmount")
    note = Params.string(p, "note")
    external_id = Params.string(p, "externalId")

    Validation.new("loan.transaction")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("transactionAmount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.param("externalId", external_id)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> payment_details(p)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    active_client!(loan)
    unique_external_id!(external_id)
    payment_detail_id = payment_detail!(p)
    check_status!(loan)
    check_dates!(loan, on)
    check_accounting!(loan)

    tx_id = apply!(user, loan, on, amount, payment_detail_id, external_id)
    Loans.add_note(id, loan.client_id, note, user.id, tx_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: tx_id,
      resource_external_id: external_id,
      changes: changes(p)
    )
  end

  @doc false
  def payment_details(v, p) do
    Enum.reduce(@payment_fields, v, fn name, v ->
      v |> Validation.param(name, Params.string(p, name)) |> Validation.max_length(50)
    end)
  end

  @doc false
  def active_client!(loan) do
    client = Clients.fetch!(loan.client_id)

    if client.status_enum != Clients.status(:active) do
      raise DomainRuleViolation,
        code: "error.msg.client.not.active.exception",
        message: "The Client with id `#{client.id}` is not active",
        args: [client.id]
    end
  end

  @doc false
  def unique_external_id!(nil), do: :ok

  @doc false
  def unique_external_id!(external_id) do
    if TenantRepo.exists?(from(t in "m_loan_transaction", where: t.external_id == ^external_id)) do
      # the failed save of the transaction has used up an id
      TenantRepo.query!("SELECT nextval(pg_get_serial_sequence('m_loan_transaction', 'id'))")

      Validation.new("loan.transaction")
      |> Validation.add_error(
        "validation.msg.loan.transaction.externalId.value.must.be.unique",
        "Failed data validation due to: value.must.be.unique.",
        "externalId",
        [nil, []]
      )
      |> Validation.raise_if_errors!()
    end
  end

  @doc false
  def payment_detail!(p) do
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

  defp check_status!(%{loan_status_id: status}) when status in [300, 600, 700], do: :ok

  defp check_status!(_loan) do
    Validation.new("loan.transaction")
    |> Validation.add_error(
      "error.msg.loan.must.be.active.fully.paid.or.overpaid",
      "Loan must be Active, Fully Paid or Overpaid",
      "id",
      []
    )
    |> Validation.raise_if_errors!()
  end

  @doc false
  def check_dates!(loan, on) do
    if Date.compare(on, BusinessDate.current()) == :gt do
      raise DomainRuleViolation,
        code: "error.msg.loan.transaction.cannot.be.a.future.date",
        message: "The transaction date cannot be in the future.",
        args: [Date.to_iso8601(on)]
    end

    if Date.compare(on, loan.disbursedon_date) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.transaction.cannot.be.before.disbursement.date",
        message:
          "The transaction date cannot be before the loan disbursement date: #{loan.disbursedon_date}",
        args: [Date.to_iso8601(on), Date.to_iso8601(loan.disbursedon_date)]
    end
  end

  defp check_accounting!(loan),
    do: Journal.check_supported!(ECBLoans.LoanProducts.fetch!(loan.product_id), "A repayment")

  # --- the allocation -----------------------------------------------------------------------------

  @doc false
  def apply!(user, loan, on, amount, payment_detail_id, external_id) do
    rows = Loans.installments(loan.id)
    {updates, left, portions} = allocate(rows, on, amount)

    tx = %{
      type: 2,
      date: on,
      amount: amount,
      principal: nil_zero(portions.principal),
      interest: nil_zero(portions.interest),
      fees: nil_zero(portions.fees),
      penalties: nil_zero(portions.penalties),
      overpayment: nil_zero(left),
      balance: balance_after(loan, portions.principal),
      payment_detail_id: payment_detail_id,
      external_id: external_id
    }

    tx_id = Disburse.insert_transaction!(user, loan, tx)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    Journal.repayment!(user, loan, product, Map.put(tx, :id, tx_id))

    save_installments!(updates, tx_id, user)
    after_repayment!(user, loan, on, left)
    tx_id
  end

  @doc """
  Applies `amount` paid on `on` to the installments, oldest first. Returns the changed installments (as
  maps with the new paid amounts, one entry per installment touched with what was paid on it), what was left over,
  and the principal, interest, fee and penalty portions in total.
  """
  @spec allocate([map], Date.t(), Decimal.t()) :: {[map], Decimal.t(), map}
  def allocate(rows, on, amount) do
    zero = Decimal.new(0)

    {touched, left} = Enum.reduce(rows, {[], amount}, &allocate_to(&1, &2, on))

    touched = Enum.reverse(touched)
    sum = fn key -> Enum.reduce(touched, zero, &Decimal.add(&2, Map.fetch!(&1.paid, key))) end

    {touched, left,
     %{
       principal: sum.(:principal),
       interest: sum.(:interest),
       fees: sum.(:fees),
       penalties: sum.(:penalties)
     }}
  end

  defp allocate_to(row, {acc, left}, on) do
    if row.completed == true or Decimal.eq?(left, 0) do
      {acc, left}
    else
      {paid, left} = pay_installment(row, left)

      if Decimal.eq?(paid.total, 0),
        do: {acc, left},
        else: {[Map.merge(row, %{paid: paid, on: on}) | acc], left}
    end
  end

  # penalties, then fees, then interest, then principal
  defp pay_installment(row, left) do
    {penalties, left} =
      take(
        left,
        owed(
          row.penalty_charges,
          row.penalty_charges_completed,
          row.penalty_charges_writtenoff,
          row.penalty_charges_waived
        )
      )

    {fees, left} =
      take(
        left,
        owed(
          row.fee_charges,
          row.fee_charges_completed,
          row.fee_charges_writtenoff,
          row.fee_charges_waived
        )
      )

    {interest, left} =
      take(
        left,
        owed(row.interest, row.interest_completed, row.interest_writtenoff, row.interest_waived)
      )

    {principal, left} =
      take(left, owed(row.principal, row.principal_completed, row.principal_writtenoff, nil))

    total = penalties |> Decimal.add(fees) |> Decimal.add(interest) |> Decimal.add(principal)

    {%{penalties: penalties, fees: fees, interest: interest, principal: principal, total: total},
     left}
  end

  defp owed(nil, _paid, _off, _waived), do: Decimal.new(0)

  defp owed(due, paid, written_off, waived) do
    zero = Decimal.new(0)

    due
    |> Decimal.sub(paid || zero)
    |> Decimal.sub(written_off || zero)
    |> Decimal.sub(waived || zero)
  end

  defp take(left, owed) do
    pay = if Decimal.compare(left, owed) == :gt, do: owed, else: left
    {pay, Decimal.sub(left, pay)}
  end

  defp save_installments!(updates, tx_id, user) do
    now = DateTime.utc_now()

    for u <- updates do
      paid = u.paid
      row = fresh(u.id)
      completed? = complete?(row, paid)
      timing = timing(u.on, u.due_date, paid.total)

      TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.id == ^u.id),
        set:
          [
            completed_derived: completed?,
            obligations_met_on_date: if(completed?, do: u.on, else: row.obligations_met_on),
            last_modified_by: user.id,
            last_modified_on_utc: now
          ] ++
            optional(:principal_completed_derived, true, row.principal_completed, paid.principal) ++
            optional(:interest_completed_derived, true, row.interest_completed, paid.interest) ++
            optional(
              :fee_charges_completed_derived,
              row.fee_charges,
              row.fee_charges_completed,
              paid.fees
            ) ++
            optional(
              :penalty_charges_completed_derived,
              row.penalty_charges,
              row.penalty_charges_completed,
              paid.penalties
            ) ++
            timing_set(timing, row, paid)
      )

      TenantRepo.insert_all("m_loan_transaction_repayment_schedule_mapping", [
        %{
          loan_transaction_id: tx_id,
          loan_repayment_schedule_id: u.id,
          amount: paid.total,
          principal_portion_derived: nil_zero(paid.principal),
          interest_portion_derived: nil_zero(paid.interest),
          fee_charges_portion_derived: nil_zero(paid.fees),
          penalty_charges_portion_derived: nil_zero(paid.penalties)
        }
      ])
    end

    :ok
  end

  defp fresh(id),
    do:
      TenantRepo.one(
        from(r in "m_loan_repayment_schedule",
          where: r.id == ^id,
          select: %{
            principal: r.principal_amount,
            principal_completed: r.principal_completed_derived,
            interest: r.interest_amount,
            interest_completed: r.interest_completed_derived,
            fee_charges: r.fee_charges_amount,
            fee_charges_completed: r.fee_charges_completed_derived,
            penalty_charges: r.penalty_charges_amount,
            penalty_charges_completed: r.penalty_charges_completed_derived,
            obligations_met_on: r.obligations_met_on_date,
            paid_in_advance: r.total_paid_in_advance_derived,
            paid_late: r.total_paid_late_derived
          }
        )
      )

  # an installment is complete when what is still owed on it is nothing
  defp complete?(row, paid) do
    zero = Decimal.new(0)

    [
      owed(row.principal, row.principal_completed, nil, nil) |> Decimal.sub(paid.principal),
      owed(row.interest, row.interest_completed, nil, nil) |> Decimal.sub(paid.interest),
      owed(row.fee_charges, row.fee_charges_completed, nil, nil) |> Decimal.sub(paid.fees),
      owed(row.penalty_charges, row.penalty_charges_completed, nil, nil)
      |> Decimal.sub(paid.penalties)
    ]
    |> Enum.all?(&(Decimal.compare(&1, zero) != :gt))
  end

  defp timing(on, due, total) do
    cond do
      Decimal.eq?(total, 0) -> :none
      Date.compare(on, due) == :lt -> :advance
      Date.compare(on, due) == :gt -> :late
      true -> :none
    end
  end

  defp timing_set(:advance, row, paid),
    do: [total_paid_in_advance_derived: add(row.paid_in_advance, paid.total)]

  defp timing_set(:late, row, paid), do: [total_paid_late_derived: add(row.paid_late, paid.total)]
  defp timing_set(:none, _row, _paid), do: []

  defp optional(_key, nil, _done, _paid), do: []

  defp optional(key, _due, done, paid),
    do: if(Decimal.eq?(paid, 0), do: [], else: [{key, add(done, paid)}])

  defp add(nil, paid), do: paid
  defp add(done, paid), do: Decimal.add(done, paid)
  defp nil_zero(d), do: if(Decimal.eq?(d, 0), do: nil, else: d)

  # the principal still owed after this repayment
  defp balance_after(loan, principal_paid) do
    repaid =
      TenantRepo.one(
        from(t in "m_loan_transaction",
          where: t.loan_id == ^loan.id and t.transaction_type_enum == 2 and not t.is_reversed,
          select: sum(t.principal_portion_derived)
        )
      ) || Decimal.new(0)

    loan.principal_amount |> Decimal.sub(repaid) |> Decimal.sub(principal_paid)
  end

  @doc false
  def after_repayment!(user, loan, on, left) do
    Derived.refresh!(loan.id, user)
    status = status_after(loan, left)
    overpaid = overpaid_total(loan.id)

    set =
      [
        loan_status_id: status,
        total_overpaid_derived: if(Decimal.eq?(overpaid, 0), do: nil, else: overpaid)
      ] ++
        case status do
          600 ->
            [closedon_date: on, overpaidon_date: nil, maturedon_date: on]

          700 ->
            [overpaidon_date: overpaid_on(loan, on), closedon_date: nil, closedon_userid: nil] ++
              maturity(loan)

          _ ->
            [
              closedon_date: nil,
              closedon_userid: nil,
              overpaidon_date: nil,
              maturedon_date: loan.expected_maturedon_date
            ]
        end

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan.id), set: set)
    :ok
  end

  # Fineract clears the actual maturity date when a loan becomes overpaid and sets it again on the next repayment
  defp maturity(%{loan_status_id: 700} = loan), do: [maturedon_date: loan.expected_maturedon_date]
  defp maturity(_loan), do: [maturedon_date: nil]

  defp status_after(loan, left) do
    refreshed = Loans.fetch!(loan.id)

    cond do
      Decimal.compare(overpaid_total(loan.id), 0) == :gt or Decimal.compare(left, 0) == :gt -> 700
      Decimal.eq?(refreshed.total_outstanding_derived, 0) -> 600
      true -> 300
    end
  end

  defp overpaid_on(%{overpaidon_date: nil}, on), do: on
  defp overpaid_on(%{overpaidon_date: date}, _on), do: date

  defp overpaid_total(loan_id) do
    TenantRepo.one(
      from(t in "m_loan_transaction",
        where: t.loan_id == ^loan_id and t.transaction_type_enum == 2 and not t.is_reversed,
        select: sum(t.overpayment_portion_derived)
      )
    ) || Decimal.new(0)
  end

  @doc false
  def changes(p) do
    %{
      "transactionDate" => Params.string(p, "transactionDate"),
      "transactionAmount" => to_string(Params.value(p, "transactionAmount")),
      "locale" => Params.string(p, "locale"),
      "dateFormat" => Params.string(p, "dateFormat")
    }
    |> put_text(p, "note")
    |> put_text(p, "externalId")
    |> put_payment(p)
  end

  defp put_text(changes, p, name) do
    case Params.string(p, name) do
      value when value in [nil, ""] -> changes
      value -> Map.put(changes, name, value)
    end
  end

  defp put_payment(changes, p) do
    changes =
      case ECBPlatform.Json.long(p, "paymentTypeId") do
        nil -> changes
        id -> Map.put(changes, "paymentTypeId", id)
      end

    Enum.reduce(@payment_fields, changes, &put_text(&2, p, &1))
  end
end
