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

  @doc "Books the whole interest of the loan as accrued on `on`, if the product does it at disbursement."
  @spec on_disbursement!(struct, map, map, Date.t()) :: :ok
  def on_disbursement!(user, loan, product, on) do
    if at_disbursement?(product) do
      accrue_charges!(user, loan, product, on)

      if Decimal.compare(loan.interest_charged_derived, 0) == :gt,
        do: post!(user, loan, product, on, loan.interest_charged_derived)
    end

    :ok
  end

  # each charge that does not fall due at disbursement is booked as accrued in full, before the interest
  defp accrue_charges!(user, loan, product, on) do
    for c <- Loans.charges(loan.id), c.time != 1 do
      tx =
        if c.penalty,
          do: %{type: @accrual, date: on, amount: c.amount, penalties: c.amount},
          else: %{type: @accrual, date: on, amount: c.amount, fees: c.amount}

      id = Disburse.insert_transaction!(user, loan, tx)
      installment = if c.time == 2, do: ChargeRows.installment_of(loan.id, c.due_date)
      ChargeRows.record_paid_by!(id, c.id, c.amount, installment)
      Journal.accrual!(user, loan, product, Map.put(tx, :id, id))
    end

    :ok
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

    # per installment: what it accrues (its interest less what was waived) against what it has accrued, which
    # also counts the waived interest as taken off; an installment with nothing new keeps what it holds
    parts =
      for r <- Loans.installments(loan.id) do
        waived = zero_nil(r.interest_waived)
        accruable = positive(Decimal.sub(zero_nil(r.interest), waived))
        accrued = positive(Decimal.sub(zero_nil(r.accrual_interest), waived))
        {r.id, accruable, Decimal.sub(accruable, accrued)}
      end

    owed = parts |> Enum.map(&elem(&1, 2)) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    if Decimal.compare(owed, 0) == :gt, do: post!(user, loan, product, date, owed)

    for {id, accruable, portion} <- parts,
        not Decimal.eq?(portion, 0),
        do: set_accrual!(id, accruable)

    :ok
  end

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
      |> Enum.reduce(Decimal.new(0), fn tx, sum ->
        sum = Decimal.add(sum, zero_nil(tx.interest))

        if changed?(loan, row, sum, tx) do
          take_back!(user, loan, tx)
          Decimal.sub(sum, zero_nil(tx.interest))
        else
          sum
        end
      end)

    set_accrual!(row.id, kept)
  end

  defp changed?(loan, row, interest, tx) do
    Decimal.compare(zero_nil(row.interest), interest) == :lt or
      (loan.accrued_till == tx.date and loan.accrued_till != row.due_date)
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
  def set_accrual!(row_id, amount) do
    value = if Decimal.eq?(amount, 0), do: nil, else: amount

    TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.id == ^row_id),
      set: [accrual_interest_derived: value]
    )

    :ok
  end

  @doc """
  Books an accrual transaction of `interest` on `date` and its entries. The job records its accruals with fees and
  penalties of nothing (`charges: :zero`); the others leave them out.
  """
  @spec post!(struct, map, map, Date.t(), Decimal.t(), keyword) :: integer
  def post!(user, loan, product, date, interest, opts \\ []) do
    tx = %{type: @accrual, date: date, amount: interest, interest: interest}

    tx =
      if opts[:charges] == :zero,
        do: Map.merge(tx, %{fees: Decimal.new(0), penalties: Decimal.new(0)}),
        else: tx

    id = Disburse.insert_transaction!(user, loan, tx)
    Journal.accrual!(user, loan, product, Map.put(tx, :id, id))
    id
  end

  defp zero_nil(nil), do: Decimal.new(0)
  defp zero_nil(d), do: d
end
