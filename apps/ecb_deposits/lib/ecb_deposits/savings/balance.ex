defmodule ECBDeposits.Savings.Balance do
  @moduledoc """
  What the transactions of a savings account add up to: the running balance after each of them, the totals of
  deposits and withdrawals and the account balance, after Fineract's `SavingsAccountSummary.updateSummary` and the
  checks of `SavingsAccount.validateAccountBalanceConstraints`. A transaction that is reversed, and the reversal
  that stands for it, count for nothing. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.Interest.Calc
  alias ECBPlatform.{Configuration, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation

  @deposit 1
  @withdrawal 2
  @interest_posting 3
  @withdrawal_fee 4
  @annual_fee 5
  @hold 20
  @release 21
  @pay_charge 7
  @dividend 8
  @overdraft_interest 17

  @doc """
  The live transactions of the account (those not reversed and not reversals) as `%{id, type, date, amount, manual,
  overdraft, payment_detail_id, ref_no}`, in the order of their dates and then their ids.
  """
  @spec live(integer) :: [map]
  def live(account_id) do
    from(t in "m_savings_account_transaction",
      where: t.savings_account_id == ^account_id and not t.is_reversed and not t.is_reversal,
      order_by: [t.transaction_date, t.created_date, t.id],
      select: %{
        id: t.id,
        type: t.transaction_type_enum,
        date: t.transaction_date,
        amount: t.amount,
        manual: t.is_manual,
        overdraft: t.overdraft_amount_derived,
        payment_detail_id: t.payment_detail_id,
        ref_no: t.ref_no,
        charge_time:
          fragment(
            "(SELECT sc.charge_time_enum FROM m_savings_account_charge_paid_by pb JOIN m_savings_account_charge sc ON sc.id = pb.savings_account_charge_id WHERE pb.savings_account_transaction_id = ? LIMIT 1)",
            t.id
          ),
        penalty:
          fragment(
            "(SELECT sc.is_penalty FROM m_savings_account_charge_paid_by pb JOIN m_savings_account_charge sc ON sc.id = pb.savings_account_charge_id WHERE pb.savings_account_transaction_id = ? LIMIT 1)",
            t.id
          )
      }
    )
    |> TenantRepo.all()
  end

  @doc "The balance after each transaction, as `[{transaction, balance}]`, for a list in the order they happened."
  @spec running([map]) :: [{map, Decimal.t()}]
  def running(transactions), do: Calc.running(transactions)

  @doc """
  Works the totals and balances out again from the account's transactions and stores them: the running balance
  of every live transaction (a reversed one has none), the part of each that was overdrawn, the totals of deposits,
  withdrawals, interest posted and overdraft interest (those of deposits and withdrawals are left alone until the
  account has had one of that kind) and the balance of the account.
  """
  @spec refresh!(integer) :: :ok
  def refresh!(account_id) do
    live = live(account_id)
    rows = running(live)
    overdrafts = Calc.overdrafts(live)

    TenantRepo.update_all(
      from(t in "m_savings_account_transaction", where: t.savings_account_id == ^account_id),
      set: [running_balance_derived: nil]
    )

    for {tx, balance} <- rows do
      TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id == ^tx.id),
        set: [running_balance_derived: balance, overdraft_amount_derived: overdrafts[tx.id]]
      )
    end

    deposits = sum(live, [@deposit, @dividend])
    withdrawals = sum(live, [@withdrawal])
    posted = sum(live, [@interest_posting])
    overdraft_interest = sum(live, [@overdraft_interest])

    withdrawal_fees = sum(live, [@withdrawal_fee])
    annual_fees = sum(live, [@annual_fee])
    fees = live |> Enum.filter(&(&1.penalty != true)) |> sum([@pay_charge])
    penalties = live |> Enum.filter(&(&1.penalty == true)) |> sum([@pay_charge])

    balance =
      deposits
      |> Decimal.add(posted)
      |> Decimal.sub(withdrawals)
      |> Decimal.sub(withdrawal_fees)
      |> Decimal.sub(annual_fees)
      |> Decimal.sub(fees)
      |> Decimal.sub(penalties)
      |> Decimal.sub(overdraft_interest)

    set =
      [
        account_balance_derived: balance,
        total_interest_posted_derived: posted,
        total_overdraft_interest_derived: overdraft_interest,
        total_withdrawal_fees_derived: withdrawal_fees,
        total_annual_fees_derived: annual_fees,
        total_fees_charge_derived: fees,
        total_penalty_charge_derived: penalties
      ]
      |> put_total(:total_deposits_derived, account_id, @deposit, deposits)
      |> put_total(:total_withdrawals_derived, account_id, @withdrawal, withdrawals)

    TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^account_id), set: set)
    :ok
  end

  defp sum(live, types),
    do:
      live
      |> Enum.filter(&(&1.type in types))
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
    # money put on hold and released is no credit or debit of the account
    rows = transactions |> Enum.reject(&(&1.type in [@hold, @release])) |> running()
    final = rows |> List.last() |> then(&if(&1, do: elem(&1, 1), else: Decimal.new(0)))
    force? = Keyword.get(opts, :force?, false)
    exception? = Keyword.get(opts, :exception?, false)

    violated? = violated?(account, rows, final, minimum, force?, exception?)

    if violated? or held?(account, final, minimum, opts[:hold]),
      do: insufficient!(final, opts[:amount]),
      else: :ok
  end

  defp violated?(%{allow_overdraft: true}, _rows, final, minimum, force?, _exception?),
    do: below?(final, minimum) and not forced?(force?, final)

  defp violated?(_account, rows, _final, minimum, force?, exception?) do
    not exception? and
      Enum.any?(rows, fn {tx, balance} ->
        Calc.direction(tx.type) == :debit and checked?(tx) and below?(balance, minimum) and
          not forced?(force?, balance)
      end)
  end

  # what the account holds back (`hold`) must stay in it: `violatesMinBalanceWithHold`
  defp held?(_account, _final, _minimum, hold) when hold in [nil, 0], do: false

  defp held?(account, final, minimum, %Decimal{} = hold) do
    cond do
      not Decimal.gt?(hold, 0) -> false
      account.enforce_min_required_balance == true -> below?(final, Decimal.add(minimum, hold))
      true -> below?(final, hold)
    end
  end

  # a charge that is not an activation or a withdrawal fee may take the balance below what is allowed
  defp checked?(%{type: type} = tx) when type in [@annual_fee, @pay_charge],
    do: tx[:charge_time] in [3, 5]

  defp checked?(_tx), do: true

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
  @spec going_negative!(String.t() | {:resource, String.t()}) :: no_return
  def going_negative!({:resource, resource}) do
    ECBPlatform.Validation.new(resource)
    |> ECBPlatform.Validation.fail_without_parameter("results.in.balance.going.negative")
    |> ECBPlatform.Validation.raise_if_errors!()
  end

  def going_negative!(action) do
    ECBPlatform.Validation.new("savingsaccount." <> action)
    |> ECBPlatform.Validation.fail_without_parameter("results.in.balance.going.negative")
    |> ECBPlatform.Validation.raise_if_errors!()
  end
end
