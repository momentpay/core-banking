defmodule ECBOrg.Application do
  @moduledoc """
  Starts the organisation app. It has no processes of its own; it registers the commands it handles
  with the platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @impl true
  def start(_type, _args) do
    Handlers.register("OFFICE", "CREATE", ECBOrg.Offices.CreateHandler)
    Handlers.register("OFFICE", "UPDATE", ECBOrg.Offices.UpdateHandler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBOrg.Supervisor)
  end
end
