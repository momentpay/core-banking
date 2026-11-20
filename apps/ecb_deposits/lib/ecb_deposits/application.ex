defmodule ECBDeposits.Application do
  @moduledoc """
  Starts the deposits app (savings products so far). It has no processes of its own; it registers the
  commands it handles with the platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"SAVINGSPRODUCT", "CREATE", ECBDeposits.Handlers.SavingsProduct},
    {"SAVINGSPRODUCT", "UPDATE", ECBDeposits.Handlers.SavingsProduct},
    {"SAVINGSPRODUCT", "DELETE", ECBDeposits.Handlers.SavingsProduct},
    {"SAVINGSACCOUNT", "CREATE", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "UPDATE", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "DELETE", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "APPROVE", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "APPROVALUNDO", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "REJECT", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "WITHDRAW", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "ACTIVATE", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "CLOSE", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "DEPOSIT", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "WITHDRAWAL", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "FORCE_WITHDRAWAL", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "UNDOTRANSACTION", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "REVERSETRANSACTION", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "ADJUSTTRANSACTION", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "CALCULATEINTEREST", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "POSTINTEREST", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNTCHARGE", "CREATE", ECBDeposits.Handlers.SavingsAccountCharge},
    {"SAVINGSACCOUNTCHARGE", "UPDATE", ECBDeposits.Handlers.SavingsAccountCharge},
    {"SAVINGSACCOUNTCHARGE", "DELETE", ECBDeposits.Handlers.SavingsAccountCharge},
    {"SAVINGSACCOUNTCHARGE", "WAIVE", ECBDeposits.Handlers.SavingsAccountCharge},
    {"SAVINGSACCOUNTCHARGE", "PAY", ECBDeposits.Handlers.SavingsAccountCharge},
    {"SAVINGSACCOUNTCHARGE", "INACTIVATE", ECBDeposits.Handlers.SavingsAccountCharge}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)
    ECBPlatform.Jobs.register("SA_PINT", ECBDeposits.Savings.PostInterestJob)
    ECBPlatform.Jobs.register("SA_PDCH", ECBDeposits.Savings.PayDueChargesJob)
    ECBPlatform.Jobs.register("SA_AANF", ECBDeposits.Savings.ApplyAnnualFeeJob)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBDeposits.Supervisor)
  end
end
