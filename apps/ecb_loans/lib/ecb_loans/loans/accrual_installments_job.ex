defmodule ECBLoans.Loans.AccrualInstallmentsJob do
  @moduledoc """
  The job "Add Accrual Transactions" (`ACC_AATR`): accrues the installments of periodic accrual loans that have
  fallen due, each on its due date. The work is `ECBLoans.Loans.AccrualJob` for whole installments.
  """

  @doc "Runs the job on behalf of `user`."
  @spec run(struct) :: :ok
  def run(user), do: ECBLoans.Loans.AccrualJob.run(user, :installments)
end
