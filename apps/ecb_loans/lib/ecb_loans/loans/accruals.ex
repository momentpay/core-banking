defmodule ECBLoans.Loans.Accruals do
  @moduledoc """
  The accrual transactions of a loan: interest recognised as income before it is paid.

    * At disbursement, a product with upfront accrual accounting (rule 4) books the whole interest as
      accrued. So do products with accounting off or cash, while the configuration
      `allow-cash-and-non-cash-accrual` is on (Fineract's default); there the accrual is only a transaction
      and posts no entries.
    * A product with periodic accrual accounting (rule 3) accrues over time. That is the work of the
      scheduler job "Add Periodic Accrual Transactions", which E-CoreBank does not run yet; what has not been
      accrued by the time the loan is closed or overpaid is accrued on that day, as Fineract does
      (`LoanAccrualsProcessingServiceImpl.processAccrualsOnLoanClosure`), and taken back when the loan is
      reopened.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Disburse, Journal}
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
    if at_disbursement?(product) and Decimal.compare(loan.interest_charged_derived, 0) == :gt do
      post!(user, loan, product, on, loan.interest_charged_derived)
    end

    :ok
  end

  @doc """
  Called when the status of a loan may have changed, with the status it had before (`before`) and the status
  it has now (`status`): a loan of a periodic accrual product that is closed or overpaid accrues the interest
  it has not accrued yet; one that is open again takes back what it accrued from the day it was closed.
  """
  @spec after_status_change!(struct, integer, map, integer) :: :ok
  def after_status_change!(user, loan_id, before, status) do
    loan = Loans.fetch!(loan_id)
    product = ECBLoans.LoanProducts.fetch!(loan.product_id)

    cond do
      product.accounting_id != 3 -> :ok
      status in [@closed, @overpaid] -> accrue_the_rest!(user, loan, product, status)
      before.loan_status_id in [@closed, @overpaid] -> reopen!(user, loan, product, before)
      true -> :ok
    end
  end

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
    |> Enum.reduce(Decimal.new(0), fn
      {type, interest}, sum ->
        interest = interest || Decimal.new(0)

        sum =
          if type == @accrual, do: Decimal.add(sum, interest), else: Decimal.sub(sum, interest)

        if Decimal.compare(sum, 0) == :lt, do: Decimal.new(0), else: sum
    end)
  end

  defp accrue_the_rest!(user, loan, product, status) do
    date = if status == @closed, do: loan.closedon_date, else: loan.overpaidon_date
    owed = Decimal.sub(interest_due(loan.id), accrued(loan.id))

    if Decimal.compare(owed, 0) == :gt, do: post!(user, loan, product, date, owed)
    set_installment_accruals!(loan.id, :all)
    :ok
  end

  # each installment remembers the interest accrued on it: what it charges less what was waived
  defp set_installment_accruals!(loan_id, :all) do
    TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.loan_id == ^loan_id),
      set: [accrual_interest_derived: nil]
    )

    TenantRepo.query!(
      """
      UPDATE m_loan_repayment_schedule
         SET accrual_interest_derived = NULLIF(GREATEST(COALESCE(interest_amount, 0) - COALESCE(interest_waived_derived, 0), 0), 0)
       WHERE loan_id = $1
      """,
      [loan_id]
    )
  end

  # what the schedule charges as interest, less what has been waived
  defp interest_due(loan_id) do
    TenantRepo.one(
      from(r in "m_loan_repayment_schedule",
        where: r.loan_id == ^loan_id,
        select: sum(coalesce(r.interest_amount, 0) - coalesce(r.interest_waived_derived, 0))
      )
    ) || Decimal.new(0)
  end

  defp accrued(loan_id) do
    TenantRepo.one(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and t.transaction_type_enum == @accrual and not t.is_reversed,
        select: sum(coalesce(t.interest_portion_derived, 0))
      )
    ) || Decimal.new(0)
  end

  # the accruals made when the loan was closed or overpaid are taken back, newest entries last
  defp reopen!(user, loan, _product, before) do
    since = before.closedon_date || before.overpaidon_date

    accruals =
      TenantRepo.all(
        from(t in "m_loan_transaction",
          where:
            t.loan_id == ^loan.id and t.transaction_type_enum == @accrual and not t.is_reversed and
              t.transaction_date >= ^since,
          order_by: t.id,
          select: %{id: t.id, date: t.transaction_date}
        )
      )

    TenantRepo.update_all(from(r in "m_loan_repayment_schedule", where: r.loan_id == ^loan.id),
      set: [accrual_interest_derived: nil]
    )

    for a <- accruals do
      Journal.reverse!(user, loan, a.id, a.date)

      TenantRepo.update_all(from(t in "m_loan_transaction", where: t.id == ^a.id),
        set: [
          is_reversed: true,
          reversed_on_date: BusinessDate.current(),
          last_modified_by: user.id,
          last_modified_on_utc: DateTime.utc_now()
        ]
      )
    end

    :ok
  end

  defp post!(user, loan, product, date, interest) do
    tx = %{type: @accrual, date: date, amount: interest, interest: interest}
    id = Disburse.insert_transaction!(user, loan, tx)
    Journal.accrual!(user, loan, product, Map.put(tx, :id, id))
  end
end
