defmodule ECBLedger.Journal.RunningBalance do
  @moduledoc """
  Running balances of journal entries, following Fineract's `JournalEntryRunningBalanceUpdateServiceImpl`.

  Posting does not work out a balance. Entries start with a balance of zero and
  `is_running_balance_calculated` false, and this command catches up from the earliest date that has an
  entry waiting:

    * for the whole organisation (no office given) it recomputes every entry from that date: the balance of
      the account across all offices and the balance of the account in the entry's office, and marks the
      entries calculated;
    * for one office it recomputes only that office's balance, from the earliest waiting date of that office,
      and leaves the entries marked as they were, so the organisation's balance stays at zero until an
      organisation-wide run.

  Either way an entry's balance is the balance before it, the balance of the last entry of the account on an
  earlier date, plus or minus its amount, in entry-date then id order: assets and expenses grow with debits,
  liabilities, equity and income with credits. Runs inside a command's transaction.
  """
  alias ECBOrg.Offices
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.{Params, TenantRepo, Validation}

  # what an entry adds to the balance of its account: its amount when it is on the account's growing side
  @signed """
  CASE WHEN (a.classification_enum IN (1, 5) AND j.type_enum = 2)
            OR (a.classification_enum IN (2, 3, 4) AND j.type_enum = 1)
       THEN j.amount ELSE -j.amount END
  """

  @organisation """
  WITH waiting AS (
    SELECT MIN(entry_date) AS date FROM acc_gl_journal_entry WHERE is_running_balance_calculated = false
  ),
  organisation_start AS (
    SELECT DISTINCT ON (account_id) account_id, organization_running_balance AS balance
    FROM acc_gl_journal_entry, waiting WHERE entry_date < waiting.date
    ORDER BY account_id, entry_date DESC, id DESC
  ),
  office_start AS (
    SELECT DISTINCT ON (office_id, account_id) office_id, account_id, office_running_balance AS balance
    FROM acc_gl_journal_entry, waiting WHERE entry_date < waiting.date
    ORDER BY office_id, account_id, entry_date DESC, id DESC
  ),
  recomputed AS (
    SELECT j.id, j.account_id, j.office_id,
           SUM(#{@signed}) OVER (PARTITION BY j.account_id ORDER BY j.entry_date, j.id) AS organisation_change,
           SUM(#{@signed}) OVER (PARTITION BY j.office_id, j.account_id ORDER BY j.entry_date, j.id) AS office_change
    FROM acc_gl_journal_entry j
    JOIN acc_gl_account a ON a.id = j.account_id, waiting
    WHERE j.entry_date >= waiting.date
  )
  UPDATE acc_gl_journal_entry u
  SET is_running_balance_calculated = true,
      organization_running_balance = COALESCE(os.balance, 0) + r.organisation_change,
      office_running_balance = COALESCE(fs.balance, 0) + r.office_change,
      last_modified_by = $1,
      last_modified_on_utc = now()
  FROM recomputed r
  LEFT JOIN organisation_start os ON os.account_id = r.account_id
  LEFT JOIN office_start fs ON fs.office_id = r.office_id AND fs.account_id = r.account_id
  WHERE u.id = r.id
  """

  @office """
  WITH waiting AS (
    SELECT MIN(entry_date) AS date FROM acc_gl_journal_entry
    WHERE is_running_balance_calculated = false AND office_id = $2
  ),
  office_start AS (
    SELECT DISTINCT ON (account_id) account_id, office_running_balance AS balance
    FROM acc_gl_journal_entry, waiting WHERE office_id = $2 AND entry_date < waiting.date
    ORDER BY account_id, entry_date DESC, id DESC
  ),
  recomputed AS (
    SELECT j.id, j.account_id,
           SUM(#{@signed}) OVER (PARTITION BY j.account_id ORDER BY j.entry_date, j.id) AS office_change
    FROM acc_gl_journal_entry j
    JOIN acc_gl_account a ON a.id = j.account_id, waiting
    WHERE j.office_id = $2 AND j.entry_date >= waiting.date
  )
  UPDATE acc_gl_journal_entry u
  SET office_running_balance = COALESCE(fs.balance, 0) + r.office_change,
      last_modified_by = $1,
      last_modified_on_utc = now()
  FROM recomputed r
  LEFT JOIN office_start fs ON fs.account_id = r.account_id
  WHERE u.id = r.id
  """

  @doc "Brings the running balances up to date for `office_id` in `params`, or for everything when it is absent."
  @spec update!(Params.t(), map) :: Result.t()
  def update!(%Params{} = params, user) do
    Params.check_supported!(params, ["officeId"])
    office_id = office_id!(params)

    case office_id do
      nil ->
        TenantRepo.query!(@organisation, [user.id])

      id ->
        case Offices.get(id) do
          {:ok, _office} -> :ok
          {:error, error} -> raise error
        end

        TenantRepo.query!(@office, [user.id, id])
    end

    Result.new(office_id: office_id)
  end

  # the office id is read as text, so that text which is not a number is reported as one
  defp office_id!(params) do
    {value, number?} =
      case Params.string(params, "officeId") do
        nil ->
          {nil, true}

        text ->
          case Integer.parse(String.trim(text)) do
            {number, ""} -> {number, true}
            _ -> {nil, false}
          end
      end

    validation =
      Validation.new("GLJournalEntry")
      |> Validation.param("officeId", value)
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()

    validation =
      if number?,
        do: validation,
        else:
          Validation.fail(
            validation,
            "not.a.number",
            "The parameter `officeId` must be a number.",
            []
          )

    Validation.raise_if_errors!(validation)
    value
  end
end
