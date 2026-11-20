defmodule ECBDeposits.DepositAccounts.Maturity do
  @moduledoc """
  The maturity date and amount of a fixed deposit, after Fineract's `FixedDepositAccount.calculateMaturityDate`,
  `updateMaturityDateAndAmount` and `getEffectiveInterestRateAsFraction`, and the rate the interest rate chart of an
  account gives (`DepositAccountInterestRateChart.getApplicableInterestRate`). The maturity amount is the deposit
  plus the interest it earns from the day it starts until the day before the maturity date, worked out as the posting
  periods of the account say.
  """
  alias ECBDeposits.Savings.Interest.Calc
  alias ECBMoney.Precision
  alias ECBPlatform.{BusinessDate, Configuration}

  @doc "The day a term that starts on `start` ends: `period` days (0), weeks (1), months (2) or years (3) later."
  @spec date(Date.t(), integer, integer | nil) :: Date.t() | nil
  def date(start, period, 0), do: Date.add(start, period)
  def date(start, period, 1), do: Date.add(start, period * 7)
  def date(start, period, 2), do: add_months(start, period)
  def date(start, period, 3), do: add_months(start, period * 12)
  def date(_start, _period, _unit), do: nil

  # Java's `plusMonths`: the day of the month stays unless the month is shorter
  defp add_months(%Date{year: y, month: m, day: d}, months) do
    total = y * 12 + (m - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    day = min(d, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, day)
  end

  @doc "Whole units of `unit` between two dates (Java's `ChronoUnit.between`)."
  @spec between(Date.t(), Date.t(), integer | nil) :: integer
  def between(from, to, 0), do: Date.diff(to, from)
  def between(from, to, 1), do: div(Date.diff(to, from), 7)
  def between(from, to, 2), do: months_between(from, to)
  def between(from, to, 3), do: div(months_between(from, to), 12)
  def between(_from, _to, _unit), do: 0

  defp months_between(from, to) do
    months = (to.year - from.year) * 12 + (to.month - from.month)

    cond do
      months > 0 and to.day < from.day -> months - 1
      months < 0 and to.day > from.day -> months + 1
      true -> months
    end
  end

  @doc """
  The annual rate the slabs of a chart give a deposit of `amount` from `start` to `close`: that of the last slab
  that fits the length of the term and the amount, or zero.
  """
  @spec rate([map], Decimal.t(), Date.t(), Date.t()) :: Decimal.t()
  def rate(slabs, amount, start, close) do
    Enum.reduce(slabs, Decimal.new(0), fn slab, rate ->
      if period_fits?(slab, start, close) and amount_fits?(slab, amount),
        do: slab.rate,
        else: rate
    end)
  end

  defp period_fits?(slab, start, close) do
    periods = between(start, close, slab.period_type)

    case {slab.from_period, slab.to_period} do
      {from, to} when from != nil and to != nil -> periods >= from and periods <= to
      {from, nil} when from != nil -> periods >= from
      _ -> true
    end
  end

  defp amount_fits?(slab, amount) do
    case {slab.amount_from, slab.amount_to} do
      {from, to} when from != nil and to != nil ->
        Decimal.compare(amount, from) != :lt and Decimal.compare(amount, to) != :gt

      {from, nil} when from != nil ->
        Decimal.compare(amount, from) != :lt

      _ ->
        true
    end
  end

  @doc """
  The interest a deposit earns over its term. `a` holds `start`, `maturity`, `amount`, the `rate` (percent), the
  `posting`, `compounding`, `calculation` and `days_in_year` of the account, its `min_balance` for interest and the
  `decimals` of the currency.
  """
  @spec interest(map) :: Decimal.t()
  def interest(a) do
    deposit = %{id: 1, type: 1, date: a.start, amount: a.amount, manual: false, overdraft: nil}
    interest_on([deposit], a)
  end

  @doc """
  The interest the deposits (`%{id, type, date, amount, manual, overdraft}`) earn from the start of the term until the
  day before the maturity date, with the settings `interest/1` takes.
  """
  @spec interest_on([map], map) :: Decimal.t()
  def interest_on(deposits, a) do
    up_to = Date.add(a.maturity, -1)

    %{
      start: a.start,
      up_to: up_to,
      posting_type: a.posting,
      compounding_type: a.compounding,
      calculation_type: a.calculation,
      days_in_year: a.days_in_year,
      rate: Precision.divide(a.rate, Decimal.new(100), 16, :half_even),
      overdraft_rate: Decimal.new(0),
      min_balance: a.min_balance || Decimal.new(0),
      min_overdraft: Decimal.new(0),
      decimals: a.decimals,
      allow_overdraft: false,
      fy_begin: financial_year_begin(),
      at_period_end: at_period_end?(),
      as_on: [],
      business_date: BusinessDate.current(),
      txs: Calc.balances(deposits, up_to)
    }
    |> Calc.periods()
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&1.interest, &2))
  end

  @doc "The maturity amount of a deposit: the amount and what it earns until the maturity date."
  @spec amount(map) :: Decimal.t()
  def amount(a), do: Decimal.add(a.amount, interest(a))

  defp at_period_end?,
    do: match?(%{enabled: true}, Configuration.get("savings-interest-posting-current-period-end"))

  defp financial_year_begin do
    case Configuration.get("financial-year-beginning-month") do
      %{value: value} when is_integer(value) -> value
      %{value: value} when is_binary(value) -> String.to_integer(String.trim(value))
      %{value: %Decimal{} = value} -> Decimal.to_integer(value)
      _ -> 1
    end
  end
end
