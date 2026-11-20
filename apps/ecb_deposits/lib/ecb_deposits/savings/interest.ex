defmodule ECBDeposits.Savings.Interest do
  @moduledoc """
  Interest on a savings account: working it out after every change to its transactions, and posting it, as Fineract
  does in `SavingsAccount.calculateInterestUsing`, `recalculateDailyBalances`, `SavingsAccountPostInterestServiceImpl`
  and the write service's `calculateInterest` and `postInterest`.

  A change is first *planned* on the list of live transactions it leaves (`plan/3`, no writes): which transactions
  are replaced by a copy because a change to the past altered how much of them took the account overdrawn, what
  interest the posting periods earn and, when the change falls before a posting already made or interest is asked to
  be posted, which postings are reversed and made again. The balance rules can then be checked on the list the plan
  leaves (`Balance.check!/3`) before anything is written. `apply!/3` writes the plan.

  Left out, and refused: the configuration that makes Fineract keep a running balance on a "pivot date"
  (`allow-backdated-transaction-before-interest-posting` off) and withholding tax. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.Savings.Interest.Calc
  alias ECBMoney.Precision
  alias ECBPlatform.{BusinessDate, Configuration, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation

  @posting 3
  @overdraft_interest 17
  @new_id_base 1_000_000_000_000

  @type plan :: %{
          calculating?: boolean,
          earned: Decimal.t() | nil,
          up_to: Date.t(),
          reverse: [map],
          create: [map],
          live_after: [map],
          posted_till: Date.t() | nil
        }

  @doc "Whether the account earns interest on its balance, or owes it on an overdraft."
  @spec calculating?(map) :: boolean
  def calculating?(account), do: earns?(account) or owes?(account)

  defp earns?(account), do: nonzero?(account.nominal_annual_interest_rate)

  defp owes?(account),
    do:
      account.allow_overdraft == true and nonzero?(account.overdraft_limit) and
        nonzero?(account.nominal_annual_interest_rate_overdraft)

  defp nonzero?(nil), do: false
  defp nonzero?(%Decimal{} = d), do: not Decimal.eq?(d, 0)

  @doc "Whether a transaction is stored already (those that are not have an id above every stored one)."
  @spec stored?(map) :: boolean
  def stored?(%{id: id}), do: is_integer(id) and id < @new_id_base

  @doc """
  Plans what a change leaves: `live` is the list of live transactions after the change (`%{id, type, date, amount,
  manual, overdraft, payment_detail_id, ref_no}`, a transaction not stored yet with an id above every other).
  Options: `:precision` (digits Fineract divides the rate by 100 with: 16 after a deposit or a withdrawal, 15 after
  an undo, 10 after a change), `:dates` (dates of the transactions that were changed, which decide whether interest
  is posted again), `:mode` (`:calculate` or `:post`, to override), `:as_on` (the day to post interest as on) and
  `:post_reversals`.
  """
  @spec plan(map, [map], keyword) :: plan
  def plan(account, live, opts) do
    live = Calc.order(live)
    up_to = Keyword.get(opts, :up_to) || BusinessDate.current()

    if calculating?(account) do
      guard!()
      reversals? = Keyword.get(opts, :post_reversals, false)
      state = replace_pass(%{live: live, reverse: [], create: [], next: @new_id_base}, reversals?)

      periods = periods(account, state.live, up_to, opts)
      earned = Enum.reduce(periods, Decimal.new(0), &Decimal.add(&1.interest, &2))
      mode = Keyword.get(opts, :mode) || mode(state.live, Keyword.get(opts, :dates, []))

      state = if mode == :post, do: post_again(state, periods, up_to, reversals?), else: state

      finish(live, state, earned, up_to)
    else
      %{
        calculating?: false,
        earned: nil,
        up_to: up_to,
        reverse: [],
        create: [],
        live_after: live,
        posted_till: nil
      }
    end
  end

  # postings made, and then, when they changed anything, the copies they make necessary
  defp post_again(state, periods, up_to, reversals?) do
    posted = post(state, periods, up_to, reversals?)
    if posted == state, do: state, else: replace_pass(posted, reversals?)
  end

  defp finish(live, state, earned, up_to) do
    reversed_ids = Enum.map(state.reverse, & &1.id)
    remaining = Enum.reject(live, &(&1.id in reversed_ids))

    made =
      for %{kind: kind, reversed?: false, row: row} <- state.create,
          kind in [:posting, :copy],
          do: row

    %{
      calculating?: true,
      earned: earned,
      up_to: up_to,
      reverse: state.reverse,
      create: state.create,
      live_after: Calc.order(state.live),
      posted_till: posted_till(remaining ++ made)
    }
  end

  # Fineract keeps a running balance on a date of its own when this configuration is off
  defp guard! do
    case Configuration.get("allow-backdated-transaction-before-interest-posting") do
      %{enabled: true} ->
        :ok

      _ ->
        raise DomainRuleViolation,
          code: "error.msg.savingsaccount.feature.not.supported.yet",
          message:
            "Interest with the backdated-transaction-before-interest-posting configuration off is not supported yet by E-CoreBank",
          args: ["allow-backdated-transaction-before-interest-posting"]
    end
  end

  # interest is posted again when a change falls before a posting that was made
  defp mode(live, dates) do
    if Enum.any?(dates, &before_last_posting?(live, &1)), do: :post, else: :calculate
  end

  @doc "Whether a posting of interest was made after `date`."
  @spec before_last_posting?([map], Date.t()) :: boolean
  def before_last_posting?(live, date),
    do:
      Enum.any?(
        live,
        &(&1.type in [@posting, @overdraft_interest] and Date.compare(&1.date, date) == :gt)
      )

  # --- copies of what a change made overdrawn differently -----------------------------------------

  # A stored transaction whose overdrawn part is not what it was is reversed and a copy put in its place
  defp replace_pass(state, reversals?) do
    overdrafts = Calc.overdrafts(state.live)

    Enum.reduce(state.live, state, fn tx, st ->
      new = Map.get(overdrafts, tx.id, Decimal.new(0))
      if replace?(tx, new), do: replace(st, tx, new, reversals?), else: st
    end)
  end

  defp replace(st, tx, new, reversals?) do
    copy = Map.merge(tx, %{id: st.next, overdraft: new, copy_of: tx.id})
    item = %{kind: :copy, reversed?: false, row: copy, of: tx}
    extra = if reversals?, do: [%{kind: :reversal, original: tx}], else: []

    %{
      st
      | live: Enum.map(st.live, &if(&1.id == tx.id, do: copy, else: &1)),
        reverse: st.reverse ++ [tx],
        create: st.create ++ [item | extra],
        next: st.next + 1
    }
  end

  defp replace?(tx, new) do
    stored?(tx) and tx.overdraft != nil and not Decimal.eq?(tx.overdraft, 0) and
      not Decimal.eq?(tx.overdraft, new) and tx.type != 10
  end

  # --- the periods --------------------------------------------------------------------------------

  defp periods(account, live, up_to, opts) do
    at_period_end =
      match?(%{enabled: true}, Configuration.get("savings-interest-posting-current-period-end"))

    manual =
      live
      |> Enum.filter(&(&1.type == @posting and &1[:manual] == true))
      |> Enum.map(& &1.date)

    manual = if at_period_end, do: Enum.map(manual, &Date.add(&1, 1)), else: manual
    as_on = if opts[:as_on], do: manual ++ [opts[:as_on]], else: manual
    digits = Keyword.get(opts, :precision, 16)

    Calc.periods(%{
      start: account.start_interest_calculation_date,
      up_to: up_to,
      posting_type: account.interest_posting_period_enum,
      compounding_type: account.interest_compounding_period_enum,
      calculation_type: account.interest_calculation_type_enum,
      days_in_year: account.interest_calculation_days_in_year_type_enum,
      rate: fraction(account.nominal_annual_interest_rate, digits),
      overdraft_rate: fraction(account.nominal_annual_interest_rate_overdraft, digits),
      min_balance: account.min_balance_for_interest_calculation || Decimal.new(0),
      min_overdraft: account.min_overdraft_for_interest_calculation || Decimal.new(0),
      decimals: account.currency_digits,
      allow_overdraft: account.allow_overdraft == true,
      fy_begin: financial_year_begin(),
      at_period_end: at_period_end,
      as_on: as_on,
      business_date: BusinessDate.current(),
      txs: Calc.balances(live, up_to)
    })
  end

  defp fraction(nil, _digits), do: Decimal.new(0)

  defp fraction(rate, digits), do: Precision.divide(rate, Decimal.new(100), digits, :half_even)

  defp financial_year_begin do
    case Configuration.get("financial-year-beginning-month") do
      %{value: value} when not is_nil(value) -> to_int(value)
      _ -> 1
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(String.trim(value))
  defp to_int(%Decimal{} = value), do: Decimal.to_integer(value)

  # --- the postings -------------------------------------------------------------------------------

  # which postings are reversed and which are made: one for every posting period that has ended
  defp post(state, periods, up_to, reversals?) do
    periods
    |> Enum.filter(&(Date.compare(&1.posting_date, up_to) != :gt))
    |> Enum.reduce(state, &post_period(&2, &1, reversals?))
  end

  defp post_period(st, period, reversals?) do
    existing = Enum.filter(st.live, &(&1.type in [@posting, @overdraft_interest]))

    case Enum.find(existing, &(Date.compare(&1.date, period.posting_date) == :eq)) do
      nil ->
        add_posting(st, period)

      found ->
        if correction?(found, period.interest),
          do: correct(st, found, period, reversals?),
          else: st
    end
  end

  defp correction?(%{type: @posting, amount: amount}, interest),
    do: not Decimal.eq?(amount, interest)

  defp correction?(%{amount: amount}, interest),
    do: not Decimal.eq?(amount, Decimal.negate(interest))

  # the posting found is reversed (one made by this change is only marked) and the one asked for made, followed by
  # the reversal when those are posted
  defp correct(st, found, period, reversals?) do
    st =
      if stored?(found) do
        %{st | reverse: st.reverse ++ [found]}
      else
        %{st | create: Enum.map(st.create, &mark_reversed(&1, found.id))}
      end

    st = %{st | live: Enum.reject(st.live, &(&1.id == found.id))}
    st = add_posting(st, period)

    if reversals?,
      do: %{st | create: st.create ++ [%{kind: :reversal, original: found}]},
      else: st
  end

  defp mark_reversed(%{kind: kind, row: %{id: id}} = item, id) when kind in [:posting, :copy],
    do: %{item | reversed?: true}

  defp mark_reversed(item, _id), do: item

  defp add_posting(st, period) do
    {type, amount} =
      if Decimal.lt?(period.interest, 0),
        do: {@overdraft_interest, Decimal.negate(period.interest)},
        else: {@posting, period.interest}

    row = %{
      id: st.next,
      type: type,
      date: period.posting_date,
      amount: amount,
      manual: period.user?,
      overdraft: nil,
      payment_detail_id: nil,
      ref_no: nil
    }

    %{
      st
      | live: st.live ++ [row],
        create: st.create ++ [%{kind: :posting, reversed?: false, row: row}],
        next: st.next + 1
    }
  end

  # Fineract looks for the last posting in its list, in which new transactions come after those that were there
  defp posted_till(list) do
    list
    |> Enum.filter(&(&1.type in [@posting, @overdraft_interest]))
    |> List.last()
    |> then(&(&1 && &1.date))
  end

  # --- writing ------------------------------------------------------------------------------------

  @doc """
  Writes a plan: reverses the transactions it reverses, makes the copies and the postings it makes, works the
  balances and totals of the account out again and records what interest was earned. Answers with the transactions
  reversed and the rows made (`%{id, type, date, amount, payment_detail_id, overdraft, reversed?}`), for the books.
  """
  @spec apply!(struct, map, plan) :: %{reversed: [map], created: [map]}
  def apply!(user, account, plan) do
    ids = Enum.map(plan.reverse, & &1.id)

    TenantRepo.update_all(from(t in "m_savings_account_transaction", where: t.id in ^ids),
      set: [is_reversed: true]
    )

    created = create!(user, account, plan.create)

    ECBDeposits.Savings.Balance.refresh!(account.id)
    finish!(account, plan)
    %{reversed: plan.reverse, created: created}
  end

  defp create!(user, account, create) do
    {created, _} =
      Enum.flat_map_reduce(create, %{}, fn
        %{kind: kind, row: row, reversed?: reversed?}, ids when kind in [:posting, :copy] ->
          id = insert!(user, account, row, reversed?)
          {[Map.merge(row, %{id: id, reversed?: reversed?})], Map.put(ids, row.id, id)}

        %{kind: :reversal, original: original}, ids ->
          insert_reversal!(user, account, original)
          {[], ids}
      end)

    created
  end

  defp insert!(user, account, row, reversed?) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_savings_account_transaction",
        [
          %{
            savings_account_id: account.id,
            office_id: account.client_office_id,
            payment_detail_id: row.payment_detail_id,
            transaction_type_enum: row.type,
            is_reversed: reversed?,
            transaction_date: row.date,
            amount: row.amount,
            created_date: NaiveDateTime.utc_now(),
            created_by: user.id,
            is_manual: row.manual == true,
            ref_no: row.ref_no,
            is_reversal: false,
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

  defp insert_reversal!(user, account, original) do
    now = DateTime.utc_now()

    TenantRepo.insert_all("m_savings_account_transaction", [
      %{
        savings_account_id: account.id,
        office_id: account.client_office_id,
        payment_detail_id: original[:payment_detail_id],
        transaction_type_enum: original.type,
        is_reversed: false,
        transaction_date: original.date,
        amount: original.amount,
        created_date: NaiveDateTime.utc_now(),
        created_by: user.id,
        is_manual: original[:manual] == true,
        ref_no: original[:ref_no],
        original_transaction_id: if(stored?(original), do: original.id),
        is_reversal: true,
        is_lien_transaction: false,
        submitted_on_date: BusinessDate.current(),
        last_modified_by: user.id,
        created_on_utc: now,
        last_modified_on_utc: now
      }
    ])
  end

  # what interest was earned and when it was last posted
  defp finish!(account, plan) do
    set =
      []
      |> put_if(plan.calculating?, :total_interest_earned_derived, plan.earned)
      |> put_if(plan.calculating?, :last_interest_calculation_date, plan.up_to)
      |> put_if(plan.posted_till != nil, :interest_posted_till_date, plan.posted_till)

    if set != [],
      do:
        TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^account.id),
          set: set
        )

    :ok
  end

  defp put_if(set, true, key, value), do: Keyword.put(set, key, value)
  defp put_if(set, false, _key, _value), do: set
end
