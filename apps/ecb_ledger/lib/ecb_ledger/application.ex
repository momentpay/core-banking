defmodule ECBLedger.Application do
  @moduledoc """
  Starts the ledger app. It has no processes of its own; it registers the commands it handles with the
  platform's command pipeline.
  """
  use Application

  alias ECBPlatform.Commands.Handlers

  @commands [
    {"GLACCOUNT", "CREATE", ECBLedger.Handlers.CreateGLAccount},
    {"GLACCOUNT", "UPDATE", ECBLedger.Handlers.UpdateGLAccount},
    {"GLACCOUNT", "DELETE", ECBLedger.Handlers.DeleteGLAccount},
    {"FINANCIALACTIVITYACCOUNT", "CREATE", ECBLedger.Handlers.CreateFinancialActivityAccount},
    {"FINANCIALACTIVITYACCOUNT", "UPDATE", ECBLedger.Handlers.UpdateFinancialActivityAccount},
    {"FINANCIALACTIVITYACCOUNT", "DELETE", ECBLedger.Handlers.DeleteFinancialActivityAccount},
    {"GLCLOSURE", "CREATE", ECBLedger.Handlers.CreateGLClosure},
    {"GLCLOSURE", "UPDATE", ECBLedger.Handlers.UpdateGLClosure},
    {"GLCLOSURE", "DELETE", ECBLedger.Handlers.DeleteGLClosure},
    {"JOURNALENTRY", "CREATE", ECBLedger.Handlers.CreateJournalEntry},
    {"JOURNALENTRY", "REVERSE", ECBLedger.Handlers.ReverseJournalEntry},
    {"JOURNALENTRY", "UPDATERUNNINGBALANCE", ECBLedger.Handlers.UpdateRunningBalance},
    {"JOURNALENTRY", "DEFINEOPENINGBALANCE", ECBLedger.Handlers.DefineOpeningBalance}
  ]

  @impl true
  def start(_type, _args) do
    for {entity, action, handler} <- @commands, do: Handlers.register(entity, action, handler)

    Supervisor.start_link([], strategy: :one_for_one, name: ECBLedger.Supervisor)
  end
end
