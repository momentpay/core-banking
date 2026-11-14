defmodule ECBOrg.Application do
  @moduledoc """
  Starts the organisation app. It has no processes of its own; it registers the commands it handles
  with the platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"OFFICE", "CREATE", ECBOrg.Offices.CreateHandler},
    {"OFFICE", "UPDATE", ECBOrg.Offices.UpdateHandler},
    {"FUND", "CREATE", ECBOrg.Handlers.CreateFund},
    {"FUND", "UPDATE", ECBOrg.Handlers.UpdateFund},
    {"PAYMENTTYPE", "CREATE", ECBOrg.Handlers.CreatePaymentType},
    {"PAYMENTTYPE", "UPDATE", ECBOrg.Handlers.UpdatePaymentType},
    {"PAYMENTTYPE", "DELETE", ECBOrg.Handlers.DeletePaymentType},
    {"STAFF", "CREATE", ECBOrg.Handlers.CreateStaff},
    {"STAFF", "UPDATE", ECBOrg.Handlers.UpdateStaff}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBOrg.Supervisor)
  end
end
