defmodule ECBCatalog.Application do
  @moduledoc """
  Starts the catalog app. It has no processes of its own; it registers the commands it handles with the
  platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"TAXCOMPONENT", "CREATE", ECBCatalog.Handlers.CreateTaxComponent},
    {"TAXCOMPONENT", "UPDATE", ECBCatalog.Handlers.UpdateTaxComponent},
    {"TAXGROUP", "CREATE", ECBCatalog.Handlers.CreateTaxGroup},
    {"TAXGROUP", "UPDATE", ECBCatalog.Handlers.UpdateTaxGroup},
    {"CHARGE", "CREATE", ECBCatalog.Handlers.CreateCharge},
    {"CHARGE", "UPDATE", ECBCatalog.Handlers.UpdateCharge},
    {"CHARGE", "DELETE", ECBCatalog.Handlers.DeleteCharge},
    {"RATE", "CREATE", ECBCatalog.Handlers.CreateRate},
    {"RATE", "UPDATE", ECBCatalog.Handlers.UpdateRate},
    {"FLOATINGRATE", "CREATE", ECBCatalog.Handlers.CreateFloatingRate},
    {"FLOATINGRATE", "UPDATE", ECBCatalog.Handlers.UpdateFloatingRate}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBCatalog.Supervisor)
  end
end
