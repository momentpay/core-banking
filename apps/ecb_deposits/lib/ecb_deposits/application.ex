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
    {"SAVINGSACCOUNT", "CLOSE", ECBDeposits.Handlers.SavingsAccount}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBDeposits.Supervisor)
  end
end
