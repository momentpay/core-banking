defmodule ECBDeposits.Savings.Postings do
  @moduledoc """
  Money into and out of a savings account: deposits, withdrawals, undoing and reversing a transaction and changing
  one, after Fineract's `SavingsAccountWritePlatformServiceJpaRepositoryImpl` (`deposit`, `withdrawal`,
  `undoTransaction`, `reverseTransaction`, `adjustSavingsTransaction`), `SavingsAccountDomainServiceJpa` and the
  rules of `SavingsAccount.deposit` and `withdraw`.

  Every change to the transactions of an account is followed, as in Fineract, by the working out of the interest
  the account has earned and, when the change falls before interest already posted, by posting it again
  (`ECBDeposits.Savings.Interest`). Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.{
    Balance,
    Blocks,
    Charges,
    Interest,
    Journal,
    Transactions,
    Transitions
  }

  alias ECBDeposits.Savings.Interest.Calc
  alias ECBPlatform.{BusinessDate, Configuration, Integrity, Params, TenantRepo, Validation}
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
    {detail_id, changes} = payment_detail!(p)

    Blocks.check_transaction!(account, :credit)
    check_open!(account, req, p)
    tx_id = add_tx!(user, account, @deposit, req, detail_id)
    wake!(account)
    note!(user, account, tx_id, Params.string(p, "note"))
    result(account, tx_id, changes)
  end

  @doc "Withdraws money from account `id`; `force?` lets a forced withdrawal take the balance below what is allowed."
  @spec withdraw!(struct, integer, Params.t(), boolean) :: Result.t()
  def withdraw!(user, id, %Params{} = p, force? \\ false) do
    req = request!(p)
    {detail_id, changes} = payment_detail!(p)
    account = Transitions.account!(id)

    Blocks.check_transaction!(account, :debit)
    check_open!(account, req, p)
    check_lock_in!(account, req, p)

    tx_id =
      add_tx!(user, account, @withdrawal, req, detail_id,
        check: [force?: force?, amount: req.amount, hold: account.savings_on_hold]
      )

    wake!(account)
    note!(user, account, tx_id, Params.string(p, "note"))
    result(account, tx_id, changes)
  end

  # an account that was inactive or dormant is active again once money moves in or out
  defp wake!(account) do
    TenantRepo.update_all(
      from(a in "m_savings_account",
        where: a.id == ^account.id and a.sub_status_enum in [100, 200]
      ),
      set: [sub_status_enum: 0]
    )
  end

  @doc """
  The deposit of the minimum opening balance when an account is activated. It is made on the day of activation,
  with no payment detail.
  """
  @spec opening_deposit!(struct, map, Date.t(), Decimal.t()) :: :ok
  def opening_deposit!(user, account, on, amount) do
    req = %{date: on, amount: amount, external_id: nil}
    add_tx!(user, account, @deposit, req, nil)
    :ok
  end

  @doc """
  Withdraws what is left in the account when it is closed, on the day of closing, as Fineract does for
  `withdrawBalance`: whatever the account's rules for its balance, it goes to nothing.
  """
  @spec closing_withdrawal!(struct, map, Params.t(), Date.t()) :: map
  def closing_withdrawal!(user, account, %Params{} = p, on) do
    {detail_id, changes} = payment_detail!(p)
    req = %{date: on, amount: account.account_balance_derived, external_id: nil}

    check_open!(account, req, p)
    check_lock_in!(account, req, p)

    add_tx!(user, account, @withdrawal, req, detail_id,
      check: [exception?: true, amount: req.amount],
      fees: false
    )

    changes
  end

  @doc "Undoes a transaction: it counts for nothing from now on, and its entries in the books are posted the other way."
  @spec undo!(struct, integer, integer) :: Result.t()
  def undo!(user, id, tx_id) do
    account = Transitions.account!(id)
    tx = Transactions.get(id, tx_id) || raise(Transactions.not_found(id, tx_id))
    check_active_for!(account, "undotransaction")

    if tx.is_reversed == true do
      check_balance_after!(account, Balance.live(account.id), "undotransaction")
    else
      remove_tx!(user, account, tx, "undotransaction", precision: 15)
    end

    result(account, id, %{})
  end

  @doc "Reverses a transaction: undoes it and puts a reversal in its place."
  @spec reverse!(struct, integer, integer) :: Result.t()
  def reverse!(user, id, tx_id) do
    account = Transitions.account!(id)
    tx = live_tx!(id, tx_id)
    check_active_for!(account, "undotransaction")

    reversal_id =
      remove_tx!(user, account, tx, "undotransaction",
        precision: 15,
        post_reversals: true,
        reversal: true,
        fees?: false
      )

    # the reversal of an amount put on hold or released is not named in the answer
    reversal_id = if tx.transaction_type_enum in [20, 21], do: nil, else: reversal_id

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
    check_active_for!(account, "adjusttransaction")

    check_open!(account, req, p)
    if tx.transaction_type_enum == @withdrawal, do: check_lock_in!(account, req, p)

    new_id = replace_tx!(user, account, tx, req, detail_id)
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

  @doc """
  Writes the plan of a command that changes no transaction (working interest out, or posting it): the postings it
  reverses and makes, and their entries in the books. Answers with `Interest.apply!/3`'s answer.
  """
  @spec settle!(struct, map, Interest.plan()) :: %{reversed: [map], created: [map]}
  def settle!(user, account, plan) do
    applied = Interest.apply!(user, account, plan)
    book!(user, account, applied, [], [])
    applied
  end

  # the id a transaction that is not stored yet takes in the lists the interest is planned on
  @pending_id 1_000_000_000_000_000

  # Adds a transaction. What it leaves is planned first (the interest earned and the postings made again), the
  # balance rules are asked, and then it is written, followed by the postings and the entries in the books
  # (the reversed postings first, as Fineract lists them, then the transaction, then the new postings). A
  # withdrawal brings the withdrawal fees of the account's charges with it, which Fineract lists before it.
  defp add_tx!(user, account, type, req, detail_id, opts \\ []) do
    ref_no = Ecto.UUID.generate()

    fees =
      if type == @withdrawal and opts[:fees] != false, do: withdrawal_fees(account, req), else: []

    fee_entries =
      fees
      |> Enum.with_index(1)
      |> Enum.map(fn {fee, i} ->
        %{pending(4, fee.req) | id: @pending_id + i}
        |> Map.merge(%{charge_time: 5, penalty: fee.charge.penalty})
      end)

    live = Balance.live(account.id) ++ fee_entries ++ [pending(type, req)]
    plan = Interest.plan(account, live, plan_opts([req.date], 16))
    if opts[:check], do: Balance.check!(account, plan.live_after, opts[:check])

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:millisecond)
    id = insert_row!(user, account, type, req, detail_id, ref_no, now)

    # the fees were made just before the withdrawal, though they are saved after it, and are counted first
    made = NaiveDateTime.add(now, -1, :millisecond)

    fee_rows =
      for fee <- fees do
        fee_id = insert_row!(user, account, 4, fee.req, nil, ref_no, made)
        record_payment!(user, fee_id, fee.charge, fee.req.amount)
        {fee_id, 4, fee.req, nil, fee.charge}
      end

    applied = Interest.apply!(user, account, plan)
    book!(user, account, applied, [], fee_rows ++ [{id, type, req, detail_id}])
    id
  end

  @doc """
  Pays `amount` of a charge of the account on `date`: a fee, a penalty, an annual fee or an activation fee takes the
  money out of the account as a transaction of its own (type 7, 5 or 7). The balance rules are asked as Fineract asks
  them after a charge is paid. Answers with the id of the transaction.
  """
  @spec pay_charge!(struct, map, map, Date.t(), Decimal.t(), keyword) :: integer
  def pay_charge!(user, account, charge, date, amount, opts \\ []) do
    type = if Charges.annual?(charge), do: 5, else: 7
    req = %{date: date, amount: amount, external_id: nil}
    entry = Map.merge(pending(type, req), %{charge_time: charge.time, penalty: charge.penalty})
    plan = Interest.plan(account, Balance.live(account.id) ++ [entry], plan_opts([date], 16))

    action =
      if opts[:action] == :activation,
        do: {:resource, "savingsaccountPAY_CHARGE"},
        else: "savingsAccountTransactionType.payCharge"

    check_balance_after!(account, plan.live_after, action)

    id = insert_row!(user, account, type, req, nil)
    record_payment!(user, id, charge, amount)
    applied = Interest.apply!(user, account, plan)
    book!(user, account, applied, [], [{id, type, req, nil, charge}])
    id
  end

  @doc """
  Escheats the balance of an account: a transaction of its own (type 19) that is dated `date`, takes the balance out
  of the books and leaves the account's own totals alone, as Fineract's `SavingsAccount.escheat` does.
  """
  @spec escheat!(struct, map, Date.t()) :: integer
  def escheat!(user, account, date) do
    req = %{date: date, amount: account.account_balance_derived, external_id: nil}
    add_tx!(user, account, 19, req, nil, fees: false)
  end

  @doc "Waives what is outstanding of a charge: a transaction that takes nothing out, dated today."
  @spec waive_charge!(struct, map, map) :: integer
  def waive_charge!(user, account, charge) do
    req = %{date: BusinessDate.current(), amount: charge.outstanding, external_id: nil}

    plan =
      Interest.plan(
        account,
        Balance.live(account.id) ++ [pending(6, req)],
        plan_opts([charge.due_date || req.date], 16)
      )

    check_balance_after!(account, plan.live_after, "waiveCharge")

    id = insert_row!(user, account, 6, req, nil)

    TenantRepo.insert_all("m_savings_account_charge_paid_by", [
      %{
        savings_account_transaction_id: id,
        savings_account_charge_id: charge.id,
        amount: req.amount
      }
    ])

    Charges.save!(user, Charges.after_waiver(charge))
    applied = Interest.apply!(user, account, plan)
    book!(user, account, applied, [], [])
    id
  end

  # the withdrawal fees a withdrawal of `req.amount` makes the account pay: those of its active charges
  defp withdrawal_fees(account, req) do
    for charge <- Charges.list(account.id, "active"), Charges.withdrawal_fee?(charge) do
      fee = Charges.withdrawal_fee_amount(charge, req.amount, account.currency_digits)
      %{charge: charge, req: %{date: req.date, amount: fee, external_id: nil}}
    end
  end

  # the payment is linked to the charge and the charge is left as paying it leaves it
  defp record_payment!(user, tx_id, charge, amount) do
    TenantRepo.insert_all("m_savings_account_charge_paid_by", [
      %{
        savings_account_transaction_id: tx_id,
        savings_account_charge_id: charge.id,
        amount: amount
      }
    ])

    # the charge as it is now (an undo just before may have changed it)
    charge = Charges.get(charge.id) || charge

    charge =
      if Charges.withdrawal_fee?(charge) or Charges.no_activity?(charge),
        do: %{charge | outstanding: amount},
        else: charge

    Charges.save!(user, Charges.after_payment(charge, amount))
  end

  # Takes a transaction away (undo or reverse): the balance rules are asked on what is left, the transaction is
  # marked reversed and, for a reversal, the reversal is put in its place after the postings are made again. Undoing a
  # withdrawal undoes the withdrawal fees it made, and undoing the payment of a charge or a waiver gives the charge
  # back what it was.
  defp remove_tx!(user, account, tx, action, opts) do
    removed = [tx | if(opts[:fees?] == false, do: [], else: fees_of(account.id, tx))]
    ids = Enum.map(removed, & &1.id)
    live = Enum.reject(Balance.live(account.id), &(&1.id in ids))
    dates = if post_calculation?(tx), do: [tx.transaction_date], else: []

    plan =
      Interest.plan(
        account,
        live,
        plan_opts(dates, opts[:precision], post_reversals: opts[:post_reversals] == true)
      )

    check_balance_after!(account, plan.live_after, action)

    TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id in ^ids),
      set: [is_reversed: true]
    )

    Enum.each(removed, &undo_charge_effect!(user, &1))

    # Fineract saves the reversal of the transaction after the postings of interest made again
    applied = Interest.apply!(user, account, plan)
    reversal_id = if opts[:reversal], do: insert_reversal!(user, account, tx)
    book!(user, account, applied, Enum.map(removed, &flip/1), [])
    reversal_id
  end

  # the withdrawal fees a withdrawal made are those that share its reference and are not undone
  defp fees_of(_account_id, %{transaction_type_enum: type}) when type != @withdrawal, do: []
  defp fees_of(_account_id, %{ref_no: nil}), do: []

  defp fees_of(account_id, tx) do
    from(t in "m_savings_account_transaction",
      where:
        t.savings_account_id == ^account_id and t.ref_no == ^tx.ref_no and
          t.transaction_type_enum == 4 and
          not t.is_reversed and t.id != ^tx.id,
      order_by: t.id,
      select: %{
        id: t.id,
        transaction_date: t.transaction_date,
        transaction_type_enum: t.transaction_type_enum,
        amount: t.amount,
        ref_no: t.ref_no
      }
    )
    |> TenantRepo.all()
  end

  # undoing the payment of a charge gives it back what it was; undoing a waiver does the same
  defp undo_charge_effect!(user, %{transaction_type_enum: type} = tx) when type in [4, 5, 6, 7] do
    links =
      TenantRepo.all(
        from(p in "m_savings_account_charge_paid_by",
          where: p.savings_account_transaction_id == ^tx.id,
          select: p.savings_account_charge_id
        )
      )

    for charge_id <- links, charge = Charges.get(charge_id) do
      Charges.save!(
        user,
        if(type == 6,
          do: Charges.after_undone_waiver(charge, tx.amount),
          else: Charges.after_undone_payment(charge, tx.amount)
        )
      )
    end

    :ok
  end

  defp undo_charge_effect!(_user, _tx), do: :ok

  # Changes a transaction: the old one goes (and the withdrawal fees it made), the new one comes (with its own fees),
  # the interest is planned on what that leaves
  defp replace_tx!(user, account, tx, req, detail_id) do
    type = tx.transaction_type_enum
    removed = [tx | fees_of(account.id, tx)]
    ids = Enum.map(removed, & &1.id)
    ref_no = Ecto.UUID.generate()
    fees = if type == @withdrawal, do: withdrawal_fees(account, req), else: []

    fee_entries =
      fees
      |> Enum.with_index(1)
      |> Enum.map(fn {fee, i} ->
        %{pending(4, fee.req) | id: @pending_id + i}
        |> Map.merge(%{charge_time: 5, penalty: fee.charge.penalty})
      end)

    live =
      Enum.reject(Balance.live(account.id), &(&1.id in ids)) ++
        fee_entries ++ [pending(type, req)]

    plan = Interest.plan(account, live, plan_opts([req.date, tx.transaction_date], 10))

    TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id in ^ids),
      set: [is_reversed: true]
    )

    Enum.each(removed, &undo_charge_effect!(user, &1))

    # Fineract saves the new transaction before it asks the balance rules, so a refusal uses an id up
    id = insert_row!(user, account, type, req, detail_id, ref_no)
    check_balance_after!(account, plan.live_after, "adjusttransaction")

    fee_rows =
      for fee <- fees do
        fee_id = insert_row!(user, account, 4, fee.req, nil, ref_no)
        record_payment!(user, fee_id, fee.charge, fee.req.amount)
        {fee_id, 4, fee.req, nil, fee.charge}
      end

    applied = Interest.apply!(user, account, plan)

    book!(
      user,
      account,
      applied,
      Enum.map(removed, &flip/1),
      fee_rows ++ [{id, type, req, detail_id}]
    )

    id
  end

  defp pending(type, req),
    do: %{
      id: @pending_id,
      type: type,
      date: req.date,
      amount: req.amount,
      manual: false,
      overdraft: nil
    }

  defp plan_opts(dates, precision, extra \\ []),
    do:
      Keyword.merge(
        [dates: dates, precision: precision, post_reversals: post_reversals?()],
        extra
      )

  defp post_reversals?,
    do:
      match?(
        %{enabled: true},
        Configuration.get("enable-post-reversal-txns-for-reverse-transactions")
      )

  # deposits, withdrawals, charges, dividends and postings of interest make interest to be worked out again
  defp post_calculation?(tx), do: tx.transaction_type_enum in [1, 2, 3, 4, 5, 7, 8]

  defp flip(tx), do: %{id: tx.id, date: tx[:transaction_date] || tx.date}

  # The entries in the books of a change: those of what was reversed are posted the other way (in the order Fineract
  # lists transactions: by date, then id), then those of the transactions added, then those of the postings made.
  defp book!(user, account, applied, reversed, added) do
    reversed =
      Enum.sort_by(
        reversed ++ Enum.map(applied.reversed, &flip/1),
        &{Date.to_gregorian_days(&1.date), &1.id}
      )

    for tx <- reversed, do: Journal.reverse!(user, account, tx.id)

    for added_tx <- added, do: post_entries!(user, account, added_tx)

    for row <- applied.created do
      Journal.post!(user, account, %{
        id: row.id,
        type: row.type,
        date: row.date,
        amount: row.amount,
        payment_detail_id: row.payment_detail_id,
        reversed: row.reversed?,
        overdraft: row.overdraft || overdraft_part(row.id, row.type, row.amount)
      })
    end

    touch_account!(user, account)
  end

  # the row of a transaction (the derived columns are worked out by `Interest.apply!`)
  defp insert_row!(user, account, type, req, detail_id, ref_no \\ nil, created \\ nil) do
    now = DateTime.utc_now()

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
                created_date: created || NaiveDateTime.utc_now(),
                created_by: user.id,
                is_manual: false,
                ref_no: ref_no || Ecto.UUID.generate(),
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
  end

  defp post_entries!(user, account, {id, type, req, detail_id}),
    do: post_entries!(user, account, {id, type, req, detail_id, nil})

  defp post_entries!(user, account, {id, type, req, detail_id, charge}) do
    Journal.post!(user, account, %{
      id: id,
      type: type,
      date: req.date,
      amount: req.amount,
      payment_detail_id: detail_id,
      charge: charge,
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

    case {Calc.direction(type), balance} do
      {_, nil} -> Decimal.new(0)
      {nil, _} -> Decimal.new(0)
      {:credit, after_} -> part(Decimal.sub(after_, amount), amount)
      {:debit, after_} -> part(after_, amount)
    end
  end

  # `balance` is what the account held when the money was taken out, or before it was put in
  defp part(balance, amount),
    do:
      if(Decimal.lt?(balance, 0),
        do: Decimal.min(amount, Decimal.negate(balance)),
        else: Decimal.new(0)
      )

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
  defp check_balance_after!(account, live, action) do
    Balance.check!(account, live, amount: nil)
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
