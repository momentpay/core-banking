defmodule ECBLoans.Loans.Corrections do
  @moduledoc """
  Changing what has happened on a loan: undoing or adjusting a repayment (or a waiver), waiving interest,
  writing the loan off, and undoing its disbursement. Follows Fineract's `LoanWritePlatformServiceJpaRepositoryImpl`
  (`adjustLoanTransaction`, `waiveInterestOnLoan`, `writeOff`, `undoLoanDisbursal`).

  Fineract works every later transaction out again when an earlier one is changed; so does `ECBLoans.Loans.Reprocess`.
  What it cannot work out again (a write-off after the transaction, a waiver replaced by another amount) is refused
  with a plain "not supported yet", never half done.
  """
  import Ecto.Query

  alias ECBLoans.Loans

  alias ECBLoans.Loans.{
    Accruals,
    ChargeOff,
    ChargeRows,
    Counters,
    Derived,
    Disburse,
    Journal,
    Repay,
    Reprocess,
    Transitions
  }

  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}

  @waive_interest 4
  @credit_balance_refund 20
  @write_off 6

  @adjust_supported ~w(transactionDate transactionAmount externalId note locale dateFormat paymentTypeId
                       accountNumber checkNumber routingCode receiptNumber bankNumber)
  @waive_supported ~w(transactionDate transactionAmount note locale dateFormat externalId)
  @write_off_supported ~w(transactionDate note locale dateFormat writeoffReasonId externalId)

  # --- undo and adjust ----------------------------------------------------------------------------

  @doc """
  Undoes repayment or waiver `tid` of loan `id` (an amount of nothing) or replaces it with a repayment of the
  amount asked for.
  """
  @spec adjust!(struct, integer, integer, Params.t()) :: Result.t()
  def adjust!(user, id, tid, %Params{} = p) do
    Params.check_supported!(p, @adjust_supported)
    on = Params.date(p, "transactionDate")
    amount = Params.decimal_with_locale(p, "transactionAmount")
    note = Params.string(p, "note")

    Validation.new("loan.transaction")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("transactionAmount", amount)
    |> Validation.not_null()
    |> Validation.zero_or_positive_amount()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Repay.payment_details(p)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    tx = transaction!(id, tid)
    check_not_foreclosed!(loan)
    ChargeOff.guard_change!(loan, tx, amount)
    check_adjustable!(loan, tx)

    if tx.transaction_type_enum == 24 and not Decimal.eq?(amount, 0),
      do: Repay.refuse_not_supported!("Replacing a charge refund", "transactionId")

    Repay.check_no_later_refund!(loan, tx.transaction_date, tx.transaction_type_enum, "reversed")
    refuse_if_later!(loan, tx)
    check_accounting!(loan, "Changing a repayment")

    new_id =
      if later_standing?(loan, tx) do
        adjust_with_later!(user, loan, p, on, amount, tx)
      else
        unapply!(user, loan, tx)
        new_id = replace!(user, Loans.fetch!(id), p, on, amount, tx)
        Journal.reverse!(user, Loans.fetch!(id), tx.id, tx.transaction_date)
        new_id
      end

    Loans.add_note(id, loan.client_id, note, user.id, new_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: new_id,
      resource_external_id:
        if(Decimal.eq?(amount, 0), do: tx.external_id, else: Params.string(p, "externalId")),
      changes: Repay.changes(p)
    )
  end

  defp check_not_foreclosed!(%{loan_status_id: 600, loan_sub_status_id: 100} = loan) do
    raise DomainRuleViolation,
      code: "loan.cannot.be.reopened.as.it.is.foreclosured",
      message: "The loan cannot reopened as it is foreclosed.",
      args: [loan.id]
  end

  defp check_not_foreclosed!(_loan), do: :ok

  defp transaction!(loan_id, tid) do
    Loans.transaction(loan_id, tid) ||
      raise ResourceNotFound,
        code: "error.msg.loan.transaction.id.invalid",
        message:
          "Transaction with identifier #{tid} does not exist for loan with identifier #{loan_id}.",
        args: [tid, loan_id]
  end

  defp check_adjustable!(loan, tx) do
    if loan.loan_status_id == Loans.status(:written_off) do
      raise DomainRuleViolation,
        code: "error.msg.loan.written.off.update.not.allowed",
        message: "Loan transaction: #{tx.id} update not allowed as loan status is written off",
        args: [tx.id]
    end

    if tx.is_reversed or
         tx.transaction_type_enum not in [@waive_interest, @credit_balance_refund | Repay.types()] do
      raise DomainRuleViolation,
        code:
          "error.msg.loan.transaction.adjustment.is.only.allowed.to.repayment.or.waiver.or.creditbalancerefund.or.capitalizedIncome.or.capitalizedIncomeAdjustment.or.buyDownFee.or.buyDownFeeAdjustment.or.chargeback.transactions",
        message:
          "Only (non-reversed) transactions of type repayment, waiver, accrual, credit balance refund, capitalized income, capitalized income adjustment, buy down fee, buy down fee adjustment or chargeback can be adjusted.",
        args: []
    end
  end

  # a write-off after the transaction cannot be worked out again yet
  defp refuse_if_later!(loan, tx) do
    later =
      loan.id
      |> Loans.transactions()
      |> Enum.any?(
        &(&1.transaction_type_enum == @write_off and not &1.is_reversed and
            {&1.transaction_date, &1.id} > {tx.transaction_date, tx.id})
      )

    if later do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "Changing a transaction that has a write-off after it is not supported yet by E-CoreBank",
        args: ["transactionId"]
    end
  end

  # whether repayments or waivers stand after the transaction, which would pay something else without it
  defp later_standing?(loan, tx) do
    loan.id
    |> Loans.transactions()
    |> Enum.any?(
      &(&1.transaction_type_enum in [@waive_interest | Repay.types()] and not &1.is_reversed and
          &1.id != tx.id and {&1.transaction_date, &1.id} > {tx.transaction_date, tx.id})
    )
  end

  # the transaction no longer counts, a new repayment (if any) takes its place and what stands after is worked out
  # again; the new repayment is saved first, then the transaction it replaces is reversed in the books
  defp adjust_with_later!(user, loan, p, on, amount, tx) do
    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
      set: [
        is_reversed: true,
        manually_adjusted_or_reversed: true,
        reversed_on_date: BusinessDate.current(),
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    new_id =
      if Decimal.eq?(amount, 0) do
        Reprocess.run!(user, loan.id)
        Journal.reverse!(user, loan, tx.id, tx.transaction_date)
        tx.id
      else
        new = new_repayment!(loan, p, on, amount, tx)
        Reprocess.run!(user, loan.id, new: new, first: true, reverse: tx)
      end

    Accruals.reprocess!(user, loan.id)
    new_id
  end

  defp check_accounting!(loan, what),
    do: Journal.check_supported!(ECBLoans.LoanProducts.fetch!(loan.product_id), what)

  # a repayment of nothing just takes the transaction back; otherwise a new repayment takes its place
  defp replace!(user, loan, p, on, amount, tx) do
    if Decimal.eq?(amount, 0) do
      tx.id
    else
      new = new_repayment!(loan, p, on, amount, tx)
      Repay.apply!(user, loan, on, amount, new.payment_detail_id, new.external_id, new.type)
    end
  end

  # what a replacement repayment is made of, once it has been checked
  defp new_repayment!(loan, p, on, amount, tx) do
    if tx.transaction_type_enum in [@waive_interest, @credit_balance_refund] do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "Replacing a waiver or a credit balance refund with another amount is not supported yet by E-CoreBank",
        args: ["transactionAmount"]
    end

    external_id = Params.string(p, "externalId")
    adjusted_external_id!(external_id)
    payment_detail_id = Repay.payment_detail!(p)
    Repay.check_dates!(loan, on)

    %{
      type: tx.transaction_type_enum,
      date: on,
      amount: amount,
      payment_detail_id: payment_detail_id,
      external_id: external_id
    }
  end

  # a new transaction cannot take an external id another already has; the failed save has used up an id
  defp adjusted_external_id!(nil), do: :ok

  defp adjusted_external_id!(external_id) do
    if TenantRepo.exists?(from(t in "m_loan_transaction", where: t.external_id == ^external_id)) do
      TenantRepo.query!("SELECT nextval(pg_get_serial_sequence('m_loan_transaction', 'id'))")

      raise ECBPlatform.Errors.DataIntegrity,
        code: "error.msg.data.integrity.issue",
        message: "The request caused a data integrity issue to be fired by the database.",
        parameter: nil,
        args: []
    end
  end

  # --- undoing the effect of a transaction on the schedule ---------------------------------------

  defp unapply!(user, loan, tx) do
    rows = Map.new(Loans.installments(loan.id), &{&1.id, &1})

    for m <- mappings(tx.id) do
      row = Map.fetch!(rows, m.schedule_id)

      TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.id == ^m.schedule_id),
        set: unapplied(row, m, tx)
      )
    end

    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
      set: [
        is_reversed: true,
        manually_adjusted_or_reversed: true,
        reversed_on_date: BusinessDate.current(),
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    Derived.refresh!(loan.id, user)
    ChargeRows.sync_paid!(loan.id)
    Accruals.reprocess!(user, loan.id)
    Repay.after_repayment!(user, Loans.fetch!(loan.id), tx.transaction_date, Decimal.new(0))
  end

  defp mappings(tx_id) do
    TenantRepo.all(
      from(m in "m_loan_transaction_repayment_schedule_mapping",
        where: m.loan_transaction_id == ^tx_id,
        order_by: m.id,
        select: %{
          schedule_id: m.loan_repayment_schedule_id,
          amount: m.amount,
          principal: m.principal_portion_derived,
          interest: m.interest_portion_derived,
          fees: m.fee_charges_portion_derived,
          penalties: m.penalty_charges_portion_derived
        }
      )
    )
  end

  defp unapplied(row, m, %{transaction_type_enum: type} = tx) when type != @waive_interest do
    [
      principal_completed_derived: less(row.principal_completed, m.principal),
      interest_completed_derived: less(row.interest_completed, m.interest),
      fee_charges_completed_derived: less(row.fee_charges_completed, m.fees),
      penalty_charges_completed_derived: less(row.penalty_charges_completed, m.penalties),
      completed_derived: false,
      obligations_met_on_date: nil
    ] ++ timing(row, m, tx)
  end

  defp unapplied(row, m, %{transaction_type_enum: @waive_interest}) do
    [
      interest_waived_derived: less(row.interest_waived, m.interest),
      completed_derived: false,
      obligations_met_on_date: nil
    ]
  end

  defp timing(row, m, tx) do
    cond do
      Date.compare(tx.transaction_date, row.due_date) == :lt ->
        [total_paid_in_advance_derived: less(row.paid_in_advance, m.amount)]

      Date.compare(tx.transaction_date, row.due_date) == :gt ->
        [total_paid_late_derived: less(row.paid_late, m.amount)]

      true ->
        []
    end
  end

  defp less(nil, _amount), do: nil
  defp less(current, nil), do: current

  defp less(current, amount) do
    left = Decimal.sub(current, amount)
    if Decimal.eq?(left, 0), do: nil, else: left
  end

  # --- waive interest -----------------------------------------------------------------------------

  @doc "Waives `transactionAmount` of the interest still owed on loan `id`, oldest installment first."
  @spec waive_interest!(struct, integer, Params.t()) :: Result.t()
  def waive_interest!(user, id, %Params{} = p) do
    Params.check_supported!(p, @waive_supported)
    on = Params.date(p, "transactionDate")
    amount = Params.decimal_with_locale(p, "transactionAmount")
    note = Params.string(p, "note")

    Validation.new("loan.transaction")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("transactionAmount", amount)
    |> Validation.not_null()
    |> Validation.zero_or_positive_amount()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    ChargeOff.guard_waiver!(loan)

    check_active!(
      loan,
      "error.msg.loan.waive.interest.account.is.not.active",
      "Loan Waive Interest is not allowed. Loan Account is not active."
    )

    Repay.check_dates!(loan, on)
    check_accounting!(loan, "Waiving interest")
    check_waivable!(loan, amount)

    tx_id = make_waiver!(user, loan, on, amount)
    Derived.refresh!(id, user)
    Repay.after_repayment!(user, Loans.fetch!(id), on, Decimal.new(0))
    Loans.add_note(id, loan.client_id, note, user.id, tx_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: tx_id,
      changes: Repay.changes(p)
    )
  end

  defp waived_entries!(user, id, tx_id, on, amount) do
    loan = Loans.fetch!(id)

    Journal.waive_interest!(user, loan, ECBLoans.LoanProducts.fetch!(loan.product_id), %{
      id: tx_id,
      date: on,
      amount: amount,
      interest: amount
    })
  end

  # a waiver dated before later repayments makes them pay something else: they are worked out again
  defp make_waiver!(user, loan, on, amount) do
    if Reprocess.needed?(loan.id, on) do
      new = %{
        type: @waive_interest,
        date: on,
        amount: amount,
        unrecognized: unrecognized_income(loan, on, amount)
      }

      Reprocess.run!(user, loan.id, new: new)
    else
      {tx_id, _} = waive!(user, loan, Loans.installments(loan.id), on, amount)
      waived_entries!(user, loan.id, tx_id, on, amount)
      tx_id
    end
  end

  defp check_active!(%{loan_status_id: 300}, _code, _message), do: :ok

  defp check_active!(_loan, code, message) do
    Validation.new("loan.transaction")
    |> Validation.add_error(code, message, "id", [])
    |> Validation.raise_if_errors!()
  end

  defp check_waivable!(loan, amount) do
    outstanding = loan.interest_outstanding_derived

    if Decimal.compare(amount, outstanding) == :gt do
      raise DomainRuleViolation,
        code: "error.msg.loan.waive.interest.amount.exceeds.total.outstanding.interest",
        message:
          "The amount of interest to waive cannot be greater than total interest outstanding on loan.",
        args: [money(amount, loan), outstanding]
    end
  end

  # Fineract writes the whole `Money` object into this error
  defp money(amount, loan) do
    digits = loan.currency_digits
    amount = Decimal.round(amount, digits)
    multiples = loan.currency_multiplesof || 0

    %{
      "amount" => amount,
      "currency" => %{
        "code" => loan.currency_code,
        "digitsAfterDecimal" => digits,
        "inMultiplesOf" => multiples
      },
      "zero" => Decimal.eq?(amount, 0),
      "currencyCode" => loan.currency_code,
      "currencyData" => %{
        "code" => loan.currency_code,
        "decimalPlaces" => digits,
        "inMultiplesOf" => multiples
      },
      "greaterThanZero" => Decimal.compare(amount, 0) == :gt,
      "mc" => %{"precision" => 19, "roundingMode" => "HALF_EVEN"},
      "amountDefaultedToNullIfZero" => if(Decimal.eq?(amount, 0), do: nil, else: amount),
      "inMultiplesOf" => multiples,
      "lessThanZero" => Decimal.compare(amount, 0) == :lt
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp waive!(user, loan, rows, on, amount) do
    tx_id =
      Disburse.insert_transaction!(user, loan, %{
        type: @waive_interest,
        date: on,
        amount: amount,
        interest: nil_zero(amount),
        unrecognized: unrecognized_income(loan, on, amount),
        balance: if(Decimal.eq?(amount, 0), do: nil, else: loan.principal_outstanding_derived)
      })

    {tx_id, apply_waiver!(tx_id, rows, on, amount)}
  end

  @doc """
  Waives `amount` of the interest owed on the installments `rows`, oldest first, for the waiver transaction
  `tx_id`: the installments and the mapping to the transaction are written. Returns the installments touched.
  """
  @spec apply_waiver!(integer, [map], Date.t(), Decimal.t()) :: [{map, Decimal.t()}]
  def apply_waiver!(tx_id, rows, on, amount) do
    {touched, _left} = Enum.reduce(rows, {[], amount}, &waive_share/2)

    for {row, take} <- Enum.reverse(touched) do
      waived = Decimal.add(row.interest_waived || Decimal.new(0), take)
      completed? = complete_after_waiver?(row, take)

      TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.id == ^row.id),
        set: [
          interest_waived_derived: waived,
          completed_derived: completed?,
          obligations_met_on_date: if(completed?, do: on, else: row.obligations_met_on)
        ]
      )

      TenantRepo.insert_all("m_loan_transaction_repayment_schedule_mapping", [
        %{
          loan_transaction_id: tx_id,
          loan_repayment_schedule_id: row.id,
          amount: take,
          interest_portion_derived: take
        }
      ])
    end

    {tx_id, touched}
  end

  # with periodic accrual, what is waived beyond the interest accrued so far was never booked as income
  defp unrecognized_income(loan, on, amount) do
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    if product.accounting_id == 3 do
      receivable = ECBLoans.Loans.Accruals.receivable_interest(loan.id, on)

      if Decimal.compare(amount, receivable) == :gt,
        do: Decimal.sub(amount, receivable),
        else: nil
    end
  end

  @doc "How much of `amount` can be waived on the installments `rows` (the interest still owed on them, at most)."
  @spec waivable([map], Decimal.t()) :: Decimal.t()
  def waivable(rows, amount) do
    {touched, _left} = Enum.reduce(rows, {[], amount}, &waive_share/2)
    Enum.reduce(touched, Decimal.new(0), fn {_row, take}, sum -> Decimal.add(sum, take) end)
  end

  defp waive_share(row, {acc, left}) do
    owed = interest_owed(row)

    if Decimal.eq?(left, 0) or Decimal.compare(owed, 0) != :gt do
      {acc, left}
    else
      take = if Decimal.compare(left, owed) == :gt, do: owed, else: left
      {[{row, take} | acc], Decimal.sub(left, take)}
    end
  end

  defp interest_owed(row) do
    zero = Decimal.new(0)

    (row.interest || zero)
    |> Decimal.sub(row.interest_completed || zero)
    |> Decimal.sub(row.interest_waived || zero)
    |> Decimal.sub(row.interest_writtenoff || zero)
  end

  defp complete_after_waiver?(row, take) do
    zero = Decimal.new(0)

    interest_left = Decimal.sub(interest_owed(row), take)

    principal_left =
      (row.principal || zero)
      |> Decimal.sub(row.principal_completed || zero)
      |> Decimal.sub(row.principal_writtenoff || zero)

    fees_left = (row.fee_charges || zero) |> Decimal.sub(row.fee_charges_completed || zero)

    penalties_left =
      (row.penalty_charges || zero) |> Decimal.sub(row.penalty_charges_completed || zero)

    Enum.all?(
      [interest_left, principal_left, fees_left, penalties_left],
      &(Decimal.compare(&1, 0) != :gt)
    )
  end

  # --- write-off ----------------------------------------------------------------------------------

  @doc "Writes off everything still owed on loan `id`."
  @spec write_off!(struct, integer, Params.t()) :: Result.t()
  def write_off!(user, id, %Params{} = p) do
    Params.check_supported!(p, @write_off_supported)
    on = Params.date(p, "transactionDate")
    note = Params.string(p, "note")

    Validation.new("loan.transaction")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)
    ChargeOff.guard!(loan, "Writing a loan off")

    check_active!(
      loan,
      "error.msg.loan.writtenoff.account.is.not.active",
      "Loan Written off is not allowed. Loan Account is not active."
    )

    check_write_off_date!(loan, on)
    check_accounting!(loan, "Writing a loan off")

    tx_id = write_off_installments!(user, loan, on)
    Derived.refresh!(id, user)

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [
        loan_status_id: Loans.status(:written_off),
        writtenoffon_date: on,
        closedon_date: on,
        closedon_userid: user.id,
        total_overpaid_derived: nil
      ]
    )

    Loans.add_note(id, loan.client_id, note, user.id, tx_id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: tx_id,
      changes:
        %{
          "transactionDate" => Params.string(p, "transactionDate"),
          "locale" => Params.string(p, "locale"),
          "dateFormat" => Params.string(p, "dateFormat"),
          "closedOnDate" => Params.string(p, "transactionDate"),
          "writtenOffOnDate" => Params.string(p, "transactionDate"),
          "status" => Loans.status_json(Loans.status(:written_off))
        }
        |> put_text("note", note)
    )
  end

  defp put_text(map, _key, nil), do: map

  defp put_text(map, key, text),
    do: if(String.trim(text) == "", do: map, else: Map.put(map, key, text))

  defp check_write_off_date!(loan, on) do
    if Date.compare(on, BusinessDate.current()) == :gt do
      raise DomainRuleViolation,
        code: "error.msg.loan.writeoff.cannot.be.a.future.date",
        message: "The date on which a loan is written off cannot be in the future.",
        args: [Date.to_iso8601(on)]
    end

    if Date.compare(on, loan.disbursedon_date) == :lt do
      raise DomainRuleViolation,
        code: "error.msg.loan.writeoff.cannot.be.before.disbursement.date",
        message:
          "The date on which a loan is written off cannot be before its disbursement date: #{loan.disbursedon_date}",
        args: [Date.to_iso8601(on), Date.to_iso8601(loan.disbursedon_date)]
    end
  end

  defp write_off_installments!(user, loan, on) do
    zero = Decimal.new(0)
    rows = Loans.installments(loan.id)

    off =
      for row <- rows, row.completed != true do
        %{
          row: row,
          principal: left(row.principal, row.principal_completed, row.principal_writtenoff, nil),
          interest:
            left(
              row.interest,
              row.interest_completed,
              row.interest_writtenoff,
              row.interest_waived
            ),
          fees:
            left(
              row.fee_charges,
              row.fee_charges_completed,
              row.fee_charges_writtenoff,
              row.fee_charges_waived
            ),
          penalties:
            left(
              row.penalty_charges,
              row.penalty_charges_completed,
              row.penalty_charges_writtenoff,
              row.penalty_charges_waived
            )
        }
      end

    sum = fn key -> Enum.reduce(off, zero, &Decimal.add(&2, Map.fetch!(&1, key))) end

    {principal, interest, fees, penalties} =
      {sum.(:principal), sum.(:interest), sum.(:fees), sum.(:penalties)}

    total = principal |> Decimal.add(interest) |> Decimal.add(fees) |> Decimal.add(penalties)

    tx = %{
      type: @write_off,
      date: on,
      amount: total,
      principal: nil_zero(principal),
      interest: nil_zero(interest),
      fees: nil_zero(fees),
      penalties: nil_zero(penalties),
      balance: zero
    }

    Counters.remove!(loan)
    Counters.assign!(loan, loan.disbursedon_date)
    Accruals.reprocess!(user, loan.id)
    tx_id = Disburse.insert_transaction!(user, loan, tx)

    for o <- off do
      TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.id == ^o.row.id),
        set:
          [
            completed_derived: true,
            obligations_met_on_date: on,
            principal_writtenoff_derived: add(o.row.principal_writtenoff, o.principal)
          ] ++
            written_off(:interest_writtenoff_derived, o.row.interest_writtenoff, o.interest) ++
            written_off(:fee_charges_writtenoff_derived, o.row.fee_charges_writtenoff, o.fees) ++
            written_off(
              :penalty_charges_writtenoff_derived,
              o.row.penalty_charges_writtenoff,
              o.penalties
            )
      )

      TenantRepo.insert_all("m_loan_transaction_repayment_schedule_mapping", [
        %{
          loan_transaction_id: tx_id,
          loan_repayment_schedule_id: o.row.id,
          amount:
            o.principal
            |> Decimal.add(o.interest)
            |> Decimal.add(o.fees)
            |> Decimal.add(o.penalties),
          principal_portion_derived: nil_zero(o.principal),
          interest_portion_derived: nil_zero(o.interest),
          fee_charges_portion_derived: nil_zero(o.fees),
          penalty_charges_portion_derived: nil_zero(o.penalties)
        }
      ])
    end

    ChargeRows.mark_all_paid!(loan.id)

    Journal.write_off!(
      user,
      Loans.fetch!(loan.id),
      ECBLoans.LoanProducts.fetch!(loan.product_id),
      Map.put(tx, :id, tx_id)
    )

    tx_id
  end

  defp written_off(_key, _current, amount) when amount == nil, do: []

  defp written_off(key, current, amount),
    do: if(Decimal.eq?(amount, 0), do: [], else: [{key, add(current, amount)}])

  defp left(nil, _paid, _off, _waived), do: Decimal.new(0)

  defp left(due, paid, off, waived) do
    zero = Decimal.new(0)
    due |> Decimal.sub(paid || zero) |> Decimal.sub(off || zero) |> Decimal.sub(waived || zero)
  end

  defp add(nil, amount), do: amount
  defp add(current, amount), do: Decimal.add(current, amount)
  defp nil_zero(d), do: if(Decimal.eq?(d, 0), do: nil, else: d)

  # --- undo disbursal -----------------------------------------------------------------------------

  @doc "Takes the payout of loan `id` back: the loan is approved again, with its schedule as submitted."
  @spec undo_disbursal!(struct, integer, Params.t()) :: Result.t()
  def undo_disbursal!(user, id, %Params{} = p) do
    if ECBLoans.Tranches.reversed?(id),
      do:
        ECBLoans.Tranches.unsupported!("undoing the disbursal after the last tranche was undone")

    loan = Loans.fetch!(id)
    Repay.active_client!(loan)

    check_active!(
      loan,
      "error.msg.loan.undo.disbursal.account.is.not.active",
      "Loan Undo disbursal is not allowed. Loan Account is not active."
    )

    refuse_if_paid!(loan)
    check_accounting!(loan, "Undoing a disbursal")

    reverse_disbursal!(user, loan)
    ECBLoans.Tranches.unpay_all!(id)
    Counters.remove!(loan)

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [
        loan_status_id: Loans.status(:approved),
        disbursedon_date: nil,
        disbursedon_userid: nil,
        loan_product_counter: nil,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    Transitions.regenerate!(id, user)
    ChargeRows.reset!(id)
    ECBLoans.Tranches.reset_net!(id)
    Derived.refresh!(id, user)
    Loans.add_note(id, loan.client_id, Params.string(p, "note"), user.id)

    Result.new(
      office_id: loan.client_office_id,
      client_id: loan.client_id,
      loan_id: id,
      resource_id: id,
      resource_external_id: loan.external_id,
      changes:
        %{
          "status" => Loans.status_json(Loans.status(:approved)),
          "actualDisbursementDate" => ""
        }
        |> put_text("note", Params.string(p, "note"))
    )
  end

  defp refuse_if_paid!(loan) do
    paid =
      loan.id
      |> Loans.transactions()
      |> Enum.any?(&(&1.transaction_type_enum not in [1, 5, 9, 10] and not &1.is_reversed))

    if paid do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "Undoing the disbursal of a loan that has repayments is not supported yet by E-CoreBank",
        args: ["transactions"]
    end

    if Enum.any?(Loans.charges(loan.id), &(&1.time == 9)) do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "Undoing the disbursal of a loan that has penalties for overdue installments is not supported yet by E-CoreBank",
        args: ["charges"]
    end
  end

  # the disbursement is reversed in the books; the transactions of the payout are removed with it
  defp reverse_disbursal!(user, loan) do
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    for t <- Loans.transactions(loan.id),
        t.transaction_type_enum in [1, 5, 9, 10],
        not t.is_reversed do
      Journal.reverse!(user, loan, t.id, t.transaction_date)
    end

    ids = for t <- Loans.transactions(loan.id), do: t.id

    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id in ^ids),
      set: [is_reversed: true, reversed_on_date: BusinessDate.current()]
    )

    _ = product
    :ok
  end
end
