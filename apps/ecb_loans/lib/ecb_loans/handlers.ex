defmodule ECBLoans.Handlers do
  @moduledoc "The commands the loans app handles, one handler per entity."

  defmodule LoanProduct do
    @moduledoc "Every action on `LOANPRODUCT`: create and update (a loan product cannot be deleted)."
    @behaviour ECBPlatform.Commands.Handler

    alias ECBLoans.LoanProducts.Write
    alias ECBPlatform.Params

    @impl true
    def process(%{action_name: "CREATE"} = command, _user),
      do: {:ok, Write.create!(Params.parse!(command.json))}

    def process(%{action_name: "UPDATE"} = command, _user),
      do: {:ok, Write.update!(command.entity_id, Params.parse!(command.json))}
  end
end
