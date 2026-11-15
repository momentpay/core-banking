defmodule ECBParty.Application do
  @moduledoc """
  Starts the customer-master app. It has no processes of its own; it registers the commands it handles with
  the platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"CLIENT", "CREATE", ECBParty.Handlers.Client},
    {"CLIENT", "UPDATE", ECBParty.Handlers.Client},
    {"CLIENT", "DELETE", ECBParty.Handlers.Client},
    {"CLIENT", "ACTIVATE", ECBParty.Handlers.Client},
    {"CLIENT", "CLOSE", ECBParty.Handlers.Client},
    {"CLIENT", "REJECT", ECBParty.Handlers.Client},
    {"CLIENT", "WITHDRAW", ECBParty.Handlers.Client},
    {"CLIENT", "REACTIVATE", ECBParty.Handlers.Client},
    {"CLIENT", "UNDOREJECT", ECBParty.Handlers.Client},
    {"CLIENT", "UNDOWITHDRAWAL", ECBParty.Handlers.Client},
    {"CLIENT", "ASSIGNSTAFF", ECBParty.Handlers.Client},
    {"CLIENT", "UNASSIGNSTAFF", ECBParty.Handlers.Client},
    {"CLIENTIDENTIFIER", "CREATE", ECBParty.Handlers.ClientIdentifier},
    {"CLIENTIDENTIFIER", "UPDATE", ECBParty.Handlers.ClientIdentifier},
    {"CLIENTIDENTIFIER", "DELETE", ECBParty.Handlers.ClientIdentifier},
    {"FAMILYMEMBERS", "CREATE", ECBParty.Handlers.FamilyMembers},
    {"FAMILYMEMBERS", "UPDATE", ECBParty.Handlers.FamilyMembers},
    {"FAMILYMEMBERS", "DELETE", ECBParty.Handlers.FamilyMembers}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBParty.Supervisor)
  end
end
