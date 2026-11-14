defmodule ECBLedger.Handlers do
  @moduledoc """
  The command handlers of the ledger, one module per command. Each reads the request body from the command
  and calls the module that does the work; the pipeline around it checks permissions, stores the command
  and runs the handler in a transaction.
  """

  defmodule CreateGLAccount do
    @moduledoc "`CREATE` on `GLACCOUNT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBLedger.GLAccounts.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateGLAccount do
    @moduledoc "`UPDATE` on `GLACCOUNT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBLedger.GLAccounts.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule DeleteGLAccount do
    @moduledoc "`DELETE` on `GLACCOUNT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBLedger.GLAccounts.Write.delete!(command.entity_id)}
  end
end
