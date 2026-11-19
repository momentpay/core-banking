defmodule ECBDeposits.Savings.Balance do
  @moduledoc """
  What the transactions of a savings account add up to: the running balance after each of them, the totals of
  deposits and withdrawals and the account balance, after Fineract's `SavingsAccountSummary.updateSummary` and the
  checks of `SavingsAccount.validateAccountBalanceConstraints`. A transaction that is reversed, and the reversal
  that stands for it, count for nothing. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.{Configuration, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation

  @deposit 1
  @withdrawal 2

  @doc """
  The live transactions of the account (those not reversed and not reversals) as `%{id, type, date, amount}`,
  in the order of their dates and then their ids.
  """
  @spec live(integer) :: [map]
  def live(account_id) do
    from(t in "m_savings_account_transaction",
      where: t.savings_account_id == ^account_id and not t.is_reversed and not t.is_reversal,
      order_by: [t.transaction_date, t.id],
      select: %{
        id: t.id,
        type: t.transaction_type_enum,
        date: t.transaction_date,
        amount: t.amount
      }
    )
    |> TenantRepo.all()
  end

  @doc "The balance after each transaction, as `[{transaction, balance}]`, for a list in the order they happened."
  @spec running([map]) :: [{map, Decimal.t()}]
  def running(transactions) do
    {rows, _} =
      Enum.map_reduce(transactions, Decimal.new(0), fn tx, balance ->
        balance = apply_tx(balance, tx)
        {{tx, balance}, balance}
      end)

    rows
  end

  defp apply_tx(balance, %{type: @deposit, amount: amount}), do: Decimal.add(balance, amount)
  defp apply_tx(balance, %{type: @withdrawal, amount: amount}), do: Decimal.sub(balance, amount)

  @doc """
  Works the totals and balances out again from the account's transactions and stores them: the running balance
  of every live transaction (a reversed one has none), the totals of deposits and withdrawals (left alone until the
  account has had one of that kind) and the balance of the account.
  """
  @spec refresh!(integer) :: :ok
  def refresh!(account_id) do
    live = live(account_id)
    rows = running(live)

    TenantRepo.update_all(
      from(t in "m_savings_account_transaction", where: t.savings_account_id == ^account_id),
      set: [running_balance_derived: nil]
    )

    for {tx, balance} <- rows do
      TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id == ^tx.id),
        set: [running_balance_derived: balance]
      )
    end

    deposits = sum(live, @deposit)
    withdrawals = sum(live, @withdrawal)

    set =
      [account_balance_derived: Decimal.sub(deposits, withdrawals)]
      |> put_total(:total_deposits_derived, account_id, @deposit, deposits)
      |> put_total(:total_withdrawals_derived, account_id, @withdrawal, withdrawals)

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^account_id), set: set)
    :ok
  end

  defp sum(live, type),
    do:
      live
      |> Enum.filter(&(&1.type == type))
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.amount, &2))

  # a total is first written when the account has a transaction of that kind, reversed or not
  defp put_total(set, column, account_id, type, total) do
    if TenantRepo.exists?(
         from(t in "m_savings_account_transaction",
           where: t.savings_account_id == ^account_id and t.transaction_type_enum == ^type
         )
       ),
       do: Keyword.put(set, column, total),
       else: set
  end

  @doc """
  Refuses a list of live transactions (with the balance rules of `account`) that leaves the account with less than
  it may have: after any withdrawal the balance may not be below the minimum required balance, and an account with an
  overdraft may be as far below it as the overdraft limit allows. `balance` is the balance the answer names;
  `amount` the amount of the transaction asked for. `force?` lets a forced withdrawal go as far below as the
  configuration allows.
  """
  @spec check!(map, [map], keyword) :: :ok
  def check!(account, transactions, opts \\ []) do
    minimum = minimum(account)
    rows = running(transactions)
    final = rows |> List.last() |> then(&if(&1, do: elem(&1, 1), else: Decimal.new(0)))
    force? = Keyword.get(opts, :force?, false)
    exception? = Keyword.get(opts, :exception?, false)

    violated? =
      if account.allow_overdraft == true do
        below?(final, minimum) and not forced?(force?, final)
      else
        not exception? and
          Enum.any?(rows, fn {tx, balance} ->
            tx.type == @withdrawal and below?(balance, minimum) and not forced?(force?, balance)
          end)
      end

    if violated?, do: insufficient!(final, opts[:amount]), else: :ok
  end

  # the least the balance may be: what must stay in the account, less what may be overdrawn
  defp minimum(account) do
    zero = Decimal.new(0)

    required =
      if account.enforce_min_required_balance == true,
        do: account.min_required_balance || zero,
        else: zero

    overdraft =
      if account.allow_overdraft == true, do: account.overdraft_limit || zero, else: zero

    Decimal.sub(required, overdraft)
  end

  defp below?(balance, minimum), do: Decimal.lt?(Decimal.sub(balance, minimum), 0)

  defp forced?(false, _balance), do: false

  defp forced?(true, balance) do
    case Configuration.get("allow-force-withdrawal-on-savings-account") do
      %{enabled: true} = config ->
        limit = Decimal.new(config.value || 0)
        limit = if Decimal.gt?(limit, 0), do: Decimal.negate(limit), else: limit
        Decimal.compare(balance, limit) != :lt

      _ ->
        false
    end
  end

  defp insufficient!(balance, amount) do
    raise DomainRuleViolation,
      code: "error.msg.savingsaccount.transaction.insufficient.account.balance",
      message: "Insufficient account balance.",
      args: ["transactionAmount", balance, nil, amount]
  end

  @doc "The error of undoing or changing a transaction that would leave the account with less than it may have."
  @spec going_negative!(String.t()) :: no_return
  def going_negative!(action) do
    ECBPlatform.Validation.new("savingsaccount." <> action)
    |> ECBPlatform.Validation.fail_without_parameter("results.in.balance.going.negative")
    |> ECBPlatform.Validation.raise_if_errors!()
  end

  @doc "Whether the account earns, or owes, interest, which is not built yet."
  @spec interest_bearing?(map) :: boolean
  def interest_bearing?(account) do
    positive?(account.nominal_annual_interest_rate) or
      (account.allow_overdraft == true and
         positive?(account.nominal_annual_interest_rate_overdraft))
  end

  defp positive?(nil), do: false
  defp positive?(%Decimal{} = d), do: Decimal.gt?(d, 0)
end
