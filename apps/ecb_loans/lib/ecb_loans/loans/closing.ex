defmodule ECBLoans.Loans.Closing do
  @moduledoc """
  What can happen to a loan once it is written off, overpaid or given up on, following Fineract's
  `LoanWritePlatformServiceJpaRepositoryImpl` (`makeLoanRepayment` for a recovery, `undoWriteOff`,
  `closeAsRescheduled`, `creditBalanceRefund`):

    * a **recovery payment** is money got back after a loan was written off: it pays nothing on the installments
      (all of it is shown as overpayment), is booked as income from recovery, and is added to what the loan has
      recovered;
    * **undoing the write-off** takes the write-off back and works the repayments and the recoveries out again, so
      that the recoveries now pay the installments they were written off from;
    * **closing as rescheduled** gives an active loan a closing date and the status "closed (rescheduled)", with no
      transaction;
    * a **credit balance refund** pays an overpaid loan's customer back what was overpaid.

  Closing a loan with nothing outstanding (`close`) is not built yet.
  """
  import Ecto.Query

  alias ECBLoans.Loans

  alias ECBLoans.Loans.{
    Accruals,
    ChargeOff,
    Counters,
    Derived,
    Disburse,
    Journal,
    Repay,
    Reprocess
  }

  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, PlatformServiceUnavailable}

  @recovery 8
  @credit_balance_refund 20
  @write_off 6
  @written_off 601

  @payment_supported ~w(transactionDate transactionAmount externalId note locale dateFormat paymentTypeId
                        accountNumber checkNumber routingCode receiptNumber bankNumber)
  @no_amount_supported ~w(transactionDate note locale dateFormat writeoffReasonId externalId)

  # --- recovery payment -------------------------------------------------------------------------

  @doc "Records money recovered on loan `id`, which must be written off."
  @spec recovery_payment!(struct, integer, Params.t()) :: Result.t()
  def recovery_payment!(user, id, %Params{} = p) do
    {on, amount, note, external_id} = payment_request!(p)

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    Repay.unique_external_id!(external_id)
    payment_detail_id = Repay.payment_detail!(p)

    unless loan.loan_status_id == @written_off do
      Validation.new("loan.transaction")
      |> Validation.add_error(
        "error.msg.loan.account.is.not.written.off",
        "Recovery repayments may only be made on loans which are written off",
        "id",
        []
      )
      |> Validation.raise_if_errors!()
    end

    Repay.check_dates!(loan, on)
    check_after_write_off!(loan, on)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    Journal.check_supported!(product, "A recovery payment")

    tx = %{
      type: @recovery,
      date: on,
      amount: amount,
      overpayment: amount,
      payment_detail_id: payment_detail_id,
      external_id: external_id
    }

    tx_id = Disburse.insert_transaction!(user, loan, tx)
    Journal.recovery!(user, loan, product, Map.put(tx, :id, tx_id))
    Derived.refresh!(id, user)
    Loans.add_note(id, loan.client_id, note, user.id, tx_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: tx_id,
      resource_external_id: external_id,
      changes: Repay.changes(p)
    )
  end

  # Fineract works a recovery dated before the write-off out as a repayment that makes the write-off smaller
  defp check_after_write_off!(%{writtenoffon_date: written_off}, on) do
    if written_off && Date.compare(on, written_off) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "A recovery payment dated before the write-off is not supported yet by E-CoreBank",
        args: ["transactionDate"]
    end
  end

  # the date, the amount, the note and the external id of a request for a payment of some kind, once checked
  defp payment_request!(%Params{} = p) do
    Params.check_supported!(p, @payment_supported)
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
    |> Repay.payment_details(p)
    |> Validation.raise_if_errors!()

    {on, amount, note, external_id}
  end

  # --- undo write-off ---------------------------------------------------------------------------

  @doc """
  Takes the write-off of loan `id` back. The loan is active again; its repayments and recoveries are applied
  again, so that a recovery now pays what it was written off from.
  """
  @spec undo_write_off!(struct, integer) :: Result.t()
  def undo_write_off!(user, id) do
    loan = Loans.fetch!(id)
    Repay.active_client!(loan)

    unless loan.loan_status_id == @written_off do
      raise PlatformServiceUnavailable,
        code: "error.msg.loan.status.not.written.off.update.not.allowed",
        message: "Loan :#{id} update not allowed as loan status is not written off",
        args: [id]
    end

    write_off = write_off_transaction!(loan)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    Journal.check_supported!(product, "Undoing a write-off")

    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^write_off.id),
      set: [
        is_reversed: true,
        reversed_on_date: BusinessDate.current(),
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [loan_status_id: Loans.status(:active), closedon_date: nil, closedon_userid: nil]
    )

    Reprocess.run!(user, id)
    Derived.refresh!(id, user)
    Accruals.reprocess!(user, id)
    Journal.reverse!(user, Loans.fetch!(id), write_off.id, write_off.transaction_date)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: write_off.id,
      resource_external_id: write_off.external_id
    )
  end

  defp write_off_transaction!(loan) do
    case loan.id
         |> Loans.transactions()
         |> Enum.find(&(&1.transaction_type_enum == @write_off and not &1.is_reversed)) do
      nil ->
        raise PlatformServiceUnavailable,
          code: "error.msg.loan.write.off.transaction.not.found",
          message: "Loan :#{loan.id} write off transaction not found",
          args: [loan.id]

      tx ->
        tx
    end
  end

  # --- close as rescheduled ---------------------------------------------------------------------

  @doc "Closes the active loan `id` as rescheduled: it gets a closing date and the status closed (rescheduled)."
  @spec close_as_rescheduled!(struct, integer, Params.t()) :: Result.t()
  def close_as_rescheduled!(user, id, %Params{} = p) do
    Params.check_supported!(p, @no_amount_supported)
    on = Params.date(p, "transactionDate")
    note = Params.string(p, "note")

    Validation.new("loan.transaction")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.param("externalId", Params.string(p, "externalId"))
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    ChargeOff.guard!(loan, "Closing a loan as rescheduled")
    check_rescheduled_on_active!(loan)

    Counters.remove!(loan)
    check_reschedule_date!(loan, on)

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [loan_status_id: Loans.status(:rescheduled), closedon_date: on, rescheduledon_date: on]
    )

    Loans.add_note(id, loan.client_id, note, user.id, nil)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: id,
      resource_external_id: loan.external_id,
      changes:
        %{
          "transactionDate" => Params.string(p, "transactionDate"),
          "locale" => Params.string(p, "locale"),
          "dateFormat" => Params.string(p, "dateFormat"),
          "status" => Loans.status_json(Loans.status(:rescheduled)),
          "closedOnDate" => Params.string(p, "transactionDate"),
          "rescheduledOnDate" => Params.string(p, "transactionDate")
        }
        |> put_text("note", note)
    )
  end

  # Fineract lets any other loan through without a change of status but with a closing date; that is not copied
  defp check_rescheduled_on_active!(%{loan_status_id: 300}), do: :ok

  defp check_rescheduled_on_active!(_loan) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message:
        "Closing a loan that is not active as rescheduled is not supported yet by E-CoreBank",
      args: ["transactionDate"]
  end

  defp check_reschedule_date!(loan, on) do
    if Date.compare(on, loan.disbursedon_date) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.close.reschedule.cannot.be.before.submittal.date",
        message:
          "The date on which a loan is rescheduled cannot be before the loan disbursement date: #{loan.disbursedon_date}",
        args: [Date.to_iso8601(on), Date.to_iso8601(loan.disbursedon_date)]
    end

    if Date.compare(on, BusinessDate.current()) == :gt do
      raise DomainRuleViolation,
        code: "error.msg.loan.close.reschedule.cannot.be.a.future.date",
        message: "The date on which a loan is rescheduled cannot be in the future.",
        args: [Date.to_iso8601(on)]
    end
  end

  defp put_text(map, _key, nil), do: map

  defp put_text(map, key, text),
    do: if(String.trim(text) == "", do: map, else: Map.put(map, key, text))

  # --- close ------------------------------------------------------------------------------------

  @doc """
  Closes loan `id`. An active loan can only be closed once nothing is outstanding; what Fineract does for a loan
  with an amount outstanding that is within its arrears tolerance (it writes it off) or with nothing outstanding yet
  open is not built yet, so only the refusals are.
  """
  @spec close!(struct, integer, Params.t()) :: Result.t()
  def close!(_user, id, %Params{} = p) do
    Params.check_supported!(p, @no_amount_supported)
    on = Params.date(p, "transactionDate")
    note = Params.string(p, "note")

    Validation.new("loan.transaction")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.param("externalId", Params.string(p, "externalId"))
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    ChargeOff.guard!(loan, "Closing a loan")

    unless loan.loan_status_id == 300 do
      Validation.new("loan.transaction")
      |> Validation.add_error(
        "error.msg.loan.close.account.is.not.active",
        "Closing Loan Account is not allowed. Loan Account is not Active.",
        "id",
        []
      )
      |> Validation.raise_if_errors!()
    end

    check_closing_date!(loan, on)
    outstanding = loan.total_outstanding_derived || Decimal.new(0)

    if Decimal.compare(outstanding, 0) == :gt and
         Decimal.compare(loan.arrearstolerance_amount || 0, outstanding) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.close.loan.has.money.outstanding",
        message: "A loan with money outstanding cannot be closed",
        args: [
          "#{loan.currency_code} #{Decimal.to_string(Decimal.round(outstanding, loan.currency_digits), :normal)}"
        ]
    end

    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message:
        "Closing a loan whose outstanding amount is within its arrears tolerance, or nothing, is not supported yet by E-CoreBank",
      args: ["transactionDate"]
  end

  defp check_closing_date!(loan, on) do
    if Date.compare(on, loan.disbursedon_date) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.close.cannot.be.before.submittal.date",
        message:
          "The date on which a loan is closed cannot be before the loan disbursement date: #{loan.disbursedon_date}",
        args: [Date.to_iso8601(on), Date.to_iso8601(loan.disbursedon_date)]
    end

    if Date.compare(on, BusinessDate.current()) == :gt do
      raise DomainRuleViolation,
        code: "error.msg.loan.close.cannot.be.a.future.date",
        message: "The date on which a loan is closed cannot be in the future.",
        args: [Date.to_iso8601(on)]
    end
  end

  # --- credit balance refund --------------------------------------------------------------------

  @doc "Pays back `transactionAmount` of what overpaid loan `id` holds."
  @spec credit_balance_refund!(struct, integer, Params.t()) :: Result.t()
  def credit_balance_refund!(user, id, %Params{} = p) do
    {on, amount, note, external_id} = payment_request!(p)

    loan = Loans.fetch!(id)
    ChargeOff.guard!(loan, "A credit balance refund")
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    Journal.check_supported!(product, "A credit balance refund")
    payment_detail_id = Repay.payment_detail!(p)
    check_refundable!(loan, on, amount)

    tx = %{
      type: @credit_balance_refund,
      date: on,
      amount: amount,
      overpayment: amount,
      payment_detail_id: payment_detail_id,
      external_id: external_id
    }

    tx_id = Disburse.insert_transaction!(user, loan, tx)
    Journal.credit_balance_refund!(user, loan, product, Map.put(tx, :id, tx_id))
    Derived.refresh!(id, user)
    Repay.after_repayment!(user, Loans.fetch!(id), on, Decimal.new(0))
    Loans.add_note(id, loan.client_id, note, user.id, tx_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      resource_id: tx_id,
      resource_external_id: external_id,
      changes: Repay.changes(p)
    )
  end

  defp check_refundable!(loan, on, amount) do
    if Date.compare(on, BusinessDate.current()) == :gt do
      raise DomainRuleViolation,
        code: "error.msg.transaction.date.cannot.be.in.the.future",
        message:
          "Loan: #{loan.id}, Credit Balance Refund transaction cannot be created for the future.",
        args: [loan.id]
    end

    unless loan.loan_status_id == 700 do
      Validation.new("loan.transaction")
      |> Validation.add_error(
        "error.msg.loan.credit.balance.refund.account.is.not.overpaid",
        "Loan Credit Balance Refund is not allowed. Loan Account is not Overpaid.",
        "id",
        []
      )
      |> Validation.raise_if_errors!()
    end

    check_after_last_payment!(loan, on)
    check_not_more_than_overpaid!(loan, amount)
  end

  # the refund cannot be dated before the last payment (or refund) that was made
  defp check_after_last_payment!(loan, on) do
    kinds = [20 | Repay.types()]

    last =
      loan.id
      |> Loans.transactions()
      |> Enum.filter(
        &(&1.transaction_type_enum in kinds and not &1.is_reversed and
            Decimal.compare(&1.amount, 0) == :gt)
      )
      |> Enum.max_by(& &1.id, fn -> nil end)

    limit = if last, do: last.transaction_date, else: BusinessDate.current()

    if Date.compare(on, limit) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.refund.failed",
        message:
          "The refund date`#{Date.to_iso8601(on)}`` cannot be before the smallest repayment transaction date",
        args: [Date.to_iso8601(on)]
    end
  end

  defp check_not_more_than_overpaid!(loan, amount) do
    overpaid = loan.total_overpaid_derived || Decimal.new(0)

    if Decimal.compare(amount, overpaid) == :gt do
      Validation.new("loan.transaction")
      |> Validation.add_error(
        "error.msg.transactionAmount.invalid.must.be.>zero.and<=overpaidamount",
        "Transaction Amount (#{Decimal.to_string(Decimal.round(amount, loan.currency_digits), :normal)}) must be > zero and <= Overpaid amount (#{Decimal.to_string(Decimal.round(overpaid, 6), :normal)}).",
        "transactionAmount",
        [amount]
      )
      |> Validation.raise_if_errors!()
    end
  end
end
