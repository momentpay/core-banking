defmodule ECBLoans.Loans.AccrualJob do
  @moduledoc """
  The job "Add Periodic Accrual Transactions" (`ACC_APTR`), after Fineract's
  `LoanAccrualsProcessingServiceImpl.addPeriodicAccruals`.

  For every active loan of a product with periodic accrual accounting that has interest not accrued yet, up to
  the business date: each installment that has started is accrued on its own, a whole installment when its due
  date is reached and otherwise the share of its interest for the days gone (the interest charged times days
  gone over the days of the installment). An accrual is booked on the due date of its installment or on the
  business date, whichever comes first, and what an installment has accrued is what it charges less what has
  been waived, less what has already been accrued.

  Interest waived under periodic accrual is taken off what is accrued (the part of a waiver that was never
  accrued is kept as unrecognized income). Fees and penalties are not accrued: loans have no charges yet.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Accruals, ChargeRows}
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @accrual 10
  @waive_interest 4

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    till = BusinessDate.current()
    Enum.each(loan_ids(till), &accrue_loan!(user, &1, till))
  end

  # the active loans of periodic accrual products with an installment that has started and has interest to accrue
  defp loan_ids(till) do
    TenantRepo.query!(
      """
      SELECT l.id FROM m_loan l
        JOIN m_product_loan p ON p.id = l.product_id
       WHERE l.loan_status_id = 300 AND p.accounting_type = 3
         AND l.is_npa = false AND l.is_charged_off = false
         AND EXISTS (
           SELECT 1 FROM m_loan_repayment_schedule s
            WHERE s.loan_id = l.id
              AND (COALESCE(s.interest_amount, 0) - COALESCE(s.interest_waived_derived, 0)
                    <> COALESCE(s.accrual_interest_derived, 0)
                   OR COALESCE(s.fee_charges_amount, 0) - COALESCE(s.fee_charges_waived_derived, 0)
                    <> COALESCE(s.accrual_fee_charges_derived, 0)
                   OR COALESCE(s.penalty_charges_amount, 0) - COALESCE(s.penalty_charges_waived_derived, 0)
                    <> COALESCE(s.accrual_penalty_charges_derived, 0))
              AND (s.fromdate < $1
                   OR (s.installment = (SELECT min(x.installment) FROM m_loan_repayment_schedule x WHERE x.loan_id = l.id)
                       AND s.fromdate = $1)))
       ORDER BY l.id
      """,
      [till]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp accrue_loan!(user, loan_id, business_date) do
    loan = Loans.fetch!(loan_id)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)
    rows = Loans.installments(loan_id)
    last = List.last(rows)

    take_back_after!(user, loan, last.due_date)

    till =
      if Date.compare(business_date, last.due_date) == :gt, do: last.due_date, else: business_date

    first = rows |> Enum.map(& &1.installment) |> Enum.min()

    started = Enum.filter(rows, &started?(&1, till, &1.installment == first))

    context = %{
      loan: loan,
      till: till,
      rows: rows,
      slots: Enum.group_by(ChargeRows.slots(loan_id), & &1.installment)
    }

    {made, _unrecognized} =
      Enum.reduce(started, {0, Decimal.new(0)}, fn row, {made, previous} ->
        {accrued?, unrecognized} = accrue_installment!(user, product, context, row, previous)
        {made + if(accrued?, do: 1, else: 0), Decimal.add(previous, unrecognized)}
      end)

    if made > 0 do
      TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan_id),
        set: [accrued_till: till]
      )
    end

    :ok
  end

  # an installment is accrued once the day is not before its period
  defp started?(row, till, true), do: Date.compare(till, row.from_date) != :lt
  defp started?(row, till, false), do: Date.compare(till, row.from_date) == :gt

  # what was accrued after the last due date is taken back
  defp take_back_after!(user, loan, last_due) do
    for tx <- accruals(loan.id),
        Date.compare(tx.date, last_due) == :gt,
        do: Accruals.take_back!(user, loan, tx)

    :ok
  end

  defp accrue_installment!(user, product, %{loan: loan, till: till} = context, row, previous) do
    digits = loan.currency_digits
    interest = interest_till(loan, row, till, digits)
    waiver = waiver(context, row, previous)

    accruable =
      if interest, do: positive(Decimal.sub(interest, waiver.counted)), else: Decimal.new(0)

    accrued = positive(Decimal.sub(accrued_amount(loan, row, till), waiver.by_transactions))
    interest_portion = Decimal.sub(accruable, accrued)

    in_row = Map.get(context.slots, row.installment, [])
    {fees_due, fee_slots} = due_charges(in_row, false, till)
    {penalties_due, penalty_slots} = due_charges(in_row, true, till)
    fee_portion = Decimal.sub(fees_due, row.accrual_fee || Decimal.new(0))
    penalty_portion = Decimal.sub(penalties_due, row.accrual_penalty || Decimal.new(0))

    nothing? =
      Enum.all?([interest_portion, fee_portion, penalty_portion], &Decimal.eq?(&1, 0))

    made =
      if nothing? do
        false
      else
        post_installment!(user, loan, product, row, till, %{
          interest: positive(interest_portion),
          fees: positive(fee_portion),
          penalties: positive(penalty_portion),
          slots: fresh(fee_slots, row.accrual_fee) ++ fresh(penalty_slots, row.accrual_penalty)
        })
      end

    # an installment with nothing new to accrue is left as it is
    unless nothing? do
      Accruals.set_accruals!(row.id, accruable, fees_due, penalties_due)
    end

    {made, waiver.unrecognized}
  end

  # the charges of an installment that have fallen due by `till`, and what they come to
  defp due_charges(slots, penalty?, till) do
    due =
      Enum.filter(slots, &(&1.penalty == penalty? and Date.compare(&1.due, till) != :gt))

    {Enum.reduce(due, Decimal.new(0), &Decimal.add(&2, &1.amount)), due}
  end

  # of the charges that are due, the ones not yet accrued: what was accrued already covers the first ones
  defp fresh(slots, accrued) do
    {fresh, _left} =
      Enum.reduce(slots, {[], accrued || Decimal.new(0)}, fn slot, {fresh, left} ->
        if Decimal.compare(left, slot.amount) != :lt,
          do: {fresh, Decimal.sub(left, slot.amount)},
          else: {fresh ++ [slot], left}
      end)

    fresh
  end

  defp post_installment!(user, loan, product, row, till, portions) do
    amount = portions.interest |> Decimal.add(portions.fees) |> Decimal.add(portions.penalties)

    if Decimal.compare(amount, 0) == :gt do
      date = if Date.compare(row.due_date, till) == :lt, do: row.due_date, else: till

      id =
        Accruals.post!(user, loan, product, date, amount,
          portions: portions,
          installment: row.installment
        )

      for slot <- portions.slots,
          do: ChargeRows.record_paid_by!(id, slot.charge, slot.amount, row.installment)

      true
    else
      false
    end
  end

  # the interest charged on the installment up to `till`: all of it once the due date is reached, otherwise a share
  defp interest_till(loan, row, till, digits) do
    charged = row.interest || Decimal.new(0)

    cond do
      Date.compare(till, row.due_date) != :lt -> charged
      Date.compare(till, row.from_date) != :gt -> nil
      Decimal.eq?(charged, 0) -> Decimal.new(0)
      true -> share(loan, row, charged, till, digits)
    end
  end

  # the share is worked out in floating point and rounded to the currency, as Fineract does
  defp share(loan, row, charged, till, digits) do
    from = latest(row.from_date, loan.interest_calculated_from_date || loan.disbursedon_date)

    if Date.compare(from, row.due_date) != :lt or Date.compare(from, till) != :lt do
      Decimal.new(0)
    else
      per_day = Decimal.to_float(charged) / Date.diff(row.due_date, from)
      Decimal.from_float(per_day * Date.diff(till, from)) |> Decimal.round(digits, :half_even)
    end
  end

  defp latest(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  # a whole installment holds what it has accrued; one under way holds what was accrued within its dates
  defp accrued_amount(loan, row, till) do
    if Date.compare(till, row.due_date) != :lt do
      row.accrual_interest || Decimal.new(0)
    else
      loan.id
      |> accruals()
      |> Enum.filter(
        &(Date.compare(&1.date, row.from_date) == :gt and
            Date.compare(&1.date, row.due_date) != :gt)
      )
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.interest || Decimal.new(0)))
    end
  end

  defp accruals(loan_id) do
    TenantRepo.all(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and t.transaction_type_enum == @accrual and not t.is_reversed,
        order_by: [t.transaction_date, t.id],
        select: %{id: t.id, date: t.transaction_date, interest: t.interest_portion_derived}
      )
    )
  end

  # the interest waived on the installment: by waiver transactions up to `till`, and the part of its waived
  # interest that was waived before it was ever accrued (unrecognized income)
  defp waiver(%{loan: loan, till: till}, row, previous) do
    waived = row.interest_waived || Decimal.new(0)
    by_transactions = waived_by_transactions(row.id, till)

    to_date = if Date.compare(row.due_date, till) == :lt, do: row.due_date, else: till
    total = unrecognized_total(loan.id, to_date)

    unrecognized =
      waived
      |> min_of(positive(Decimal.sub(total, previous)))
      |> min_of(positive(Decimal.sub(waived, by_transactions)))

    counted =
      if Date.compare(till, row.due_date) == :gt,
        do: waived,
        else: Decimal.add(by_transactions, unrecognized)

    %{by_transactions: by_transactions, unrecognized: unrecognized, counted: counted}
  end

  defp waived_by_transactions(row_id, till) do
    TenantRepo.one(
      from(m in "m_loan_transaction_repayment_schedule_mapping",
        join: t in "m_loan_transaction",
        on: t.id == m.loan_transaction_id,
        where:
          m.loan_repayment_schedule_id == ^row_id and not t.is_reversed and
            t.transaction_type_enum == @waive_interest and t.transaction_date <= ^till,
        select: sum(coalesce(m.interest_portion_derived, 0))
      )
    ) || Decimal.new(0)
  end

  defp unrecognized_total(loan_id, date) do
    TenantRepo.one(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and not t.is_reversed and
            t.transaction_type_enum == @waive_interest and
            t.transaction_date <= ^date,
        select: sum(coalesce(t.unrecognized_income_portion, 0))
      )
    ) || Decimal.new(0)
  end

  defp positive(d), do: if(Decimal.compare(d, 0) == :lt, do: Decimal.new(0), else: d)
  defp min_of(a, b), do: if(Decimal.compare(a, b) == :gt, do: b, else: a)
end
