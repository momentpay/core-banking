defmodule ECBLedger.TenantRepo.Migrations.AddJournalIndexes do
  @moduledoc """
  Indexes the journal needs to stay fast as it grows; Fineract's schema has none for these lookups (it
  already indexes the transaction id).

  Listings by office and date, and balances by account and date, would otherwise read the whole table. The
  partial index lets the running-balance command find the entries waiting for it without a scan.
  """
  use Ecto.Migration

  def up do
    execute(
      "CREATE INDEX idx_acc_gl_journal_entry_office_date ON public.acc_gl_journal_entry (office_id, entry_date, id)"
    )

    execute(
      "CREATE INDEX idx_acc_gl_journal_entry_account_date ON public.acc_gl_journal_entry (account_id, entry_date, id)"
    )

    execute(
      "CREATE INDEX idx_acc_gl_journal_entry_balance_waiting ON public.acc_gl_journal_entry (entry_date) WHERE is_running_balance_calculated = false"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS public.idx_acc_gl_journal_entry_balance_waiting")
    execute("DROP INDEX IF EXISTS public.idx_acc_gl_journal_entry_account_date")
    execute("DROP INDEX IF EXISTS public.idx_acc_gl_journal_entry_office_date")
  end
end
