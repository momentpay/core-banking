defmodule ECBLoans.Schedule.Rates do
  @moduledoc """
  The interest rate of a repayment period, as Fineract's `LoanApplicationTerms` works it out from the yearly
  rate. Quotients and products are rounded to 19 significant digits (`ECBMoney.Precision`), the way Java's
  `MathContext` does.
  """
  alias ECBLoans.Schedule.Dates
  alias ECBMoney.Precision

  @digits 19

  @doc """
  The rate to charge on a balance for the period from `from` to `to`, as a fraction (0.01 is 1%).

  `days_in_month` (1 actual, 30) and `days_in_year` (1 actual, 360, 364, 365) matter when interest is worked out
  by the day. `for_emi?` is true when the rate is the one the EMI formula uses: it counts whole repayment
  periods instead of looking at the dates.
  """
  @spec periodic(map, 1 | 30, 1 | 360 | 364 | 365, Date.t(), Date.t(), boolean) :: Decimal.t()
  def periodic(terms, days_in_month, days_in_year, from, to, for_emi?) do
    per_year = periods_in_one_year(terms)

    frequency =
      if for_emi?, do: Decimal.new(terms.repayment_every), else: term_frequency(terms, from, to)

    case terms.interest_calculation_period do
      0 -> daily(terms, per_year, frequency, days_in_month, days_in_year, from, to)
      _ -> same_as_repayment(terms, per_year, frequency)
    end
  end

  defp same_as_repayment(terms, per_year, frequency) do
    terms.annual_rate
    |> divide(Decimal.new(per_year))
    |> divide(Decimal.new(100))
    |> exact_mult(frequency)
  end

  defp daily(terms, per_year, frequency, days_in_month, days_in_year, from, to) do
    one_day =
      terms.annual_rate
      |> divide(Decimal.new(per_year))
      |> divide(Decimal.new(100))

    days = Decimal.new(Dates.days_between(from, to))

    days =
      case terms.repayment_frequency do
        2 when days_in_month == 30 -> multiply(frequency, Decimal.new(30))
        3 -> year_days(frequency, days, days_in_year)
        _ -> days
      end

    multiply(one_day, days)
  end

  defp year_days(_frequency, days, 1), do: days
  defp year_days(frequency, _days, count), do: multiply(frequency, Decimal.new(count))

  defp term_frequency(terms, from, to) do
    if terms.interest_calculation_period == 0 or terms.allow_partial_period do
      Dates.periods_between(terms, from, to)
    else
      Decimal.new(terms.repayment_every)
    end
  end

  @doc """
  The part of the yearly rate that falls on the whole loan term, for flat interest:
  yearly rate / periods in a year / 100 x periods in the term.
  """
  @spec flat_for_term(map) :: Decimal.t()
  def flat_for_term(terms) do
    terms.annual_rate
    |> divide(Decimal.new(periods_in_one_year(terms)))
    |> divide(Decimal.new(100))
    |> multiply(periods_in_term(terms))
  end

  defp periods_in_term(terms) do
    case terms.interest_calculation_period do
      0 ->
        start =
          if terms.interest_charged_from &&
               Date.compare(terms.disbursement_date, terms.interest_charged_from) == :lt,
             do: terms.interest_charged_from,
             else: terms.disbursement_date

        Decimal.new(Dates.days_between(start, terms.loan_end_date))

      _ ->
        if terms.allow_partial_period do
          start = terms.interest_charged_from || terms.disbursement_date
          Dates.periods_between(terms, start, terms.loan_end_date)
        else
          Decimal.new(terms.loan_term_frequency)
        end
    end
  end

  @doc "How many repayment periods (or days, when interest is by the day) make a year."
  @spec periods_in_one_year(map) :: pos_integer
  def periods_in_one_year(terms) do
    actual? = terms.days_in_year == 1

    base =
      if terms.repayment_frequency == 0 and not actual?,
        do: terms.days_in_year,
        else: calendar_periods(terms.repayment_frequency)

    if terms.interest_calculation_period == 0,
      do: if(actual?, do: 365, else: terms.days_in_year),
      else: base
  end

  defp calendar_periods(0), do: 365
  defp calendar_periods(1), do: 52
  defp calendar_periods(2), do: 12
  defp calendar_periods(3), do: 1

  # --- Java BigDecimal arithmetic ------------------------------------------------------------

  defp divide(a, b), do: Precision.divide(a, b, @digits, :half_even)

  defp multiply(a, b),
    do: Precision.round_significant(exact_mult(a, b), @digits, :half_even)

  defp exact_mult(a, b), do: Precision.exact(fn -> Decimal.mult(a, b) end)
end
