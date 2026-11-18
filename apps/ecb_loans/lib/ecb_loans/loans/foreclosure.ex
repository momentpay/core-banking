defmodule ECBLoans.Loans.Foreclosure do
  @moduledoc """
  Settling a loan early on a day (`command=foreclosure`), following Fineract's `forecloseLoan` and
  `LoanAccountDomainServiceJpa.foreCloseLoan`.

  What is to be paid on the day is worked out from the schedule as it stands: the interest, fees and penalties of the
  installments due by the day, the share of the running installment that has built up by the day (interest by days),
  and the principal still owed, less what was paid ahead of the day. The schedule is then rewritten: the installments
  due on or after the day become one, ending on the day, that holds all their principal and what has built up; the
  charges that fall due after the day are dropped. The repayments the loan has had are worked out again on that
  schedule, the settling repayment is made, and the loan is closed (obligations met) with the sub-status foreclosed.
  The interest accrued at disbursement is made again for the interest the shortened schedule charges.

  Refused as not supported yet: a loan with charges per installment or on overdue installments, or with a waived
  charge, and a charged-off loan.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Accruals, ChargeOff, Derived, Journal, Repay, Reprocess}
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.DomainRuleViolation

  @supported ~w(transactionDate note externalId locale dateFormat)
  @accrual 10
  @foreclosed 100

  @doc "Settles loan `id` on `transactionDate`."
  @spec foreclose!(struct, integer, Params.t()) :: Result.t()
  def foreclose!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    on = Params.date(p, "transactionDate")
    note = Params.string(p, "note")
    external_id = Params.string(p, "externalId")

    Validation.new("loan")
    |> Validation.param("transactionDate", on)
    |> Validation.not_null()
    |> Validation.param("note", note)
    |> Validation.max_length(1000)
    |> Validation.raise_if_errors!()

    loan = Loans.fetch!(id)
    check_status!(loan)
    check_date!(loan, on)
    ChargeOff.guard!(loan, "Foreclosing a loan")
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    Journal.check_supported!(product, "Foreclosing a loan")

    rows = Loans.installments(id)
    charges = Loans.charges(id)
    check_charges!(charges)
    Repay.unique_external_id!(external_id)

    payable = payable(loan, rows, charges, on)
    balances = overlapping_period(rows, charges, on, loan.currency_digits)

    total =
      Enum.reduce(
        [payable.principal, payable.interest, payable.fees, payable.penalties],
        &Decimal.add/2
      )

    rewrite_schedule!(user, loan, rows, charges, on, balances)

    tx_id =
      Reprocess.run!(user, id,
        new: %{type: 2, date: on, amount: total, payment_detail_id: nil, external_id: external_id}
      )

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^id),
      set: [loan_sub_status_id: @foreclosed, expected_maturedon_date: maturity(id)]
    )

    make_accruals_again!(user, Loans.fetch!(id), product)
    Loans.add_note(id, loan.client_id, note, user.id, nil)

    changes =
      %{
        "dateFormat" => Params.string(p, "dateFormat"),
        "transactionDate" => Params.string(p, "transactionDate")
      }
      |> put_some("externalId", external_id)
      |> Map.merge(%{
        "transactions" => [tx_id],
        "eventAmount" => Decimal.negate(payable.principal)
      })
      |> put_some("note", note && String.trim(note) != "" && note)

    Result.new(
      loan_id: id,
      resource_id: tx_id,
      resource_external_id: external_id,
      changes: changes
    )
  end

  defp put_some(map, _key, value) when value in [nil, false], do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp check_status!(%{loan_status_id: 300}), do: :ok

  defp check_status!(_loan) do
    Validation.new("loan.transaction")
    |> Validation.add_error(
      "error.msg.loan.foreclosure.account.is.not.active",
      "Loan foreclosure is not allowed. Loan Account is not active.",
      "id",
      []
    )
    |> Validation.raise_if_errors!()
  end

  defp check_date!(loan, on) do
    if Date.compare(on, BusinessDate.current()) == :gt do
      refuse!(
        "loan.foreclosure.transaction.date.is.in.future",
        "The transactionDate cannot be in the future.",
        [Date.to_iso8601(on)]
      )
    end

    if Date.compare(on, ChargeOff.last_user_transaction_date(loan)) == :lt do
      refuse!(
        "loan.foreclosure.transaction.date.cannot.before.the.last.transaction.date",
        "The transactionDate cannot be earlier than the last transaction date.",
        [Date.to_iso8601(on)]
      )
    end
  end

  defp refuse!(code, message, args),
    do: raise(DomainRuleViolation, code: code, message: message, args: args)

  defp check_charges!(charges) do
    if Enum.any?(charges, &(&1.time not in [1, 2] or &1.waived == true)) do
      raise DomainRuleViolation,
        code: "error.msg.loan.feature.not.supported.yet",
        message:
          "Foreclosing a loan with charges by installment, on overdue installments or waived is not supported yet by E-CoreBank",
        args: ["charges"]
    end
  end

  # --- what is to be paid ---------------------------------------------------------------------

  @interest_taken [:interest_completed, :interest_waived, :interest_writtenoff]
  @fee_taken [:fee_charges_completed, :fee_charges_waived, :fee_charges_writtenoff]
  @penalty_taken [
    :penalty_charges_completed,
    :penalty_charges_waived,
    :penalty_charges_writtenoff
  ]

  defp payable(loan, rows, charges, on) do
    zero = Decimal.new(0)
    start = %{interest: zero, fees: zero, penalties: zero, ahead: zero}
    acc = Enum.reduce(rows, start, &add_row(&2, &1, charges, on, loan))
    principal = Decimal.sub(nz(loan.principal_outstanding_derived), acc.ahead)
    %{principal: principal, interest: acc.interest, fees: acc.fees, penalties: acc.penalties}
  end

  defp add_row(acc, row, charges, on, loan) do
    cond do
      Date.compare(on, row.due_date) != :lt ->
        %{
          acc
          | interest: Decimal.add(acc.interest, left(row, :interest, @interest_taken)),
            fees: Decimal.add(acc.fees, left(row, :fee_charges, @fee_taken)),
            penalties: Decimal.add(acc.penalties, left(row, :penalty_charges, @penalty_taken))
        }

      Date.compare(on, row.from_date) == :gt ->
        current_period(acc, row, charges, on, loan)

      true ->
        paid =
          [row.interest_completed, row.penalty_charges_completed, row.fee_charges_completed]
          |> Enum.reduce(acc.ahead, &Decimal.add(&2, nz(&1)))

        %{acc | ahead: paid}
    end
  end

  # the share of the running installment built up by the day, less what was paid or waived of it; a surplus counts
  # as paid ahead
  defp current_period(acc, row, charges, on, loan) do
    {interest, fees, penalties} = period_amounts(row, charges, on, loan.currency_digits)
    interest_done = Decimal.add(nz(row.interest_waived), nz(row.interest_completed))
    {fee_done, penalty_done} = charges_done(charges, row, on)

    {interest_left, ahead1} = split(interest, interest_done)
    {fee_left, ahead2} = split(fees, fee_done)
    {penalty_left, ahead3} = split(penalties, penalty_done)

    %{
      acc
      | interest: Decimal.add(acc.interest, interest_left),
        fees: Decimal.add(acc.fees, fee_left),
        penalties: Decimal.add(acc.penalties, penalty_left),
        ahead: acc.ahead |> Decimal.add(ahead1) |> Decimal.add(ahead2) |> Decimal.add(ahead3)
    }
  end

  defp split(built, done) do
    if Decimal.compare(built, done) == :gt,
      do: {Decimal.sub(built, done), Decimal.new(0)},
      else: {Decimal.new(0), Decimal.sub(done, built)}
  end

  defp charges_done(charges, row, on) do
    due = Enum.filter(charges, &due_in_period?(&1, row, on))

    done = fn penalty? ->
      due
      |> Enum.filter(&(&1.penalty == penalty?))
      |> Enum.reduce(Decimal.new(0), fn c, sum ->
        Decimal.add(sum, Decimal.add(nz(c.waived_amount), nz(c.paid)))
      end)
    end

    {done.(false), done.(true)}
  end

  # interest by days (as Fineract works it, in floating point), fees and penalties that fall due in the period
  defp period_amounts(row, charges, on, digits) do
    total_days = Date.diff(row.due_date, row.from_date)
    till_days = Date.diff(on, row.from_date)
    interest = nz(row.interest)

    interest_by_days =
      if Decimal.eq?(interest, 0) do
        Decimal.new(0)
      else
        (Decimal.to_float(interest) / total_days * till_days)
        |> Decimal.from_float()
        |> Decimal.round(digits, :half_even)
      end

    due = Enum.filter(charges, &due_in_period?(&1, row, on))

    sum = fn penalty? ->
      due
      |> Enum.filter(&(&1.penalty == penalty?))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount))
    end

    {interest_by_days, sum.(false), sum.(true)}
  end

  # a charge on a date is due in the period if the date is after its start (the first installment's start counts)
  defp due_in_period?(%{time: 2, due_date: due}, row, on) when not is_nil(due) do
    after_start =
      Date.compare(due, row.from_date) == :gt or (row.installment == 1 and due == row.from_date)

    after_start and Date.compare(due, on) != :gt
  end

  defp due_in_period?(_charge, _row, _on), do: false

  # what the installment that replaces the rest holds besides principal: interest, fees and penalties
  defp overlapping_period(rows, charges, on, digits) do
    zero = Decimal.new(0)

    Enum.find_value(rows, {zero, zero, zero}, fn row ->
      cond do
        on == row.due_date ->
          {nz(row.interest), nz(row.fee_charges), nz(row.penalty_charges)}

        Date.compare(on, row.from_date) == :gt and Date.compare(on, row.due_date) == :lt ->
          period_amounts(row, charges, on, digits)

        true ->
          nil
      end
    end)
  end

  defp left(row, asked, taken) do
    Enum.reduce(taken, nz(Map.fetch!(row, asked)), fn key, acc ->
      Decimal.sub(acc, nz(Map.fetch!(row, key)))
    end)
  end

  defp nz(nil), do: Decimal.new(0)
  defp nz(value), do: value

  # --- the schedule ----------------------------------------------------------------------------

  defp rewrite_schedule!(user, loan, rows, charges, on, {interest, fees, penalties}) do
    now = DateTime.utc_now()
    {gone, kept} = Enum.split_with(rows, &(Date.compare(on, &1.due_date) != :gt))
    principal = Enum.reduce(gone, Decimal.new(0), &Decimal.add(&2, &1.principal))
    start = if kept == [], do: loan.disbursedon_date, else: List.last(kept).due_date
    gone_ids = Enum.map(gone, & &1.id)

    tx_ids =
      TenantRepo.all(from(t in "m_loan_transaction", where: t.loan_id == ^loan.id, select: t.id))

    TenantRepo.delete_all(
      from(m in "m_loan_transaction_repayment_schedule_mapping",
        where: m.loan_transaction_id in ^tx_ids
      )
    )

    TenantRepo.delete_all(from(r in "m_loan_repayment_schedule", where: r.id in ^gone_ids))

    TenantRepo.insert_all("m_loan_repayment_schedule", [
      %{
        loan_id: loan.id,
        installment: length(kept) + 1,
        fromdate: start,
        duedate: on,
        principal_amount: principal,
        interest_amount: interest,
        fee_charges_amount: nil_zero(fees),
        penalty_charges_amount: nil_zero(penalties),
        completed_derived: false,
        recalculated_interest_component: not Enum.any?(gone, &(&1.due_date == on)),
        is_additional: false,
        is_down_payment: false,
        is_re_aged: false,
        created_by: user.id,
        last_modified_by: user.id,
        created_on_utc: now,
        last_modified_on_utc: now
      }
    ])

    # the charges that fall due after the day are dropped
    for c <- charges, c.time == 2, c.due_date != nil, Date.compare(c.due_date, on) == :gt do
      TenantRepo.update_all(from(lc in "m_loan_charge", where: lc.id == ^c.id),
        set: [is_active: false]
      )
    end

    :ok
  end

  # the installment made for the day counts as one the loan ends on only when the day was one that fell due
  defp maturity(loan_id) do
    TenantRepo.one(
      from(r in "m_loan_repayment_schedule",
        where: r.loan_id == ^loan_id and r.recalculated_interest_component == false,
        select: max(r.duedate)
      )
    )
  end

  defp nil_zero(d), do: if(Decimal.eq?(d, 0), do: nil, else: d)

  # --- the accruals ----------------------------------------------------------------------------

  # the interest booked as accrued when the loan was paid out is booked again for what the schedule now charges
  defp make_accruals_again!(user, loan, product) do
    if Accruals.at_disbursement?(product) do
      old =
        TenantRepo.all(
          from(t in "m_loan_transaction",
            where:
              t.loan_id == ^loan.id and t.transaction_type_enum == @accrual and not t.is_reversed and
                t.transaction_date == ^loan.disbursedon_date and
                not is_nil(t.interest_portion_derived),
            select: %{id: t.id, date: t.transaction_date, interest: t.interest_portion_derived}
          )
        )

      for tx <- old, Decimal.compare(tx.interest, loan.interest_charged_derived) != :eq do
        Accruals.take_back!(user, loan, tx)
        Accruals.post!(user, loan, product, loan.disbursedon_date, loan.interest_charged_derived)
      end
    end

    Derived.refresh!(loan.id, user)
    :ok
  end
end
