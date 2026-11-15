defmodule ECBParty.Handlers do
  @moduledoc "The commands the customer master handles, one handler per entity."

  defmodule Client do
    @moduledoc """
    Every action on `CLIENT`: create, update, delete and the life-cycle commands. The action names are
    Fineract's, so the permission needed is `<ACTION>_CLIENT`.
    """
    @behaviour ECBPlatform.Commands.Handler

    alias ECBParty.Clients.Write
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Write.create!(user, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user),
      do: {:ok, Write.update!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, _user),
      do: {:ok, Write.delete!(command.entity_id)}

    def process(%{action_name: action} = command, user) do
      {:ok, life_cycle(action, user, command.entity_id, Params.parse!(command.json))}
    end

    defp life_cycle("ACTIVATE", user, id, p), do: Write.activate!(user, id, p)
    defp life_cycle("CLOSE", user, id, p), do: Write.close!(user, id, p)
    defp life_cycle("REJECT", user, id, p), do: Write.reject!(user, id, p)
    defp life_cycle("WITHDRAW", user, id, p), do: Write.withdraw!(user, id, p)
    defp life_cycle("REACTIVATE", user, id, p), do: Write.reactivate!(user, id, p)
    defp life_cycle("UNDOREJECT", user, id, p), do: Write.undo_rejection!(user, id, p)
    defp life_cycle("UNDOWITHDRAWAL", user, id, p), do: Write.undo_withdrawal!(user, id, p)
    defp life_cycle("ASSIGNSTAFF", user, id, p), do: Write.assign_staff!(user, id, p)
    defp life_cycle("UNASSIGNSTAFF", user, id, p), do: Write.unassign_staff!(user, id, p)
  end

  defmodule ClientIdentifier do
    @moduledoc "Every action on `CLIENTIDENTIFIER`; the client is `client_id`, an identifier `entity_id`."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBParty.Identifiers
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Identifiers.create!(user, command.client_id, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user) do
      {:ok,
       Identifiers.update!(
         user,
         command.client_id,
         command.entity_id,
         Params.parse!(command.json)
       )}
    end

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, Identifiers.delete!(user, command.client_id, command.entity_id)}
  end

  defmodule FamilyMembers do
    @moduledoc "Every action on `FAMILYMEMBERS`; a client is `client_id`, a family member `entity_id`."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBParty.FamilyMembers
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, _user),
      do: {:ok, FamilyMembers.create!(command.client_id, Params.parse_typed!(command.json))}

    def process(%{action_name: "UPDATE"} = command, _user),
      do: {:ok, FamilyMembers.update!(command.entity_id, Params.parse_typed!(command.json))}

    def process(%{action_name: "DELETE"} = command, _user),
      do: {:ok, FamilyMembers.delete!(command.entity_id)}
  end
end
