defmodule ECBLoans.Loans.Derived do
  @moduledoc """
  The running totals a loan keeps in its own row (`principal_outstanding_derived`, `total_repayment_derived`
  and the rest), worked out again from the repayment schedule and the transactions whenever either changes.
  Follows Fineract's `LoanSummary` and `LoanBalanceService.updateLoanSummaryDerivedFields`.
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBPlatform.TenantRepo

  @disbursement 1

  @doc "Recomputes the derived totals of loan `loan_id` and stores them."
  @spec refresh!(integer, struct) :: :ok
  def refresh!(loan_id, user) do
    rows = Loans.installments(loan_id)
    disbursed = disbursed(loan_id)

    principal = sum(rows, & &1.principal)
    interest = sum(rows, & &1.interest)
    fees = sum(rows, & &1.fee_charges)
    penalties = sum(rows, & &1.penalty_charges)

    principal_repaid = sum(rows, & &1.principal_completed)
    interest_repaid = sum(rows, & &1.interest_completed)
    fees_repaid = sum(rows, & &1.fee_charges_completed)
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

    :ok
  end

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
