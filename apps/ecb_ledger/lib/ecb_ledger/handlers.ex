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

  defmodule CreateFinancialActivityAccount do
    @moduledoc "`CREATE` on `FINANCIALACTIVITYACCOUNT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBLedger.FinancialActivities.Write.create!(ECBPlatform.Params.parse!(command.json))}
  end

  defmodule UpdateFinancialActivityAccount do
    @moduledoc "`UPDATE` on `FINANCIALACTIVITYACCOUNT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do:
        {:ok,
         ECBLedger.FinancialActivities.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json)
         )}
  end

  defmodule DeleteFinancialActivityAccount do
    @moduledoc "`DELETE` on `FINANCIALACTIVITYACCOUNT`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBLedger.FinancialActivities.Write.delete!(command.entity_id)}
  end

  defmodule CreateGLClosure do
    @moduledoc "`CREATE` on `GLCLOSURE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do: {:ok, ECBLedger.Closures.Write.create!(ECBPlatform.Params.parse!(command.json), user)}
  end

  defmodule UpdateGLClosure do
    @moduledoc "`UPDATE` on `GLCLOSURE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBLedger.Closures.Write.update!(
           command.entity_id,
           ECBPlatform.Params.parse!(command.json),
           user
         )}
  end

  defmodule DeleteGLClosure do
    @moduledoc "`DELETE` on `GLCLOSURE`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, _user),
      do: {:ok, ECBLedger.Closures.Write.delete!(command.entity_id)}
  end

  defmodule CreateJournalEntry do
    @moduledoc "`CREATE` on `JOURNALENTRY`: posts a balanced set of debits and credits."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do: {:ok, ECBLedger.Journal.Write.create!(ECBPlatform.Params.parse!(command.json), user)}
  end

  defmodule ReverseJournalEntry do
    @moduledoc "`REVERSE` on `JOURNALENTRY`: reverses the manual entries of one transaction."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBLedger.Journal.Write.reverse!(
           command.transaction_id,
           ECBPlatform.Params.parse!(command.json),
           user
         )}
  end

  defmodule UpdateRunningBalance do
    @moduledoc "`UPDATERUNNINGBALANCE` on `JOURNALENTRY`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBLedger.Journal.RunningBalance.update!(ECBPlatform.Params.parse!(command.json), user)}
  end

  defmodule DefineOpeningBalance do
    @moduledoc "`DEFINEOPENINGBALANCE` on `JOURNALENTRY`."
    @behaviour ECBPlatform.Commands.Handler

    @impl true
    def process(command, user),
      do:
        {:ok,
         ECBLedger.Journal.Write.define_opening_balance!(
           ECBPlatform.Params.parse!(command.json),
           user
         )}
  end
end
