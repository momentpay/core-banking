defmodule ECBDeposits.Savings.Interest.Calc do
  @moduledoc """
  Works out the interest of a savings account over its posting periods, as Fineract does in `PostingPeriod`,
  `EndOfDayBalance`, the compounding periods and `CompoundInterestHelper`: the balance of every day, the interest
  of every compounding period (on the balance of each day, or on the average of the period, compounded daily or
  carried to the next period), the sum rounded to the currency for each posting period.

  Arithmetic follows `java.math.BigDecimal` with the contexts Fineract uses: 16 significant digits for products and
  quotients, nine decimals for the interest on a balance, and the currency's decimals for what is posted. Pure: it
  takes the transactions and the settings of the account and answers with the periods.
  """
  alias ECBDeposits.Savings.Interest.Periods
  alias ECBMoney.Precision

  @mode :half_even
  @digits 16
  @credit_types [1, 3, 8, 21]
  @debit_types [2, 4, 5, 7, 17, 18, 19, 20]
  @interest_types [3, 17]
  @charge_types [4, 5, 7]

  @type tx :: %{id: integer, date: Date.t(), amount: Decimal.t(), type: integer}

  @doc "Whether a transaction type adds to the balance (`:credit`), takes from it (`:debit`) or leaves it alone."
  @spec direction(integer) :: :credit | :debit | nil
  def direction(type) when type in @credit_types, do: :credit
  def direction(type) when type in @debit_types, do: :debit
  def direction(_type), do: nil

  @doc "Puts transactions in the order they happened: by date, then by id."
  @spec order([map]) :: [map]
  def order(txs), do: Enum.sort_by(txs, &{Date.to_gregorian_days(&1.date), &1.id})

  @doc "The balance after each transaction of a list in the order they happened: `[{tx, balance}]`."
  @spec running([tx]) :: [{tx, Decimal.t()}]
  def running(txs) do
    {rows, _} =
      Enum.map_reduce(txs, Decimal.new(0), fn tx, balance ->
        balance =
          case direction(tx.type) do
            :credit -> Decimal.add(balance, tx.amount)
            :debit -> Decimal.sub(balance, tx.amount)
            nil -> balance
          end

        {{tx, balance}, balance}
      end)

    rows
  end

  @doc """
  How much of each transaction of a list in the order they happened was taken from, or paid into, an overdrawn
  account: `%{id => amount}`, as `SavingsAccount.recalculateDailyBalances` works it out.
  """
  @spec overdrafts([tx]) :: %{optional(term) => Decimal.t()}
  def overdrafts(txs) do
    {map, _} =
      Enum.reduce(txs, {%{}, Decimal.new(0)}, fn tx, {map, running} ->
        {over, after_} = overdraft_of(direction(tx.type), tx.amount, running)

        over =
          if Decimal.eq?(over, 0) and Decimal.lt?(after_, 0) and tx.type != 20,
            do: Decimal.negate(after_),
            else: over

        {Map.put(map, tx.id, over), after_}
      end)

    map
  end

  defp overdraft_of(:credit, amount, running) do
    over =
      if Decimal.lt?(running, 0) do
        diff = Decimal.add(amount, running)
        if Decimal.gt?(diff, 0), do: Decimal.sub(amount, diff), else: amount
      else
        Decimal.new(0)
      end

    {over, Decimal.add(running, amount)}
  end

  defp overdraft_of(:debit, amount, running),
    do:
      {if(Decimal.lt?(running, 0), do: amount, else: Decimal.new(0)),
       Decimal.sub(running, amount)}

  defp overdraft_of(nil, _amount, running), do: {Decimal.new(0), running}

  @doc """
  The transactions that interest is worked out on (everything but the postings of interest), each with the balance
  it left (`:balance`), the last day that balance held (`:end_date`) and for how many days (`:days`, none for a
  transaction followed by another of the same day). `txs` are the live transactions in the order they happened;
  `up_to` the day the last balance holds until.
  """
  @spec balances([tx], Date.t()) :: [map]
  def balances(txs, up_to) do
    rows = txs |> running() |> Enum.reject(fn {tx, _} -> tx.type in @interest_types end)

    {out, _} =
      rows
      |> Enum.reverse()
      |> Enum.map_reduce(up_to, fn {tx, balance}, ends ->
        end_date = if Date.compare(ends, tx.date) == :lt, do: tx.date, else: ends
        days = Date.diff(ends, tx.date) + 1

        {Map.merge(tx, %{balance: balance, end_date: end_date, days: days}),
         Date.add(tx.date, -1)}
      end)

    Enum.reverse(out)
  end

  @doc """
  The posting periods of an account with the interest each earns. `p` holds the settings: `:start` (the day interest
  begins), `:up_to`, `:posting_type`, `:compounding_type`, `:calculation_type`, `:days_in_year`, `:rate` and
  `:overdraft_rate` (as a fraction), `:min_balance`, `:min_overdraft`, `:decimals`, `:allow_overdraft`,
  `:fy_begin`, `:at_period_end`, `:as_on` (the dates of manual postings), `:business_date` and `:txs` (from
  `balances/2`). Each period comes back as `%{from, to, posting_date, interest, user?}`; `interest` is rounded to
  the currency, and negative when the account was overdrawn.
  """
  @spec periods(map) :: [map]
  def periods(p) do
    intervals = Periods.posting_periods(p.start, p.up_to, p.posting_type, p.fy_begin, p.as_on)

    {rows, _, _} =
      Enum.reduce(intervals, {[], Decimal.new(0), {Decimal.new(0), Decimal.new(0)}}, fn interval,
                                                                                        {acc,
                                                                                         start,
                                                                                         values} ->
        {closing, eods} = end_of_day_balances(interval, start, p)
        {earned, values} = interest_of_period(interval, eods, values, p)
        {from, to} = interval

        row = %{
          from: from,
          to: to,
          posting_date: if(p.at_period_end, do: to, else: Date.add(to, 1)),
          interest: round_to(earned, p.decimals),
          user?: Date.add(to, 1) in p.as_on
        }

        {[row | acc], closing, values}
      end)

    Enum.reverse(rows)
  end

  # --- the balance of every day -----------------------------------------------------------------

  defp end_of_day_balances({from, to} = interval, start, p) do
    {opening, eods} =
      Enum.reduce(p.txs, {start, []}, fn tx, {opening, acc} ->
        cond do
          inside?(interval, {tx.date, tx.end_date}) ->
            eod = to_eod(tx, opening, p)
            {eod.closing, [eod | acc]}

          holds_any?({tx.date, tx.end_date}, interval) ->
            eod = to_bounded_eod(tx, opening, interval, p)
            {eod.closing, [eod | acc]}

          true ->
            {opening, acc}
        end
      end)

    eods = Enum.reverse(eods)

    if eods == [] do
      last = if after?(to, p.up_to), do: p.up_to, else: to

      {opening,
       [%{date: from, opening: opening, closing: opening, days: Date.diff(last, from) + 1}]}
    else
      {opening, eods}
    end
  end

  # the balance a transaction leaves, for the days it holds
  defp to_eod(tx, opening, p),
    do: %{date: tx.date, opening: opening, closing: apply_tx(tx, opening, p), days: tx.days}

  defp to_bounded_eod(tx, opening, {from, to}, p) do
    {start, closing, days} =
      if after?(from, tx.date),
        do: {from, opening, Date.diff(tx.end_date, from) + 1},
        else: {tx.date, apply_tx(tx, opening, p), tx.days}

    days = if after?(tx.end_date, to), do: Date.diff(to, start) + 1, else: days
    %{date: start, opening: opening, closing: closing, days: days}
  end

  defp apply_tx(%{type: type, amount: amount} = tx, opening, p) do
    cond do
      type in [1, 8] ->
        Decimal.add(opening, amount)

      type == 2 or type in @charge_types ->
        if Decimal.gt?(opening, 0) or p.allow_overdraft,
          do: Decimal.sub(opening, amount),
          else: tx.balance

      true ->
        opening
    end
  end

  # --- the interest of a posting period ---------------------------------------------------------

  defp interest_of_period(interval, eods, values, p) do
    interval
    |> Periods.compounding_periods(p.compounding_type, p.fy_begin, p.business_date)
    |> Enum.reduce({Decimal.new(0), values}, fn {from, to} = compounding,
                                                {earned, {compounded, uncompounded}} ->
      balances = balances_within(compounding, eods, p)
      interest = compounding_interest(balances, compounded, p)
      uncompounded = add(uncompounded, interest)

      ends =
        if p.compounding_type == 1,
          do: to,
          else: Periods.compounding_end(from, p.compounding_type, p.fy_begin, p.business_date)

      values =
        if Date.compare(ends, to) == :eq,
          do: {add(compounded, uncompounded), Decimal.new(0)},
          else: {compounded, uncompounded}

      {add(earned, interest), values}
    end)
  end

  # the balances of the days of a compounding period, cut to it
  defp balances_within(interval, eods, %{compounding_type: 1} = p) do
    Enum.map(eods, fn eod ->
      cond do
        inside_date?(interval, eod.date) -> up_to(eod, interval, p.up_to)
        holds_any?(eod_span(eod), interval) -> up_to(eod, interval, p.up_to)
        true -> up_to(eod, {elem(interval, 0), p.up_to}, p.up_to)
      end
    end)
  end

  defp balances_within(interval, eods, p) do
    eods
    |> Enum.filter(&(inside_date?(interval, &1.date) or holds_any?(eod_span(&1), interval)))
    |> Enum.map(&up_to(&1, interval, p.up_to))
  end

  defp eod_span(eod), do: {eod.date, Date.add(eod.date, eod.days - 1)}

  defp up_to(eod, {from, to}, up_to) do
    old_end = Date.add(eod.date, eod.days - 1)

    {start, opening, days} =
      if Date.compare(eod.date, from) == :lt,
        do: {from, eod.closing, Date.diff(old_end, from) + 1},
        else: {eod.date, eod.opening, eod.days}

    days = if after?(Date.add(start, days - 1), to), do: Date.diff(to, start) + 1, else: days

    days =
      if after?(Date.add(start, days - 1), up_to), do: Date.diff(up_to, start) + 1, else: days

    %{date: start, opening: opening, closing: eod.closing, days: days}
  end

  # daily compounding: every day's interest is compounded into the next balance
  defp compounding_interest(balances, compounded, %{compounding_type: 1} = p) do
    {_, earned} =
      Enum.reduce(balances, {compounded, Decimal.new(0)}, fn eod, {to_compound, earned} ->
        interest = on_balance_and_interest(eod, to_compound, p)
        to_compound = to_compound |> add(interest) |> sig() |> Decimal.round(9, @mode)
        {to_compound, add(earned, interest)}
      end)

    earned
  end

  defp compounding_interest(balances, compounded, %{calculation_type: 2} = p),
    do: average_daily_balance(balances, compounded, p)

  defp compounding_interest(balances, compounded, p),
    do:
      Enum.reduce(balances, Decimal.new(0), fn eod, earned ->
        add(earned, on_balance(eod, compounded, p))
      end)

  # simple interest on the balance (and the interest carried) for the days it held
  defp on_balance(eod, to_compound, p) do
    real = add(eod.closing, to_compound)
    simple(real, eod.days, p)
  end

  defp simple(real, days, p) do
    cond do
      Decimal.gte?(real, 0) and Decimal.gte?(real, p.min_balance) ->
        earn(real, p.rate, days, p)

      Decimal.lt?(real, 0) and Decimal.lt?(real, Decimal.negate(p.min_overdraft)) ->
        earn(real, p.overdraft_rate, days, p)

      true ->
        Decimal.new(0)
    end
  end

  defp earn(balance, rate, days, p) do
    daily = mul(rate, divide(Decimal.new(1), Decimal.new(p.days_in_year)))
    periodic = mul(daily, Decimal.new(days))
    balance |> mul(periodic) |> Decimal.round(9, @mode)
  end

  # the interest on the average of the balances of the period
  defp average_daily_balance(balances, compounded, p) do
    {cumulative, days} =
      Enum.reduce(balances, {Decimal.new(0), 0}, fn eod, {cumulative, days} ->
        each =
          eod.closing |> add(compounded) |> mul(Decimal.new(eod.days)) |> Decimal.round(9, @mode)

        {add(cumulative, each), days + eod.days}
      end)

    if not Decimal.eq?(cumulative, 0) and days > 0 do
      average = cumulative |> divide(Decimal.new(days)) |> Decimal.round(9, @mode)
      simple(average, days, p)
    else
      Decimal.new(0)
    end
  end

  # interest on the balance with the interest carried, compounded for every day: FV = PV x (1 + r) ^ n
  defp on_balance_and_interest(eod, to_compound, p) do
    present = add(eod.closing, to_compound)

    future =
      cond do
        Decimal.gte?(present, 0) and Decimal.gte?(present, p.min_balance) ->
          grow(present, p.rate, eod.days, p)

        Decimal.lt?(present, 0) and Decimal.lt?(present, Decimal.negate(p.min_overdraft)) ->
          grow(present, p.overdraft_rate, eod.days, p)

        true ->
          Decimal.round(present, 9, @mode)
      end

    Decimal.sub(future, present)
  end

  defp grow(present, rate, days, p) do
    r = exact(fn -> Decimal.mult(rate, divide(Decimal.new(1), Decimal.new(p.days_in_year))) end)
    base = r |> add(Decimal.new(1)) |> Decimal.to_float()
    powered = :math.pow(base, days * 1.0)
    present |> mul(Decimal.from_float(powered)) |> Decimal.round(9, @mode)
  end

  # --- BigDecimal arithmetic ----------------------------------------------------------------------

  defp add(a, b), do: exact(fn -> Decimal.add(a, b) end)
  defp mul(a, b), do: a |> exact_mul(b) |> sig()
  defp exact_mul(a, b), do: exact(fn -> Decimal.mult(a, b) end)
  defp divide(a, b), do: Precision.divide(a, b, @digits, @mode)
  defp sig(value), do: Precision.round_significant(value, @digits, @mode)
  defp exact(fun), do: Precision.exact(fun)

  defp round_to(value, decimals), do: Decimal.round(value, decimals, @mode)

  # --- dates --------------------------------------------------------------------------------------

  defp after?(a, b), do: Date.compare(a, b) == :gt

  defp inside?({from, to}, {a, b}),
    do: Date.compare(a, from) != :lt and Date.compare(b, to) != :gt

  defp inside_date?({from, to}, date),
    do: Date.compare(date, from) != :lt and Date.compare(date, to) != :gt

  # the span of days `{a, b}` holds the first or the last day of `{from, to}`
  defp holds_any?({a, b}, {from, to}), do: inside_date?({a, b}, from) or inside_date?({a, b}, to)
end
