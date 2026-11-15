defmodule ECBLoans.Application do
  @moduledoc """
  Starts the loans app (loan products so far). It has no processes of its own; it registers the commands it
  handles with the platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"LOANPRODUCT", "CREATE", ECBLoans.Handlers.LoanProduct},
    {"LOANPRODUCT", "UPDATE", ECBLoans.Handlers.LoanProduct}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBLoans.Supervisor)
  end
end
