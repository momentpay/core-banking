defmodule ECBDeposits.Handlers do
  @moduledoc "The commands the deposits app handles, one handler per entity."

  defmodule SavingsProduct do
    @moduledoc "Every action on `SAVINGSPRODUCT`: create, update and delete."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.SavingsProducts.Write
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, _user),
      do: {:ok, Write.create!(Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, _user),
      do: {:ok, Write.update!(command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, _user),
      do: {:ok, Write.delete!(command.entity_id)}
  end

  defmodule SavingsAccount do
    @moduledoc """
    Every action on `SAVINGSACCOUNT` so far: apply, change and delete an application, approve it, take the approval
    back, reject it, withdraw it, activate the account and close it.
    """
    @behaviour ECBPlatform.Commands.Handler

    alias ECBDeposits.Savings.{Submit, Transitions}
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, user),
      do: {:ok, Submit.create!(user, Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, user),
      do: {:ok, Submit.modify!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "DELETE"} = command, user),
      do: {:ok, Submit.delete!(user, command.entity_id)}

    def process(%{action_name: "APPROVE"} = command, user),
      do: {:ok, Transitions.approve!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "APPROVALUNDO"} = command, user),
      do: {:ok, Transitions.undo_approval!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "REJECT"} = command, user),
      do: {:ok, Transitions.reject!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "WITHDRAW"} = command, user),
      do: {:ok, Transitions.withdraw!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "ACTIVATE"} = command, user),
      do: {:ok, Transitions.activate!(user, command.entity_id, Params.parse!(command.json))}

    def process(%{action_name: "CLOSE"} = command, user),
      do: {:ok, Transitions.close!(user, command.entity_id, Params.parse!(command.json))}
  end
end
