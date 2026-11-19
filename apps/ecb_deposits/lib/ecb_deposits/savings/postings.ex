defmodule ECBDeposits.Savings.Postings do
  @moduledoc """
  Money into and out of a savings account: deposits, withdrawals, undoing and reversing a transaction and changing
  one, after Fineract's `SavingsAccountWritePlatformServiceJpaRepositoryImpl` (`deposit`, `withdrawal`,
  `undoTransaction`, `reverseTransaction`, `adjustSavingsTransaction`), `SavingsAccountDomainServiceJpa` and the
  rules of `SavingsAccount.deposit` and `withdraw`.

  An account that earns or owes interest is refused for now: Fineract calculates it after every transaction, and
  that is the next slice. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.{Balance, Journal, Transactions, Transitions}
  alias ECBPlatform.{BusinessDate, Integrity, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors

  alias ECBPlatform.Errors.{
    DomainRuleViolation,
    PlatformApiDataValidation,
    PlatformServiceUnavailable
  }

  alias ECBPlatform.Params.DatePattern

  @deposit 1
  @withdrawal 2
  @active 300
  @note_savings_transaction 800

  @supported ~w(locale dateFormat externalId transactionDate transactionAmount paymentTypeId accountNumber checkNumber
                routingCode receiptNumber bankNumber retailEntries childAccountId note amount date isManualTransaction
                lienTransaction chargesPaidByData submittedOnDate accountId accountNo)

  @payment_fields ~w(accountNumber checkNumber routingCode receiptNumber bankNumber)

  # --- the commands ---------------------------------------------------------------------------------

  @doc "Deposits money into account `id`."
  @spec deposit!(struct, integer, Params.t()) :: Result.t()
  def deposit!(user, id, %Params{} = p) do
    req = request!(p)
    account = Transitions.account!(id)
    refuse_interest!(account)
    {detail_id, changes} = payment_detail!(p)

    check_open!(account, req, p)
    tx_id = insert_tx!(user, account, @deposit, req, detail_id)
    note!(user, account, tx_id, Params.string(p, "note"))
    result(account, tx_id, changes)
  end

  @doc "Withdraws money from account `id`; `force?` lets a forced withdrawal take the balance below what is allowed."
  @spec withdraw!(struct, integer, Params.t(), boolean) :: Result.t()
  def withdraw!(user, id, %Params{} = p, force? \\ false) do
    req = request!(p)
    {detail_id, changes} = payment_detail!(p)
    account = Transitions.account!(id)
    refuse_interest!(account)

    check_open!(account, req, p)
    check_lock_in!(account, req, p)
    tx_id = withdraw_row!(user, account, req, detail_id, force?: force?, amount: req.amount)
    note!(user, account, tx_id, Params.string(p, "note"))
    result(account, tx_id, changes)
  end

  @doc """
  The deposit of the minimum opening balance when an account is activated. It is made on the day of activation,
  with no payment detail.
  """
  @spec opening_deposit!(struct, map, Date.t(), Decimal.t()) :: :ok
  def opening_deposit!(user, account, on, amount) do
    refuse_interest!(account)

    req = %{date: on, amount: amount, external_id: nil}
    insert_tx!(user, account, @deposit, req, nil)
    :ok
  end

  @doc """
  Withdraws what is left in the account when it is closed, on the day of closing, as Fineract does for
  `withdrawBalance`: whatever the account's rules for its balance, it goes to nothing.
  """
  @spec closing_withdrawal!(struct, map, Params.t(), Date.t()) :: map
  def closing_withdrawal!(user, account, %Params{} = p, on) do
    refuse_interest!(account)
    {detail_id, changes} = payment_detail!(p)
    req = %{date: on, amount: account.account_balance_derived, external_id: nil}

    check_open!(account, req, p)
    check_lock_in!(account, req, p)
    withdraw_row!(user, account, req, detail_id, exception?: true, amount: req.amount)
    changes
  end

  @doc "Undoes a transaction: it counts for nothing from now on, and its entries in the books are posted the other way."
  @spec undo!(struct, integer, integer) :: Result.t()
  def undo!(user, id, tx_id) do
    account = Transitions.account!(id)
    tx = Transactions.get(id, tx_id) || raise(Transactions.not_found(id, tx_id))
    refuse_interest!(account)
    check_active_for!(account, "undotransaction")

    if tx.is_reversed != true do
      mark_reversed!(account, tx)
      check_balance_after!(account, "undotransaction")
      reverse_entries!(user, account, tx)
    end

    check_balance_after!(account, "undotransaction")
    result(account, id, %{})
  end

  @doc "Reverses a transaction: undoes it and puts a reversal in its place."
  @spec reverse!(struct, integer, integer) :: Result.t()
  def reverse!(user, id, tx_id) do
    account = Transitions.account!(id)
    tx = live_tx!(id, tx_id)
    refuse_interest!(account)
    check_active_for!(account, "undotransaction")

    mark_reversed!(account, tx)
    check_balance_after!(account, "undotransaction")
    reversal_id = insert_reversal!(user, account, tx)
    reverse_entries!(user, account, tx)

    Result.new(
      resource_id: reversal_id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      savings_id: id
    )
  end

  @doc "Changes a deposit or a withdrawal: undoes it and makes the one asked for."
  @spec adjust!(struct, integer, integer, Params.t()) :: Result.t()
  def adjust!(user, id, tx_id, %Params{} = p) do
    tx = Transactions.get(id, tx_id) || raise Transactions.not_found(id, tx_id)

    if tx.transaction_type_enum not in [@deposit, @withdrawal] or tx.is_reversed == true,
      do: raise(update_not_allowed(id, tx_id))

    req = request!(p)
    {detail_id, changes} = payment_detail!(p)
    account = Transitions.account!(id)
    refuse_interest!(account)
    check_active_for!(account, "adjusttransaction")

    mark_reversed!(account, tx)
    check_open!(account, req, p)

    if tx.transaction_type_enum == @withdrawal, do: check_lock_in!(account, req, p)
    new_id = insert_tx!(user, account, tx.transaction_type_enum, req, detail_id, entries?: false)

    check_balance_after!(account, "adjusttransaction")
    reverse_entries!(user, account, tx)
    post_entries!(user, account, new_id, tx.transaction_type_enum, req, detail_id)
    result(account, new_id, changes)
  end

  # --- the request ----------------------------------------------------------------------------------

  defp request!(p) do
    Params.check_supported!(p, @supported)
    date = Params.date(p, "transactionDate")
    amount = Params.decimal_with_locale(p, "transactionAmount")
    external_id = Params.string(p, "externalId")
    type_id = Params.integer_with_locale(p, "paymentTypeId")

    Validation.new("savingsaccount.transaction")
    |> Validation.param("transactionDate", date)
    |> Validation.not_null()
    |> Validation.param("transactionAmount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> Validation.param("externalId", external_id)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.param("paymentTypeId", type_id)
    |> Validation.not_null()
    |> payment_type_details(p, type_id)
    |> Validation.raise_if_errors!()

    %{date: date, amount: amount, external_id: external_id}
  end

  @doc false
  @spec payment_type_details(Validation.t(), Params.t(), integer | nil) :: Validation.t()
  def payment_type_details(v, p, type_id) do
    v =
      v
      |> Validation.param("paymentTypeId", type_id)
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()

    v =
      Enum.reduce(@payment_fields, v, fn name, v ->
        v
        |> Validation.param(name, Params.string(p, name))
        |> Validation.ignore_if_null()
        |> Validation.max_length(50)
      end)

    if Enum.any?(@payment_fields, &(Params.string(p, &1) not in [nil, ""])),
      do:
        v
        |> Validation.param("paymentTypeId", type_id)
        |> Validation.not_blank()
        |> Validation.greater_than_zero(),
      else: v
  end

  # the payment detail of a request, stored, and what it adds to the answer's changes
  @doc false
  @spec payment_detail!(Params.t()) :: {integer | nil, map}
  def payment_detail!(p) do
    type_id = Params.integer_with_locale(p, "paymentTypeId")
    given = Enum.filter(@payment_fields, &(Params.string(p, &1) not in [nil, ""]))

    if type_id == nil and given == [] do
      {nil, %{}}
    else
      ECBOrg.PaymentTypes.fetch!(type_id)

      {1, [%{id: id}]} =
        TenantRepo.insert_all(
          "m_payment_detail",
          [
            %{
              payment_type_id: type_id,
              account_number: Params.string(p, "accountNumber") || "",
              check_number: Params.string(p, "checkNumber") || "",
              receipt_number: Params.string(p, "receiptNumber") || "",
              bank_number: Params.string(p, "bankNumber") || "",
              routing_code: Params.string(p, "routingCode") || ""
            }
          ],
          returning: [:id]
        )

      changes = Map.new(given, &{&1, Params.string(p, &1)})
      {id, Map.put(changes, "paymentTypeId", type_id)}
    end
  end

  @doc "The date of the last transaction of the account, reversed ones too, or `nil`."
  @spec last_transaction_date(integer) :: Date.t() | nil
  def last_transaction_date(account_id),
    do:
      TenantRepo.one(
        from(t in "m_savings_account_transaction",
          where: t.savings_account_id == ^account_id,
          select: max(t.transaction_date)
        )
      )

  # --- the rules of the account ---------------------------------------------------------------------

  defp refuse_interest!(account) do
    if Balance.interest_bearing?(account) do
      raise DomainRuleViolation,
        code: "error.msg.savingsaccount.feature.not.supported.yet",
        message:
          "Money in and out of an account that earns or owes interest is not supported yet by E-CoreBank",
        args: ["nominalAnnualInterestRate"]
    end
  end

  # what `SavingsAccount.deposit` and `withdraw` ask before anything else: an active account, a date in the past and
  # not before the account was activated
  defp check_open!(account, req, p) do
    pattern = Params.date_format(p)
    text = DatePattern.format(req.date, pattern)

    cond do
      account.status_enum != @active ->
        date_error!(
          "error.msg.savingsaccount.transaction.account.is.not.active",
          "Transaction is not allowed. Account is not active.",
          text,
          []
        )

      Date.compare(req.date, BusinessDate.current()) == :gt ->
        date_error!(
          "error.msg.savingsaccount.transaction.in.the.future",
          "Transaction date cannot be in the future.",
          text,
          []
        )

      Date.compare(req.date, account.activatedon_date) == :lt ->
        raise_errors!([
          Errors.parameter_error(
            "error.msg.savingsaccount.transaction.before.activation.date",
            "Transaction date cannot be before accounts activation date.",
            "transactionDate",
            [text, DatePattern.format(account.activatedon_date, pattern)]
          )
        ])

      true ->
        :ok
    end
  end

  defp check_lock_in!(%{lockedin_until_date_derived: nil}, _req, _p), do: :ok

  defp check_lock_in!(account, req, p) do
    until = account.lockedin_until_date_derived

    if Date.compare(req.date, until) == :lt do
      pattern = Params.date_format(p)

      date_error!(
        "error.msg.savingsaccount.transaction.withdrawals.blocked.during.lockin.period",
        "Withdrawal is not allowed. No withdrawals are allowed until after " <>
          DatePattern.format(until, pattern),
        DatePattern.format(req.date, pattern),
        [DatePattern.format(until, pattern)]
      )
    end
  end

  defp check_active_for!(account, action) do
    if account.status_enum != @active do
      Validation.new("savingsaccount." <> action)
      |> Validation.fail_without_parameter("account.is.not.active")
      |> Map.update!(:errors, fn [e | rest] ->
        [Map.merge(e, %{parameter: nil, args: []}) | rest]
      end)
      |> Validation.raise_if_errors!()
    end
  end

  defp raise_errors!(errors), do: raise(%PlatformApiDataValidation{errors: errors})

  # Fineract names these errors with the date where the parameter should be, and "transactionDate" as the message for
  # the user
  defp date_error!(code, message, date_text, args) do
    raise_errors!([
      Map.put(
        Errors.parameter_error(code, message, date_text, args),
        :default_message,
        "transactionDate"
      )
    ])
  end

  defp update_not_allowed(account_id, tx_id),
    do: %PlatformServiceUnavailable{
      code: "error.msg.saving.account.trasaction.update.notallowed",
      message:
        "Savings Account transaction update not allowed with savings identifier #{account_id} and trasaction identifier #{tx_id}",
      args: [account_id, tx_id]
    }

  # --- the rows -------------------------------------------------------------------------------------

  # a transaction of the account that has not been undone, or the error for one that is not there
  defp live_tx!(account_id, tx_id) do
    case Transactions.get(account_id, tx_id) do
      %{is_reversed: false} = tx -> tx
      _ -> raise Transactions.not_found(account_id, tx_id)
    end
  end

  # a withdrawal is first tried against the rules for the balance
  defp withdraw_row!(user, account, req, detail_id, opts) do
    live =
      Balance.live(account.id) ++
        [%{id: :infinity, type: @withdrawal, date: req.date, amount: req.amount}]

    Balance.check!(account, Enum.sort_by(live, &{&1.date, &1.id}), opts)
    insert_tx!(user, account, @withdrawal, req, detail_id)
  end

  defp insert_tx!(user, account, type, req, detail_id, opts \\ []) do
    now = DateTime.utc_now()

    id =
      Integrity.translate(
        fn ->
          {1, [%{id: id}]} =
            TenantRepo.insert_all(
              "m_savings_account_transaction",
              [
                %{
                  savings_account_id: account.id,
                  office_id: account.client_office_id,
                  payment_detail_id: detail_id,
                  transaction_type_enum: type,
                  is_reversed: false,
                  transaction_date: req.date,
                  amount: req.amount,
                  created_date: NaiveDateTime.utc_now(),
                  created_by: user.id,
                  is_manual: false,
                  ref_no: Ecto.UUID.generate(),
                  is_reversal: false,
                  is_lien_transaction: false,
                  submitted_on_date: BusinessDate.current(),
                  last_modified_by: user.id,
                  created_on_utc: now,
                  last_modified_on_utc: now,
                  external_id: req.external_id
                }
              ],
              returning: [:id]
            )

          id
        end,
        %{
          "uk_m_sat_external_id" =>
            {"error.msg.data.integrity.issue",
             "ERROR: duplicate key value violates unique constraint \"uk_m_sat_external_id\"\n  Detail: Key (external_id)=(#{req.external_id}) already exists.",
             nil, []}
        },
        {"error.msg.data.integrity.issue",
         "Data integrity issue with a savings account transaction."}
      )

    Balance.refresh!(account.id)

    if Keyword.get(opts, :entries?, true),
      do: post_entries!(user, account, id, type, req, detail_id)

    touch_account!(user, account)
    id
  end

  defp post_entries!(user, account, id, type, req, detail_id) do
    Journal.post!(user, account, %{
      id: id,
      type: type,
      date: req.date,
      amount: req.amount,
      payment_detail_id: detail_id,
      overdraft: overdraft_part(id, type, req.amount)
    })
  end

  # the part of a transaction that takes the account below nothing (a withdrawal) or pays back what it is below
  # (a deposit), by the balance it left
  defp overdraft_part(id, type, amount) do
    balance =
      TenantRepo.one(
        from(t in "m_savings_account_transaction",
          where: t.id == ^id,
          select: t.running_balance_derived
        )
      )

    case {type, balance} do
      {_, nil} -> Decimal.new(0)
      {1, after_} -> part(Decimal.sub(after_, amount), amount)
      {2, after_} -> part(after_, amount)
    end
  end

  # `balance` is what the account held when the money was taken out, or before it was put in
  defp part(balance, amount),
    do:
      if(Decimal.lt?(balance, 0),
        do: Decimal.min(amount, Decimal.negate(balance)),
        else: Decimal.new(0)
      )

  # the transaction counts for nothing from now on
  defp mark_reversed!(account, tx) do
    TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id == ^tx.id),
      set: [is_reversed: true]
    )

    Balance.refresh!(account.id)
  end

  # and its entries in the books are posted the other way
  defp reverse_entries!(user, account, tx) do
    Journal.reverse!(user, account, tx.id)
    touch_account!(user, account)
  end

  defp insert_reversal!(user, account, tx) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_savings_account_transaction",
        [
          %{
            savings_account_id: account.id,
            office_id: account.client_office_id,
            payment_detail_id: tx.payment_detail_id,
            transaction_type_enum: tx.transaction_type_enum,
            is_reversed: false,
            transaction_date: tx.transaction_date,
            amount: tx.amount,
            created_date: NaiveDateTime.utc_now(),
            created_by: user.id,
            is_manual: false,
            ref_no: Ecto.UUID.generate(),
            original_transaction_id: tx.id,
            is_reversal: true,
            is_lien_transaction: false,
            submitted_on_date: BusinessDate.current(),
            last_modified_by: user.id,
            created_on_utc: now,
            last_modified_on_utc: now
          }
        ],
        returning: [:id]
      )

    id
  end

  # an undone or changed transaction must not leave the account with less than it may have
  defp check_balance_after!(account, action) do
    Balance.check!(account, Balance.live(account.id), amount: nil)
  rescue
    DomainRuleViolation -> Balance.going_negative!(action)
  end

  defp touch_account!(user, account) do
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^account.id),
      set: [last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]
    )
  end

  defp note!(_user, _account, _tx_id, nil), do: :ok

  defp note!(user, account, tx_id, note) do
    if String.trim(note) != "" do
      now = DateTime.utc_now()

      TenantRepo.insert_all("m_note", [
        %{
          savings_account_id: account.id,
          savings_account_transaction_id: tx_id,
          client_id: account.client_id,
          note_type_enum: @note_savings_transaction,
          note: note,
          created_by: user.id,
          created_on_utc: now,
          last_modified_by: user.id,
          last_modified_on_utc: now
        }
      ])
    end

    :ok
  end

  defp result(account, id, changes) do
    Result.new(
      resource_id: id,
      savings_id: account.id,
      office_id: account.client_office_id,
      client_id: account.client_id,
      changes: if(changes == %{}, do: nil, else: changes)
    )
  end
end
