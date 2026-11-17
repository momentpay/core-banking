defmodule ECBLoans.Loans.ArrearsAgeingJob do
  @moduledoc """
  The job "Update Loan Arrears Ageing" (`LA_ARAG`), after Fineract's `LoanArrearsAgeingUpdateHandler`: brings the
  arrears of every active loan up to date for the business date (see `ECBLoans.Loans.Arrears`).
  """

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(_user), do: ECBLoans.Loans.Arrears.update_all!()
end
