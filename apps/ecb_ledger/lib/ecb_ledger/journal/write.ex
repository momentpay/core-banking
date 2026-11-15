defmodule ECBLedger.Journal.Write do
  @moduledoc """
  Posting and reversing manual journal entries, following Fineract's
  `JournalEntryWritePlatformServiceImpl`.

  A posting has debit lines and credit lines whose sums are equal. Every line becomes one entry; all of
  them share a transaction id, which is how the posting is found again to be reversed. A posting cannot be
  dated in the future or on or before the office's latest accounting closure, and its lines may only
  touch enabled accounts that allow manual entries. Reversing a posting adds the opposite entries under a
  new transaction id and marks the originals reversed; nothing is ever deleted. Runs inside a command's
  transaction.

  Entries are inserted one line at a time, debits first, as Fineract does, so a posting refused half way
  has used up the ids of the lines already written (the rollback does not give them back).
  """
  import Ecto.Query

  alias ECBLedger.{AccountingRules, Closures, FinancialActivities, GLAccounts, Journal}
  alias ECBOrg.{Currencies, Offices, PaymentTypes}
  alias ECBPlatform.{BusinessDate, Configuration, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}

  @supported ~w(officeId transactionDate comments credits debits locale dateFormat referenceNumber
                useAccountingRule accountingRule amount currencyCode paymentTypeId accountNumber
                checkNumber routingCode receiptNumber bankNumber externalAssetOwner)

  @externalization "asset-externalization-of-non-active-loans"
  @opening_balance_activity 300
  @equity 3

  @doc "Posts the debits and credits in `params` on behalf of `user`."
  @spec create!(Params.t(), map) :: Result.t()
  def create!(%Params{} = params, user) do
    Params.check_supported!(params, @supported)
    entry = read(params)
    validate!(entry)

    {:ok, _office} = fetch_office!(entry.office_id)
    business_rules!(entry)

    payment_id = payment_detail!(params, entry.payment_type_id)
    transaction_id = transaction_id(user, entry.office_id)

    check_owner!(entry.owner)

    posting = %{entry: entry, transaction_id: transaction_id, payment_id: payment_id, user: user}

    if entry.rule do
      post_by_rule!(posting, AccountingRules.fetch!(entry.rule))
    else
      post!(posting, :debit, entry.debits)
      post!(posting, :credit, entry.credits)
    end

    Result.new(office_id: entry.office_id, transaction_id: transaction_id)
  end

  @doc "Reverses the unreversed manual entries of `transaction_id`."
  @spec reverse!(String.t(), Params.t(), map) :: Result.t()
  def reverse!(transaction_id, %Params{} = params, user) do
    entries = Journal.reversible(transaction_id)

    # a posting has at least two entries; one left over is not a posting
    if length(entries) <= 1, do: raise(Journal.transaction_not_found(transaction_id))

    Result.new(transaction_id: revert!(entries, Params.string(params, "comments"), user))
  end

  @doc """
  Sets the opening balances of an office. Debits and credits name the accounts and amounts; each line is
  matched by an entry on the contra account (the equity account mapped to the "opening balances transfer
  contra" activity), so the postings balance on their own. Any earlier opening balance of the office is
  reversed first. Only allowed while every transaction in the ledger touches the contra account, that is,
  before anything else has been posted.
  """
  @spec define_opening_balance!(Params.t(), map) :: Result.t()
  def define_opening_balance!(%Params{} = params, user) do
    Params.check_supported!(params, @supported)
    entry = read(params)
    validate!(entry)

    contra_id = FinancialActivities.mapped_account!(@opening_balance_activity).id
    check_nothing_else_posted!(contra_id)

    {:ok, _office} = fetch_office!(entry.office_id)
    business_rules!(entry)

    for transaction <- open_opening_transactions(contra_id, entry.office_id) do
      revert!(Journal.reversible(transaction), "defining opening balance", user)
    end

    transaction_id = transaction_id(user, entry.office_id)
    post_opening!(entry, :debit, entry.debits, transaction_id, contra_id, user)
    post_opening!(entry, :credit, entry.credits, transaction_id, contra_id, user)

    Result.new(office_id: entry.office_id, transaction_id: transaction_id)
  end

  # Adds the opposite entries of `entries` (one posting) under a new transaction id and marks the
  # originals reversed. Returns the new transaction id.
  defp revert!([first | _] = entries, comments, user) do
    reversal_id = transaction_id(user, first.office_id)

    Validation.new("GLJournalEntry")
    |> Validation.param("comments", comments)
    |> Validation.max_length(500)
    |> Validation.raise_if_errors!()

    check_not_closed!(first.office_id, first.entry_date)

    for entry <- entries do
      description =
        comments ||
          "Reversal entry for Journal Entry with Entry Id  :#{entry.id} and transaction Id #{entry.transaction_id}"

      id = insert_reversal!(entry, reversal_id, description, user)

      TenantRepo.update_all(from(j in "acc_gl_journal_entry", where: j.id == ^entry.id),
        set: [
          reversed: true,
          reversal_id: id,
          last_modified_by: user.id,
          last_modified_on_utc: DateTime.utc_now()
        ]
      )
    end

    reversal_id
  end

  defp revert!([], _comments, _user), do: nil

  # --- reading the request --------------------------------------------------------------------

  defp read(params) do
    locale = Params.locale(params)

    %{
      office_id: Params.long(params, "officeId"),
      currency_code: Params.string(params, "currencyCode"),
      comments: Params.string(params, "comments"),
      date: Params.date(params, "transactionDate"),
      reference: Params.string(params, "referenceNumber"),
      rule: Params.long(params, "accountingRule"),
      amount: Params.decimal_checked(params, "amount", locale),
      payment_type_id: Params.long(params, "paymentTypeId"),
      owner: Params.string(params, "externalAssetOwner"),
      credits: lines(params, "credits", locale),
      debits: lines(params, "debits", locale)
    }
  end

  # `nil` when the key is missing or not a list (Fineract then sees no lines at all)
  defp lines(params, key, locale) do
    case Params.value(params, key) do
      list when is_list(list) ->
        for line <- list, is_map(line) do
          line = %Params{map: line}

          %{
            account_id: Params.long(line, "glAccountId"),
            amount: Params.decimal_checked(line, "amount", locale),
            comments: Params.string(line, "comments")
          }
        end

      _ ->
        nil
    end
  end

  defp validate!(entry) do
    Validation.new("GLJournalEntry")
    |> Validation.param("transactionDate", entry.date)
    |> Validation.not_blank()
    |> Validation.param("officeId", entry.office_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("currencyCode", entry.currency_code)
    |> Validation.not_blank()
    |> Validation.param("comments", entry.comments)
    |> Validation.ignore_if_null()
    |> Validation.max_length(500)
    |> Validation.param("referenceNumber", entry.reference)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.param("accountingRule", entry.rule)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("paymentTypeId", entry.payment_type_id)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("externalAssetOwner", entry.owner)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> validate_lines("credits", entry.credits)
    |> validate_lines("debits", entry.debits)
    |> Validation.param("amount", number(entry.amount))
    |> Validation.ignore_if_null()
    |> Validation.zero_or_positive_amount()
    |> Validation.raise_if_errors!()
  end

  # an empty list is checked as one blank line, which reports the missing account and amount
  defp validate_lines(validation, _name, nil), do: validation

  defp validate_lines(validation, name, []),
    do: validate_line(validation, name, 0, %{account_id: nil, amount: nil})

  defp validate_lines(validation, name, lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(validation, fn {line, index}, v -> validate_line(v, name, index, line) end)
  end

  defp validate_line(validation, name, index, line) do
    validation
    |> Validation.param("#{name}[#{index}].glAccountId", line.account_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("#{name}[#{index}].amount", number(line.amount))
    |> Validation.not_null()
    |> Validation.zero_or_positive_amount()
  end

  defp number(nil), do: nil
  defp number(%Decimal{} = decimal), do: Decimal.to_float(decimal)

  # --- rules of the posting -------------------------------------------------------------------

  defp fetch_office!(office_id) do
    case Offices.get(office_id) do
      {:ok, office} -> {:ok, office}
      {:error, error} -> raise error
    end
  end

  defp business_rules!(entry) do
    if Date.compare(entry.date, BusinessDate.current()) == :gt,
      do:
        refuse(
          "error.msg.glJournalEntry.invalid.future.date",
          "The journal entry cannot be made for a future date",
          [Date.to_iso8601(entry.date), nil, nil]
        )

    check_not_closed!(entry.office_id, entry.date)

    if entry.credits in [nil, []] or entry.debits in [nil, []],
      do:
        refuse(
          "error.msg.glJournalEntry.invalid.no.debits.or.credits",
          "Journal Entry must have at least one Debit and one Credit",
          [nil, nil, nil]
        )

    unless Decimal.equal?(total(entry.credits), total(entry.debits)),
      do:
        refuse(
          "error.msg.glJournalEntry.invalid.mismatch.debits.credits",
          "Sum of All Debits must equal the sum of all Credits for a Journal Entry",
          [nil, nil, nil]
        )
  end

  defp total(lines), do: Enum.reduce(lines, Decimal.new(0), &Decimal.add(&1.amount, &2))

  # nothing may be posted, or reversed, on or before the date the office's books were closed up to
  defp check_not_closed!(office_id, date) do
    closed = Closures.closed_until(office_id)

    if closed && Date.compare(closed, date) != :lt,
      do:
        refuse(
          "error.msg.glJournalEntry.invalid.accounting.closed",
          "Journal entry cannot be made prior to last account closing date for the branch",
          [Date.to_iso8601(closed), nil, nil]
        )
  end

  defp payment_detail!(_params, nil), do: nil

  defp payment_detail!(params, payment_type_id) do
    PaymentTypes.fetch!(payment_type_id)

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_payment_detail",
        [
          %{
            payment_type_id: payment_type_id,
            account_number: Params.string(params, "accountNumber"),
            check_number: Params.string(params, "checkNumber"),
            receipt_number: Params.string(params, "receiptNumber"),
            bank_number: Params.string(params, "bankNumber"),
            routing_code: Params.string(params, "routingCode")
          }
        ],
        returning: [:id]
      )

    id
  end

  # An asset owner can only be named when asset externalisation is switched on, and there are no owners
  # yet (investors are not built), so a name is never found.
  defp check_owner!(nil), do: :ok

  defp check_owner!(owner) do
    unless Configuration.enabled?(@externalization),
      do:
        refuse(
          "error.msg.glJournalEntry.asset.externalization.not.enabled",
          "GL Journal Entry with Asset Externalization not enabled",
          []
        )

    raise ResourceNotFound,
      code: "error.msg.external.asset.owner.external.id",
      message: "External asset owner with external id: #{owner} does not found",
      args: [owner]
  end

  # --- posting by an accounting rule ----------------------------------------------------------

  # The credit side is dealt with first, then the debit side. A side the rule fixes to one account takes
  # exactly one line, on that account (and the account must take manual entries). A side the rule leaves
  # to tags takes any lines on accounts with one of its tags, and then both sides are checked against the
  # tags (Fineract checks the *other* side of a rule with a fixed account against tags too, so a rule that
  # mixes a fixed side with a tagged side cannot be posted by). The "allow several entries" flags are only
  # stored, never enforced.
  defp post_by_rule!(posting, rule) do
    entry = posting.entry

    rule_side!(posting, rule, :credit, rule.credit_account_id, entry.credits, fn ->
      check_tags!(rule, entry.credits, entry.debits)
    end)

    rule_side!(posting, rule, :debit, rule.debit_account_id, entry.debits, fn ->
      check_tags!(rule, entry.credits, entry.debits)
    end)
  end

  defp rule_side!(posting, _rule, type, nil, lines, check) do
    check.()
    post!(posting, type, lines)
  end

  defp rule_side!(posting, _rule, type, account_id, lines, _check) do
    head = GLAccounts.fetch!(account_id)
    check_account!(head)

    unless match?([%{account_id: ^account_id}], lines),
      do:
        refuse(
          "error.msg.glJournalEntry.invalid.debit.or.credit.accounts",
          "Invalid debit or credit accounts are passed",
          [nil, nil, nil]
        )

    post!(posting, type, lines)
  end

  # every line must be on an account that one of the rule's tags allows
  defp check_tags!(rule, credits, debits) do
    check_allowed!(
      rule,
      AccountingRules.credit(),
      credits,
      "error.msg.glJournalEntry.invalid.credits",
      "Invalid Credits."
    )

    check_allowed!(
      rule,
      AccountingRules.debit(),
      debits,
      "error.msg.glJournalEntry.invalid.debits",
      "Invalid Debits"
    )
  end

  defp check_allowed!(_rule, _side, nil, _code, _message), do: :ok
  defp check_allowed!(_rule, _side, [], _code, _message), do: :ok

  defp check_allowed!(rule, side, lines, code, message) do
    allowed = AccountingRules.accounts_by_tag(rule.id, side)

    matches =
      for account <- allowed, line <- lines, line.account_id == account.id, reduce: 0 do
        count -> count + 1
      end

    if matches != length(lines), do: refuse(code, message, [])
  end

  # --- opening balances -----------------------------------------------------------------------

  # Opening balances can only be defined while nothing but opening balances is posted: every transaction
  # has to touch the contra account.
  defp check_nothing_else_posted!(contra_id) do
    other =
      TenantRepo.all(
        from(j in "acc_gl_journal_entry",
          where:
            j.transaction_id not in subquery(
              from(c in "acc_gl_journal_entry",
                where: c.account_id == ^contra_id,
                select: c.transaction_id
              )
            ),
          distinct: true,
          select: j.transaction_id
        )
      )

    if other != [],
      do:
        refuse(
          "error.msg.journalentry.defining.openingbalance.not.allowed",
          "Defining Opening balances not allowed after journal entries posted",
          [other]
        )
  end

  # The office's earlier opening-balance transactions that are still standing: not reversed, and not
  # themselves the reversal of something.
  defp open_opening_transactions(contra_id, office_id) do
    reversals =
      from(r in "acc_gl_journal_entry",
        join: o in "acc_gl_journal_entry",
        on: o.reversal_id == r.id,
        where: o.reversed == true,
        select: r.transaction_id
      )

    TenantRepo.all(
      from(j in "acc_gl_journal_entry",
        where:
          j.office_id == ^office_id and j.account_id == ^contra_id and j.reversed == false and
            j.transaction_id not in subquery(reversals),
        distinct: true,
        select: j.transaction_id
      )
    )
  end

  # Each line is posted with its mirror on the contra account. A line's own comment stays in force for the
  # lines after it, as it does in Fineract.
  defp post_opening!(entry, type, lines, transaction_id, contra_id, user) do
    contra = GLAccounts.fetch!(contra_id)

    if contra.type_id != @equity,
      do:
        refuse(
          "error.msg.configuration.opening.balance.contra.account.value.is.invalid.account.type",
          "Global configuration 'office-opening-balances-contra-account' value is not an equity type account",
          [contra_id]
        )

    check_account!(contra)
    Currencies.fetch_selected!(entry.currency_code)

    Enum.reduce(lines, entry.comments, fn line, comments ->
      account = GLAccounts.fetch!(line.account_id)
      check_account!(account)
      comments = line.comments || comments

      for {account_id, kind} <- [{account.id, type}, {contra.id, mirror(type)}] do
        insert!(%{
          account_id: account_id,
          office_id: entry.office_id,
          currency_code: entry.currency_code,
          transaction_id: transaction_id,
          entry_date: entry.date,
          type_enum: type_enum(kind),
          amount: line.amount,
          description: comments,
          ref_num: nil,
          created_by: user.id,
          last_modified_by: user.id
        })
      end

      comments
    end)
  end

  defp mirror(:debit), do: :credit
  defp mirror(:credit), do: :debit

  # --- writing --------------------------------------------------------------------------------

  defp post!(%{entry: entry} = posting, type, lines) do
    Currencies.fetch_selected!(entry.currency_code)

    for line <- lines do
      account = GLAccounts.fetch!(line.account_id)
      check_account!(account)

      insert!(%{
        account_id: account.id,
        office_id: entry.office_id,
        currency_code: entry.currency_code,
        transaction_id: posting.transaction_id,
        entry_date: entry.date,
        type_enum: type_enum(type),
        amount: line.amount,
        description: line.comments || entry.comments,
        ref_num: entry.reference || "",
        payment_details_id: posting.payment_id,
        created_by: posting.user.id,
        last_modified_by: posting.user.id
      })
    end
  end

  # a posting cannot touch a disabled account or one that does not allow manual entries
  defp check_account!(%{disabled: true} = account),
    do:
      refuse(
        "error.msg.glJournalEntry.invalid.account.disabled",
        "Target account has been disabled",
        [nil, account.name, account.gl_code]
      )

  defp check_account!(%{manual_entries_allowed: false} = account),
    do:
      refuse(
        "error.msg.glJournalEntry.invalid.account.manual.adjustments.not.permitted",
        "Target account does not allow manual adjustments",
        [nil, account.name, account.gl_code]
      )

  defp check_account!(_account), do: :ok

  defp insert_reversal!(entry, transaction_id, description, user) do
    insert!(%{
      account_id: entry.account_id,
      office_id: entry.office_id,
      currency_code: entry.currency_code,
      transaction_id: transaction_id,
      entry_date: entry.entry_date,
      type_enum: opposite(entry.type),
      amount: entry.amount,
      description: description,
      ref_num: entry.reference_number,
      payment_details_id: entry.payment_details_id,
      loan_transaction_id: entry.loan_transaction_id,
      savings_transaction_id: entry.savings_transaction_id,
      client_transaction_id: entry.client_transaction_id,
      share_transaction_id: entry.share_transaction_id,
      created_by: user.id,
      last_modified_by: user.id
    })
  end

  defp insert!(values) do
    now = DateTime.utc_now()

    row =
      Map.merge(
        %{
          reversed: false,
          manual_entry: true,
          submitted_on_date: BusinessDate.current(),
          is_running_balance_calculated: false,
          office_running_balance: Decimal.new(0),
          organization_running_balance: Decimal.new(0),
          created_on_utc: now,
          last_modified_on_utc: now
        },
        values
      )

    {1, [%{id: id}]} = TenantRepo.insert_all("acc_gl_journal_entry", [row], returning: [:id])
    id
  end

  defp type_enum(:debit), do: Journal.debit()
  defp type_enum(:credit), do: Journal.credit()

  defp opposite(type) do
    if type == Journal.debit(), do: Journal.credit(), else: Journal.debit()
  end

  # What Fineract does: the time in milliseconds, the user's id and the office's id written one after
  # another as a number, in hexadecimal. Fineract can give two postings made in the same millisecond the same
  # id, which would merge them for ever (a reversal takes both back). An id already in the books is skipped
  # here by moving to the next millisecond.
  defp transaction_id(user, office_id),
    do: unused_transaction_id(System.os_time(:millisecond), user, office_id)

  defp unused_transaction_id(millis, user, office_id) do
    id =
      "#{millis}#{user.id}#{office_id}"
      |> String.to_integer()
      |> Integer.to_string(16)
      |> String.downcase()

    if TenantRepo.exists?(from(j in "acc_gl_journal_entry", where: j.transaction_id == ^id)),
      do: unused_transaction_id(millis + 1, user, office_id),
      else: id
  end

  defp refuse(code, message, args),
    do: raise(DomainRuleViolation, code: code, message: message, args: args)
end
