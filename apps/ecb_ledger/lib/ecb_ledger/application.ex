defmodule ECBLedger.Application do
  @moduledoc """
  Starts the ledger app. It has no processes of its own; it registers the commands it handles with the
  platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"GLACCOUNT", "CREATE", ECBLedger.Handlers.CreateGLAccount},
    {"GLACCOUNT", "UPDATE", ECBLedger.Handlers.UpdateGLAccount},
    {"GLACCOUNT", "DELETE", ECBLedger.Handlers.DeleteGLAccount}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBLedger.Supervisor)
  end
end
