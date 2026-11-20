defmodule ECBDeposits.Savings.Holds do
  @moduledoc """
  Putting an amount of a savings account on hold and releasing it, after Fineract's `holdAmount` and `releaseAmount`
  of the write service, `SavingsAccountTransactionDataValidator` and `SavingsAccount.holdAmount`. A hold is a
  transaction of its own (type 20) that takes nothing out of the balance but keeps the account from paying it out; a
  release (type 21) gives it back. What is on hold is kept with the account (`total_savings_amount_on_hold`), which
  undoing or reversing a hold leaves as it is, as Fineract does. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.{Postings, Transactions, Transitions}
  alias ECBPlatform.{BusinessDate, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.ServerError

  @hold 20
  @release 21
  @active 300

  # --- putting on hold -------------------------------------------------------------------------------

  @doc "Puts an amount of the account on hold."
  @spec hold!(struct, integer, Params.t()) :: Result.t()
  def hold!(user, id, %Params{} = p) do
    account = Transitions.account!(id)

    Params.check_supported!(
      p,
      ~w(transactionDate dateFormat locale transactionAmount externalId lienAllowed reasonForBlock)
    )

    amount = Params.decimal_with_locale(p, "transactionAmount")
    external_id = Params.string(p, "externalId")
    reason = Params.string(p, "reasonForBlock")
    date = Params.date(p, "transactionDate")
    lien? = Params.boolean(p, "lienAllowed") == true

    # Fineract fails without an answer when the amount is missing
    if amount == nil, do: raise(ServerError)

    Validation.new("savingsaccount")
    |> Validation.param("transactionAmount", amount)
    |> Validation.not_null()
    |> Validation.positive_amount()
    |> Validation.param("externalId", external_id)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.param("reasonForBlock", reason)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("transactionDate", date)
    |> Validation.not_null()
    |> active_state(account)
    |> room(account, amount, lien?)
    |> after_last_transaction(account, date)
    |> Validation.raise_if_errors!()

    on_hold = account.savings_on_hold || Decimal.new(0)
    balance = Decimal.sub(Decimal.sub(account.account_balance_derived, on_hold), amount)

    tx_id =
      insert!(user, account,
        type: @hold,
        date: date,
        amount: amount,
        running_balance: balance,
        external_id: external_id,
        reason: reason,
        lien?: lien?
      )

    set_on_hold!(user, id, Decimal.add(on_hold, amount))
    result(account, tx_id)
  end

  defp active_state(v, account) do
    if account.status_enum == @active,
      do: v,
      else:
        v
        |> Validation.param("status", nil)
        |> Validation.fail_without_parameter("not.in.active.state")
  end

  # the account must be able to spare the amount: from a lien allowed within its limit, else from what it may pay out
  defp room(v, account, amount, true) do
    cond do
      account.is_lien_allowed != true ->
        problem(v, "lien.is.not.allowed.in.product.level", account.id)

      account.allow_overdraft == true and
          Decimal.gt?(
            account.overdraft_limit || Decimal.new(0),
            account.max_allowed_lien_limit || Decimal.new(0)
          ) ->
        v = problem(v, "Overdraft.limit.can.not.be.greater.than.lien.limit", account.id)
        lien_limit(v, account, amount)

      true ->
        lien_limit(v, account, amount)
    end
  end

  defp room(v, account, amount, false) do
    withdrawable = withdrawable(account)
    over? = account.allow_overdraft == true
    enforced? = account.enforce_min_required_balance == true
    beyond? = Decimal.gt?(amount, withdrawable)
    limit = account.overdraft_limit || Decimal.new(0)

    # each rule that applies asks for itself, and each can add its problem
    asked = [
      over? and beyond? and Decimal.gt?(amount, limit),
      enforced? and beyond?,
      not over? and not enforced? and beyond?
    ]

    Enum.reduce(asked, v, fn
      true, acc -> problem(acc, "insufficient.balance", account.id)
      false, acc -> acc
    end)
  end

  defp lien_limit(v, account, amount) do
    if Decimal.gt?(amount, account.max_allowed_lien_limit || Decimal.new(0)),
      do: problem(v, "lien.limit.exceeded", account.id),
      else: v
  end

  # what the account can pay out: its balance less the least it must keep and what is on hold
  defp withdrawable(account) do
    account.account_balance_derived
    |> Decimal.sub(minimum(account))
    |> Decimal.sub(account.on_hold_funds_derived || Decimal.new(0))
    |> Decimal.sub(account.savings_on_hold || Decimal.new(0))
  end

  defp minimum(account) do
    zero = Decimal.new(0)

    required =
      if account.enforce_min_required_balance == true,
        do: account.min_required_balance || zero,
        else: zero

    if account.allow_overdraft == true,
      do: Decimal.sub(required, account.overdraft_limit || zero),
      else: required
  end

  # an amount is put on hold only after the last transaction
  defp after_last_transaction(v, account, date) do
    last = Postings.last_transaction_date(account.id)

    if last != nil and (date == nil or Date.compare(date, last) == :lt) do
      v
      |> Validation.param("date", last)
      |> Validation.fail_with_code("validation.msg.date.can.not.be.before.last.transaction.date")
      |> with_args(["Amount can be put on hold only after last transaction"])
    else
      v
    end
  end

  # a problem whose arguments are the id of the account
  defp problem(v, code, id) do
    v |> Validation.param(nil, nil) |> Validation.fail_without_parameter(code) |> with_args([id])
  end

  # the last problem's second argument says more
  defp with_args(%{errors: [error | rest]} = v, extra),
    do: %{v | errors: [%{error | args: [hd(error.args), extra]} | rest]}

  # --- releasing ---------------------------------------------------------------------------------------

  @doc "Releases an amount that was put on hold."
  @spec release!(struct, integer, integer, Params.t()) :: Result.t()
  def release!(user, id, hold_id, %Params{} = p) do
    Params.check_supported!(p, ~w(externalId locale dateFormat))
    external_id = Params.string(p, "externalId")

    Validation.new("savingsaccount.transaction")
    |> Validation.param("externalId", external_id)
    |> Validation.ignore_if_null()
    |> Validation.max_length(100)
    |> Validation.raise_if_errors!()

    hold = Transactions.get(id, hold_id) || raise Transactions.not_found(id, hold_id)
    account = Transitions.account!(id)

    Validation.new("savingsaccount")
    |> held(hold)
    |> active_state(account)
    |> Validation.raise_if_errors!()

    on_hold = account.savings_on_hold || Decimal.new(0)

    balance =
      account.account_balance_derived |> Decimal.sub(on_hold) |> Decimal.add(hold.amount)

    release_id =
      insert!(user, account,
        type: @release,
        date: BusinessDate.current(),
        amount: hold.amount,
        running_balance: balance,
        external_id: external_id,
        reason: nil,
        lien?: hold.is_lien_transaction == true
      )

    TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id == ^hold.id),
      set: [release_id_of_hold_amount: release_id, reason_for_block: nil]
    )

    set_on_hold!(user, id, Decimal.sub(on_hold, hold.amount))
    result(account, release_id)
  end

  # only a hold that is not released and not undone can be released
  defp held(v, hold) do
    if hold.transaction_type_enum == @hold and hold.is_reversed != true and
         hold.release_id_of_hold_amount == nil do
      v
    else
      v
      |> Validation.param("amount", hold.amount)
      |> Validation.fail_with_code("validation.msg.amount.is.not.on.hold")
      |> with_args(["Transaction amount is not on hold"])
    end
  end

  # --- the rows ------------------------------------------------------------------------------------------

  defp insert!(user, account, opts) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_savings_account_transaction",
        [
          %{
            savings_account_id: account.id,
            office_id: account.client_office_id,
            transaction_type_enum: opts[:type],
            is_reversed: false,
            transaction_date: opts[:date],
            amount: opts[:amount],
            running_balance_derived: opts[:running_balance],
            created_date: NaiveDateTime.utc_now(),
            created_by: user.id,
            is_manual: false,
            is_reversal: false,
            is_lien_transaction: opts[:lien?],
            reason_for_block: opts[:reason],
            external_id: opts[:external_id],
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

  defp set_on_hold!(user, id, amount) do
    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id),
      set: [
        total_savings_amount_on_hold: amount,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      ]
    )
  end

  defp result(account, id) do
    Result.new(
      resource_id: id,
      savings_id: account.id,
      office_id: account.client_office_id,
      client_id: account.client_id
    )
  end

  @doc "Whether the account has an amount on hold."
  @spec on_hold?(map) :: boolean
  def on_hold?(account), do: Decimal.gt?(account.savings_on_hold || Decimal.new(0), 0)
end
