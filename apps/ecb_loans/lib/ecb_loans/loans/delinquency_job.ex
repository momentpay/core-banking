defmodule ECBLoans.Loans.DelinquencyJob do
  @moduledoc """
  The job "Loan Delinquency Classification" (`LA_DECL`), after Fineract's `SetLoanDelinquencyTagsTasklet`: puts every
  active loan of a product with a delinquency bucket that has an installment due and unpaid in the range its
  delinquency calls for, and takes out of its range one that is no longer delinquent (see
  `ECBLoans.Delinquency.Classify`).
  """
  import Ecto.Query

  alias ECBLoans.Delinquency.Classify
  alias ECBPlatform.{BusinessDate, TenantRepo}

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user) do
    today = BusinessDate.current()

    from(l in "m_loan",
      join: p in "m_product_loan",
      on: p.id == l.product_id,
      join: s in "m_loan_repayment_schedule",
      on: s.loan_id == l.id,
      where:
        l.loan_status_id == 300 and not is_nil(p.delinquency_bucket_id) and s.duedate <= ^today and
          s.completed_derived == false,
      distinct: true,
      select: l.id
    )
    |> TenantRepo.all()
    |> Enum.each(&Classify.classify!(&1, user))
  end
end
