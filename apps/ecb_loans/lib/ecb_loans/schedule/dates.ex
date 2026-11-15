defmodule ECBLoans.Schedule.Dates do
  @moduledoc """
  The dates of a repayment schedule, following Fineract's `DefaultScheduledDateGenerator` and the date helpers
  its schedule code leans on. Dates follow Java's `LocalDate` rules: adding months to the 31st lands on the
  month's last day.

  Frequencies are Fineract's period frequency numbers: 0 days, 1 weeks, 2 months, 3 years.
  """

  @doc "`date` plus `every` periods of `frequency`."
  @spec plus(Date.t(), 0..3, integer) :: Date.t()
  def plus(date, 0, every), do: Date.shift(date, day: every)
  def plus(date, 1, every), do: Date.shift(date, week: every)
  def plus(date, 2, every), do: Date.shift(date, month: every)
  def plus(date, 3, every), do: Date.shift(date, year: every)

  @doc "`date` minus `every` periods of `frequency`."
  @spec minus(Date.t(), 0..3, integer) :: Date.t()
  def minus(date, frequency, every), do: plus(date, frequency, -every)

  @doc """
  The next due date after `last`. The first one is the date the schedule was told to start from, when there is
  one; later ones add the repayment frequency to the previous date and, for a monthly loan seeded on the 29th or
  later, hold the day to the seed's day where the month is long enough.
  """
  @spec next_repayment_date(Date.t(), map, boolean) :: Date.t()
  def next_repayment_date(last, terms, first?) do
    if first? and terms.first_repayment_date != nil do
      terms.first_repayment_date
    else
      last
      |> plus(terms.repayment_frequency, terms.repayment_every)
      |> adjust_to_seed_day(terms.seed_date, terms.repayment_frequency)
    end
  end

  defp adjust_to_seed_day(date, seed, 2) when seed.day > 28 and date.day >= 28 do
    %{date | day: min(Date.days_in_month(date), seed.day)}
  end

  defp adjust_to_seed_day(date, _seed, _frequency), do: date

  @doc "The date of the last repayment, before any non-working day or holiday moves it."
  @spec last_repayment_date(map) :: Date.t()
  def last_repayment_date(terms) do
    {last, _} =
      Enum.reduce(1..terms.number_of_repayments, {terms.repayment_start, true}, fn _,
                                                                                   {last, first?} ->
        {next_repayment_date(last, terms, first?), false}
      end)

    last
  end

  @doc "Whole days from `from` to `to` (negative when `to` is earlier)."
  @spec days_between(Date.t(), Date.t()) :: integer
  def days_between(from, to), do: Date.diff(to, from)

  @doc """
  Fineract's `calculatePeriodsBetweenDates`: the length of the span from `start` to `finish` in repayment
  periods, a whole number of them and a fraction of the next one.
  """
  @spec periods_between(map, Date.t(), Date.t()) :: Decimal.t()
  def periods_between(%{repayment_frequency: 0}, start, finish),
    do: Decimal.new(days_between(start, finish))

  def periods_between(%{repayment_frequency: 1}, start, finish) do
    weeks = div(days_between(start, finish), 7)
    left = days_between(Date.shift(start, week: weeks), finish)
    Decimal.add(Decimal.new(weeks), double_quotient(left, 7))
  end

  def periods_between(%{repayment_frequency: 2} = terms, start, finish) do
    months = whole_months(start, finish)
    from = start |> Date.shift(month: months) |> adjust_to_seed_day(terms.seed_date, 2)
    till = start |> Date.shift(month: months + 1) |> adjust_to_seed_day(terms.seed_date, 2)

    Decimal.add(
      Decimal.new(months),
      double_quotient(days_between(from, finish), days_between(from, till))
    )
  end

  def periods_between(%{repayment_frequency: 3}, start, finish) do
    years = div(whole_months(start, finish), 12)
    from = Date.shift(start, year: years)
    till = Date.shift(start, year: years + 1)

    Decimal.add(
      Decimal.new(years),
      double_quotient(days_between(from, finish), days_between(from, till))
    )
  end

  # Java divides two ints as doubles here and wraps the result with `BigDecimal.valueOf(double)`
  defp double_quotient(_numerator, 0), do: Decimal.new(0)

  defp double_quotient(numerator, denominator),
    do: Decimal.from_float(numerator / denominator)

  # ChronoUnit.MONTHS.between
  defp whole_months(start, finish) do
    total = finish.year * 12 + finish.month - (start.year * 12 + start.month)

    cond do
      total > 0 and finish.day < start.day -> total - 1
      total < 0 and finish.day > start.day -> total + 1
      true -> total
    end
  end
end
