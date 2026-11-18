defmodule ECBLoans.Loans.Derived do
  @moduledoc """
  The running totals a loan keeps in its own row (`principal_outstanding_derived`, `total_repayment_derived`
  and the rest), worked out again from the repayment schedule and the transactions whenever either changes.
  Follows Fineract's `LoanSummary` and `LoanBalanceService.updateLoanSummaryDerivedFields`.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBLoans.Loans.{Arrears, ChargeRows}
  alias ECBPlatform.TenantRepo

  @disbursement 1

  @doc "Recomputes the derived totals of loan `loan_id` and stores them."
  @spec refresh!(integer, struct) :: :ok
  def refresh!(loan_id, user) do
    rows = Loans.installments(loan_id)
    disbursed = disbursed(loan_id)

    principal = sum(rows, & &1.principal)
    interest = sum(rows, & &1.interest)
    loan = Loans.fetch!(loan_id)
    due_at_disbursement = loan.total_charges_due_at_disbursement_derived || Decimal.new(0)
    fees = rows |> sum(& &1.fee_charges) |> Decimal.add(due_at_disbursement)
    penalties = sum(rows, & &1.penalty_charges)

    principal_repaid = sum(rows, & &1.principal_completed)
    interest_repaid = sum(rows, & &1.interest_completed)

    fees_repaid =
      rows
      |> sum(& &1.fee_charges_completed)
      |> Decimal.add(ChargeRows.paid_at_disbursement(loan_id))

    penalties_repaid = sum(rows, & &1.penalty_charges_completed)

    principal_off = sum(rows, & &1.principal_writtenoff)
    interest_off = sum(rows, & &1.interest_writtenoff)
    fees_off = sum(rows, & &1.fee_charges_writtenoff)
    penalties_off = sum(rows, & &1.penalty_charges_writtenoff)

    interest_waived = sum(rows, & &1.interest_waived)
    fees_waived = sum(rows, & &1.fee_charges_waived)
    penalties_waived = sum(rows, & &1.penalty_charges_waived)

    interest_out =
      interest |> minus(interest_repaid) |> minus(interest_waived) |> minus(interest_off)

    fees_out = fees |> minus(fees_repaid) |> minus(fees_waived) |> minus(fees_off)

    penalties_out =
      penalties |> minus(penalties_repaid) |> minus(penalties_waived) |> minus(penalties_off)

    principal_out = disbursed |> minus(principal_repaid) |> minus(principal_off)
    _ = principal

    charged = sum_all([interest, fees, penalties])
    repaid = sum_all([principal_repaid, interest_repaid, fees_repaid, penalties_repaid])
    waived = sum_all([interest_waived, fees_waived, penalties_waived])
    written_off = sum_all([principal_off, interest_off, fees_off, penalties_off])

    now = DateTime.utc_now()

    TenantRepo.update_all(from(l in "m_loan", where: l.id == ^loan_id),
      set: [
        principal_disbursed_derived: disbursed,
        total_principal_derived: disbursed,
        principal_repaid_derived: principal_repaid,
        principal_writtenoff_derived: principal_off,
        principal_outstanding_derived: principal_out,
        interest_charged_derived: interest,
        interest_repaid_derived: interest_repaid,
        interest_waived_derived: interest_waived,
        interest_writtenoff_derived: interest_off,
        interest_outstanding_derived: interest_out,
        fee_charges_charged_derived: fees,
        fee_charges_repaid_derived: fees_repaid,
        fee_charges_waived_derived: fees_waived,
        fee_charges_writtenoff_derived: fees_off,
        fee_charges_outstanding_derived: fees_out,
        penalty_charges_charged_derived: penalties,
        penalty_charges_repaid_derived: penalties_repaid,
        penalty_charges_waived_derived: penalties_waived,
        penalty_charges_writtenoff_derived: penalties_off,
        penalty_charges_outstanding_derived: penalties_out,
        total_expected_repayment_derived: Decimal.add(disbursed, charged),
        total_repayment_derived: repaid,
        total_expected_costofloan_derived: charged,
        total_costofloan_derived: sum_all([interest_repaid, fees_repaid, penalties_repaid]),
        total_waived_derived: waived,
        total_writtenoff_derived: written_off,
        total_outstanding_derived:
          sum_all([principal_out, interest_out, fees_out, penalties_out]),
        last_modified_by: user.id,
        last_modified_on_utc: now
      ]
    )

    balances!(loan_id)

    # the arrears follow the loan whenever its totals do, as Fineract's listeners keep them
    Arrears.update!(loan_id)
  end

  # the transactions that move no money and so have no balance of their own: contra, marked for rescheduling,
  # accrual, the transfers, charge-off, accrual activity and accrual adjustment
  @non_monetary [3, 7, 10, 12, 13, 14, 15, 27, 32, 34]
  @adds_principal [1, 19, 35]

  @doc """
  Works out the principal still outstanding after each transaction that stands (`outstanding_loan_balance_derived`),
  as Fineract does after every change (`LoanBalanceService.updateLoanOutstandingBalances`): the transactions in the
  order of their date, the day they were made, the moment they were made, waivers first, and then their number;
  a disbursement adds to the balance and the principal of the others takes from it, never below nothing.
  """
  @spec balances!(integer) :: :ok
  def balances!(loan_id) do
    # Fineract leaves a waiver of nothing without a balance
    ordered =
      loan_id
      |> monetary_transactions()
      |> Enum.reject(&(&1.type == 4 and Decimal.eq?(&1.amount, 0)))
      |> Enum.sort_by(
        &{Date.to_gregorian_days(&1.date), submitted_days(&1.submitted), moment(&1.created),
         if(&1.type == 4 or &1.type == 9, do: 0, else: 1), &1.id}
      )

    _ = Enum.reduce(ordered, Decimal.new(0), &store_balance/2)
    :ok
  end

  defp monetary_transactions(loan_id) do
    TenantRepo.all(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and not t.is_reversed and
            t.transaction_type_enum not in ^@non_monetary,
        select: %{
          id: t.id,
          type: t.transaction_type_enum,
          date: t.transaction_date,
          submitted: t.submitted_on_date,
          created: t.created_on_utc,
          amount: t.amount,
          principal: t.principal_portion_derived,
          overpayment: t.overpayment_portion_derived
        }
      )
    )
  end

  # the balance after a transaction, which is kept on it; the running balance may go below nothing, what is shown
  # does not
  defp store_balance(t, outstanding) do
    outstanding =
      if t.type in @adds_principal,
        do: outstanding |> Decimal.add(t.amount) |> Decimal.sub(t.overpayment || 0),
        else: Decimal.sub(outstanding, t.principal || 0)

    shown = if Decimal.compare(outstanding, 0) == :lt, do: Decimal.new(0), else: outstanding

    TenantRepo.update_all(from(x in "m_loan_transaction", where: x.id == ^t.id),
      set: [outstanding_loan_balance_derived: shown]
    )

    outstanding
  end

  defp submitted_days(nil), do: :infinity_days
  defp submitted_days(date), do: Date.to_gregorian_days(date)

  defp moment(nil), do: 0
  defp moment(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp moment(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> moment()

  # what has been paid out, from the disbursement transactions that still stand
  defp disbursed(loan_id) do
    TenantRepo.one(
      from(t in "m_loan_transaction",
        where:
          t.loan_id == ^loan_id and t.transaction_type_enum == @disbursement and not t.is_reversed,
        select: sum(t.amount)
      )
    ) || Decimal.new(0)
  end

  defp sum(rows, fun) do
    Enum.reduce(rows, Decimal.new(0), fn row, acc ->
      Decimal.add(acc, fun.(row) || Decimal.new(0))
    end)
  end

  defp sum_all(values), do: Enum.reduce(values, Decimal.new(0), &Decimal.add/2)
  defp minus(a, b), do: Decimal.sub(a, b)
end
