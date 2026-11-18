defmodule ECBLoans.Application do
  @moduledoc """
  Starts the loans app (loan products so far). It has no processes of its own; it registers the commands it
  handles with the platform's command pipeline, and the scheduler job it runs.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"LOANPRODUCT", "CREATE", ECBLoans.Handlers.LoanProduct},
    {"LOANPRODUCT", "UPDATE", ECBLoans.Handlers.LoanProduct},
    {"LOAN", "CREATE", ECBLoans.Handlers.Loan},
    {"LOAN", "UPDATE", ECBLoans.Handlers.Loan},
    {"LOAN", "APPROVE", ECBLoans.Handlers.Loan},
    {"LOAN", "APPROVALUNDO", ECBLoans.Handlers.Loan},
    {"LOAN", "REJECT", ECBLoans.Handlers.Loan},
    {"LOAN", "WITHDRAW", ECBLoans.Handlers.Loan},
    {"LOAN", "DISBURSE", ECBLoans.Handlers.Loan},
    {"LOAN", "REPAYMENT", ECBLoans.Handlers.Loan},
    {"LOAN", "MERCHANTISSUEDREFUND", ECBLoans.Handlers.Loan},
    {"LOAN", "PAYOUTREFUND", ECBLoans.Handlers.Loan},
    {"LOAN", "GOODWILLCREDIT", ECBLoans.Handlers.Loan},
    {"LOAN", "UPDATELOANOFFICER", ECBLoans.Handlers.Loan},
    {"LOAN", "REMOVELOANOFFICER", ECBLoans.Handlers.Loan},
    {"LOAN", "RECOVERYPAYMENT", ECBLoans.Handlers.Loan},
    {"LOAN", "UNDOWRITEOFF", ECBLoans.Handlers.Loan},
    {"LOAN", "CLOSEASRESCHEDULED", ECBLoans.Handlers.Loan},
    {"LOAN", "CLOSE", ECBLoans.Handlers.Loan},
    {"LOAN", "CHARGEOFF", ECBLoans.Handlers.Loan},
    {"LOAN", "UNDOCHARGEOFF", ECBLoans.Handlers.Loan},
    {"LOAN", "CREDITBALANCEREFUND", ECBLoans.Handlers.Loan},
    {"LOAN", "ADJUST", ECBLoans.Handlers.Loan},
    {"LOAN", "WAIVEINTERESTPORTION", ECBLoans.Handlers.Loan},
    {"LOAN", "WRITEOFF", ECBLoans.Handlers.Loan},
    {"LOAN", "DISBURSALUNDO", ECBLoans.Handlers.Loan},
    {"LOAN", "DELETE", ECBLoans.Handlers.Loan},
    {"COLLATERAL", "CREATE", ECBLoans.Handlers.Collateral},
    {"COLLATERAL", "UPDATE", ECBLoans.Handlers.Collateral},
    {"COLLATERAL", "DELETE", ECBLoans.Handlers.Collateral},
    {"LOANCHARGE", "CREATE", ECBLoans.Handlers.LoanCharge},
    {"LOANCHARGE", "UPDATE", ECBLoans.Handlers.LoanCharge},
    {"LOANCHARGE", "DELETE", ECBLoans.Handlers.LoanCharge},
    {"LOANCHARGE", "WAIVE", ECBLoans.Handlers.LoanCharge},
    {"LOANCHARGE", "PAY", ECBLoans.Handlers.LoanCharge},
    {"LOANCHARGE", "ADJUSTMENT", ECBLoans.Handlers.LoanCharge}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)
    ECBPlatform.Jobs.register("ACC_APTR", ECBLoans.Loans.AccrualJob)
    ECBPlatform.Jobs.register("ACC_AATR", ECBLoans.Loans.AccrualInstallmentsJob)
    ECBPlatform.Jobs.register("LA_OPEN", ECBLoans.Loans.OverdueJob)
    ECBPlatform.Jobs.register("LA_ARAG", ECBLoans.Loans.ArrearsAgeingJob)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBLoans.Supervisor)
  end
end
