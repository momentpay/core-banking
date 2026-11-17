defmodule ECBLoans.Loans.Accruals do
  @moduledoc """
  The accrual transactions of a loan: interest recognised as income before it is paid.

    * At disbursement, a product with upfront accrual accounting (rule 4) books the whole interest as
      accrued. So do products with accounting off or cash, while the configuration
      `allow-cash-and-non-cash-accrual` is on (Fineract's default); there the accrual is only a transaction
      and posts no entries.
    * A product with periodic accrual accounting (rule 3) accrues over time, installment by installment, in
      the job "Add Periodic Accrual Transactions" (`ECBLoans.Loans.AccrualJob`). Each installment remembers the
      interest accrued on it (`accrual_interest_derived`). When the loan is closed or overpaid, what is still
      not accrued is accrued on that day in one transaction (`LoanAccrualsProcessingServiceImpl`,
      `processAccrualsOnLoanClosure`).
    * When a repayment is undone or adjusted, or the loan is written off, the accruals are looked at again
      (`reprocess!/2`): an accrual that is more than its installment charges, or the latest accrual made
      part-way through an installment, is taken back, to be made again by the next run.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{ChargeRows, Disburse, Journal}
  alias ECBPlatform.{BusinessDate, Configuration, TenantRepo}

  @accrual 10
  @closed 600
  @overpaid 700

  @doc "Whether the interest of a loan of `product` is booked as accrued on the day it is paid out."
  @spec at_disbursement?(map) :: boolean
  def at_disbursement?(%{accounting_id: 4}), do: true

  def at_disbursement?(%{accounting_id: id}) when id in [nil, 1, 2],
    do: Configuration.enabled?("allow-cash-and-non-cash-accrual")

  def at_disbursement?(_product), do: false

  @doc """
  Books the charges of the loan that do not fall due at disbursement as accrued on `on`, if the product does it at
  disbursement. Fineract does this before the fees due at disbursement are taken from what is paid out.
  """
  @spec charges_on_disbursement!(struct, map, map, Date.t()) :: :ok
  def charges_on_disbursement!(user, loan, product, on) do
    if at_disbursement?(product), do: accrue_charges!(user, loan, product, on)
    :ok
  end

  @doc "Books the whole interest of the loan as accrued on `on`, if the product does it at disbursement."
  @spec on_disbursement!(struct, map, map, Date.t()) :: :ok
  def on_disbursement!(user, loan, product, on) do
    if at_disbursement?(product) and Decimal.compare(loan.interest_charged_derived, 0) == :gt,
      do: post!(user, loan, product, on, loan.interest_charged_derived)

    :ok
  end

  # each charge that does not fall due at disbursement is booked as accrued in full
  defp accrue_charges!(user, loan, product, on) do
    for c <- Loans.charges(loan.id), c.time != 1, do: accrue_charge!(user, loan, product, c, on)
    :ok
  end

  @doc """
  Books one charge of the loan (as `Loans.charges/1` gives it) as accrued in full on `on`, with the installment
  that holds its due date, if any, taking the accrual.
  """
  @spec accrue_charge!(struct, map, map, map, Date.t()) :: integer
  def accrue_charge!(user, loan, product, c, on) do
    tx =
      if c.penalty,
        do: %{type: @accrual, date: on, amount: c.amount, penalties: c.amount},
        else: %{type: @accrual, date: on, amount: c.amount, fees: c.amount}

    id = Disburse.insert_transaction!(user, loan, tx)
    installment = if c.time in [2, 9], do: ChargeRows.installment_of(loan.id, c.due_date)
    ChargeRows.record_paid_by!(id, c.id, c.amount, installment)
    Journal.accrual!(user, loan, product, Map.put(tx, :id, id))
    id
  end

  @doc """
  Called when the status of a loan may have changed (`status` is what it is now): a loan of a periodic accrual
  product that is closed or overpaid accrues the interest it has not accrued yet.
  """
  @spec after_status_change!(struct, integer, integer) :: :ok
  def after_status_change!(user, loan_id, status) do
    loan = Loans.fetch!(loan_id)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    if product.accounting_id == 3 and status in [@closed, @overpaid],
      do: accrue_the_rest!(user, loan, product, status),
      else: :ok
  end

  defp accrue_the_rest!(user, loan, product, status) do
    date = if status == @closed, do: loan.closedon_date, else: loan.overpaidon_date
    slots = Enum.group_by(ChargeRows.slots(loan.id), & &1.installment)

    # per installment: what it accrues (its interest, fees and penalties less what was waived) against what it
    # has accrued, which also counts the waived interest as taken off; one with nothing new keeps what it holds
    parts =
      for r <- Loans.installments(loan.id) do
        waived = zero_nil(r.interest_waived)
        accruable = positive(Decimal.sub(zero_nil(r.interest), waived))
        accrued = positive(Decimal.sub(zero_nil(r.accrual_interest), waived))
        fees = positive(Decimal.sub(zero_nil(r.fee_charges), zero_nil(r.fee_charges_waived)))

        penalties =
          positive(Decimal.sub(zero_nil(r.penalty_charges), zero_nil(r.penalty_charges_waived)))

        %{
          row: r,
          accruable: accruable,
          interest: Decimal.sub(accruable, accrued),
          fees: fees,
          fee_portion: Decimal.sub(fees, zero_nil(r.accrual_fee)),
          penalties: penalties,
          penalty_portion: Decimal.sub(penalties, zero_nil(r.accrual_penalty)),
          slots: Map.get(slots, r.installment, [])
        }
      end

    interest = parts |> Enum.map(& &1.interest) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    fees =
      parts |> Enum.map(&positive(&1.fee_portion)) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    penalties =
      parts
      |> Enum.map(&positive(&1.penalty_portion))
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    total = interest |> Decimal.add(fees) |> Decimal.add(penalties)

    if Decimal.compare(total, 0) == :gt do
      id =
        post!(user, loan, product, date, total,
          portions: %{
            interest: positive(interest),
            fees: nil_if_zero(fees),
            penalties: nil_if_zero(penalties)
          }
        )

      for p <- parts,
          slot <-
            fresh(p.slots, false, p.row.accrual_fee) ++
              fresh(p.slots, true, p.row.accrual_penalty),
          do: ChargeRows.record_paid_by!(id, slot.charge, slot.amount, p.row.installment)
    end

    for p <- parts,
        not Enum.all?([p.interest, p.fee_portion, p.penalty_portion], &Decimal.eq?(&1, 0)),
        do: set_accruals!(p.row.id, p.accruable, p.fees, p.penalties)

    :ok
  end

  # the charges of one kind in an installment that are not covered by what has been accrued on it
  defp fresh(slots, penalty?, accrued) do
    slots
    |> Enum.filter(&(&1.penalty == penalty?))
    |> Enum.reduce({[], zero_nil(accrued)}, fn slot, {fresh, left} ->
      if Decimal.compare(left, slot.amount) != :lt,
        do: {fresh, Decimal.sub(left, slot.amount)},
        else: {fresh ++ [slot], left}
    end)
    |> elem(0)
  end

  defp nil_if_zero(d), do: if(Decimal.eq?(d, 0), do: nil, else: d)
  defp positive(d), do: if(Decimal.compare(d, 0) == :lt, do: Decimal.new(0), else: d)

  @doc """
  The interest accrued and not yet paid or waived on `date` (Fineract's `LoanBalanceService.getReceivableInterest`):
  the accruals, less the interest of repayments and waivers, never less than nothing along the way.
  """
  @spec receivable_interest(integer, Date.t()) :: Decimal.t()
  def receivable_interest(loan_id, date) do
    TenantRepo.all(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and not t.is_reversed and t.transaction_type_enum in [2, 4, 10] and
            t.transaction_date <= ^date,
        order_by: [t.transaction_date, t.id],
        select: {t.transaction_type_enum, t.interest_portion_derived}
      )
    )
    |> Enum.reduce(Decimal.new(0), fn {type, interest}, sum ->
      interest = zero_nil(interest)

      sum =
        if type == @accrual, do: Decimal.add(sum, interest), else: Decimal.sub(sum, interest)

      if Decimal.compare(sum, 0) == :lt, do: Decimal.new(0), else: sum
    end)
  end

  @doc """
  Looks at the accruals of a loan again after a change to its repayments (Fineract's `reprocessExistingAccruals`
  for the cumulative schedule): an accrual transaction is taken back when the installment it falls in would
  have more accrued than it charges, or when it is the latest accrual of the loan and was made part-way
  through its installment. Every installment then holds what is left of its accruals.
  """
  @spec reprocess!(struct, integer) :: :ok
  def reprocess!(user, loan_id) do
    loan = Loans.fetch!(loan_id)

    if ECBLoans.LoanProducts.fetch!(loan.product_id).accounting_id == 3 do
      rows = Loans.installments(loan_id)
      first = rows |> Enum.map(& &1.installment) |> Enum.min(fn -> nil end)
      Enum.each(rows, &reprocess_installment!(user, loan, &1, &1.installment == first))
    end

    :ok
  end

  defp reprocess_installment!(user, loan, row, first?) do
    kept =
      loan.id
      |> accruals()
      |> Enum.filter(&in_period?(&1.date, row, first?))
      |> Enum.reduce(%{interest: zero(), fees: zero(), penalties: zero()}, fn tx, sum ->
        sum = add_portions(sum, tx)

        if changed?(loan, row, sum, tx) do
          take_back!(user, loan, tx)
          subtract_portions(sum, tx)
        else
          sum
        end
      end)

    set_accruals!(row.id, kept.interest, kept.fees, kept.penalties)
  end

  defp zero, do: Decimal.new(0)

  defp add_portions(sum, tx) do
    %{
      interest: Decimal.add(sum.interest, zero_nil(tx.interest)),
      fees: Decimal.add(sum.fees, zero_nil(tx.fees)),
      penalties: Decimal.add(sum.penalties, zero_nil(tx.penalties))
    }
  end

  defp subtract_portions(sum, tx) do
    %{
      interest: Decimal.sub(sum.interest, zero_nil(tx.interest)),
      fees: Decimal.sub(sum.fees, zero_nil(tx.fees)),
      penalties: Decimal.sub(sum.penalties, zero_nil(tx.penalties))
    }
  end

  defp changed?(loan, row, sum, tx) do
    Decimal.compare(zero_nil(row.interest), sum.interest) == :lt or
      Decimal.compare(zero_nil(row.fee_charges), sum.fees) == :lt or
      Decimal.compare(zero_nil(row.penalty_charges), sum.penalties) == :lt or
      (loan.accrued_till == tx.date and loan.accrued_till != row.due_date)
  end

  defp accruals(loan_id) do
    TenantRepo.all(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and t.transaction_type_enum == @accrual and not t.is_reversed,
        order_by: [t.transaction_date, t.id],
        select: %{
          id: t.id,
          date: t.transaction_date,
          interest: t.interest_portion_derived,
          fees: t.fee_charges_portion_derived,
          penalties: t.penalty_charges_portion_derived
        }
      )
    )
  end

  @doc """
  Whether `date` falls in the period of an installment: the first installment takes the day it starts on, the
  others start the day after.
  """
  @spec in_period?(Date.t(), map, boolean) :: boolean
  def in_period?(date, row, true),
    do: Date.compare(date, row.from_date) != :lt and Date.compare(date, row.due_date) != :gt

  def in_period?(date, row, false),
    do: Date.compare(date, row.from_date) == :gt and Date.compare(date, row.due_date) != :gt

  @doc "Takes an accrual transaction back: its entries are reversed and it no longer counts."
  @spec take_back!(struct, map, map) :: :ok
  def take_back!(user, loan, tx) do
    Journal.reverse!(user, loan, tx.id, tx.date)

    TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^tx.id),
      set: [
        is_reversed: true,
        reversed_on_date: BusinessDate.current(),
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )

    :ok
  end

  @doc "Records what is accrued on an installment (nothing is stored as null)."
  @spec set_accrual!(integer, Decimal.t()) :: :ok
  def set_accrual!(row_id, amount),
    do: set_accruals!(row_id, amount, Decimal.new(0), Decimal.new(0))

  @doc "Records the interest, fees and penalties accrued on an installment (nothing is stored as null)."
  @spec set_accruals!(integer, Decimal.t(), Decimal.t(), Decimal.t()) :: :ok
  def set_accruals!(row_id, interest, fees, penalties) do
    nil_zero = fn d -> if Decimal.eq?(d, 0), do: nil, else: d end

    TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.id == ^row_id),
      set: [
        accrual_interest_derived: nil_zero.(interest),
        accrual_fee_charges_derived: nil_zero.(fees),
        accrual_penalty_charges_derived: nil_zero.(penalties)
      ]
    )

    :ok
  end

  @doc """
  Books an accrual transaction of `amount` on `date` and its entries. Given `portions` (`%{interest, fees,
  penalties}`) the transaction is made of them, with the fees and penalties recorded even when nothing (as the
  job does); otherwise it is all interest, and the fees and penalties are left out.
  """
  @spec post!(struct, map, map, Date.t(), Decimal.t(), keyword) :: integer
  def post!(user, loan, product, date, amount, opts) do
    tx = %{type: @accrual, date: date, amount: amount, interest: amount}

    tx =
      case opts[:portions] do
        nil -> tx
        p -> Map.merge(tx, %{interest: p.interest, fees: p.fees, penalties: p.penalties})
      end

    id = Disburse.insert_transaction!(user, loan, tx)
    Journal.accrual!(user, loan, product, Map.put(tx, :id, id))
    id
  end

  @doc "Books an accrual transaction that is all interest."
  @spec post!(struct, map, map, Date.t(), Decimal.t()) :: integer
  def post!(user, loan, product, date, interest),
    do: post!(user, loan, product, date, interest, [])

  defp zero_nil(nil), do: Decimal.new(0)
  defp zero_nil(d), do: d
end
