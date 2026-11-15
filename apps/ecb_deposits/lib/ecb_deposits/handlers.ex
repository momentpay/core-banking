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
end
