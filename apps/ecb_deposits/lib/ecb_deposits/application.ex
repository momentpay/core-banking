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
    {"FIXEDDEPOSITPRODUCT", "CREATE", ECBDeposits.Handlers.FixedDepositProduct},
    {"FIXEDDEPOSITPRODUCT", "UPDATE", ECBDeposits.Handlers.FixedDepositProduct},
    {"FIXEDDEPOSITPRODUCT", "DELETE", ECBDeposits.Handlers.FixedDepositProduct},
    {"RECURRINGDEPOSITPRODUCT", "CREATE", ECBDeposits.Handlers.RecurringDepositProduct},
    {"RECURRINGDEPOSITPRODUCT", "UPDATE", ECBDeposits.Handlers.RecurringDepositProduct},
    {"RECURRINGDEPOSITPRODUCT", "DELETE", ECBDeposits.Handlers.RecurringDepositProduct},
    {"FIXEDDEPOSITACCOUNT", "CREATE", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "UPDATE", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "DELETE", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "APPROVE", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "APPROVALUNDO", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "REJECT", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "WITHDRAW", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "ACTIVATE", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "CALCULATEINTEREST", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "POSTINTEREST", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "CLOSE", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "PREMATURECLOSE", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "DEPOSIT", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "WITHDRAWAL", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "UNDOTRANSACTION", ECBDeposits.Handlers.FixedDepositAccount},
    {"FIXEDDEPOSITACCOUNT", "ADJUSTTRANSACTION", ECBDeposits.Handlers.FixedDepositAccount},
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
    {"SAVINGSACCOUNT", "ASSIGNSAVINGSOFFICER", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "UNASSIGNSAVINGSOFFICER", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "BLOCK", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "UNBLOCK", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "BLOCKCREDITS", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "UNBLOCKCREDITS", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "BLOCKDEBITS", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "UNBLOCKDEBITS", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "HOLDAMOUNT", ECBDeposits.Handlers.SavingsAccount},
    {"SAVINGSACCOUNT", "RELEASEAMOUNT", ECBDeposits.Handlers.SavingsAccount},
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
    ECBPlatform.Jobs.register("SA_UDOR", ECBDeposits.Savings.DormancyJob)
    ECBPlatform.Jobs.register("SA_MATD", ECBDeposits.DepositAccounts.MaturityJob)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBDeposits.Supervisor)
  end
end
