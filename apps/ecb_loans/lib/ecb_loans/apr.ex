defmodule ECBLoans.Apr do
  @moduledoc """
  The yearly interest rate Fineract keeps beside a loan's rate per period (`AprCalculator`).

  `interest_frequency` is how often the rate is quoted (0 days, 1 weeks, 2 months, 3 years, 4 whole term);
  for a whole-term rate the rate is first spread over the term's periods, to 8 decimals.
  """

  @doc "The yearly rate for `rate` quoted every `interest_frequency`."
  @spec calculate(0..4, Decimal.t(), pos_integer, pos_integer, 0..3, 1 | 360 | 364 | 365) ::
          Decimal.t()
  def calculate(interest_frequency, rate, repayments, every, repayment_frequency, days_in_year) do
    case interest_frequency do
      0 -> Decimal.mult(rate, days(days_in_year))
      1 -> Decimal.mult(rate, 52)
      2 -> Decimal.mult(rate, 12)
      3 -> rate
      4 -> whole_term(rate, repayments * every, repayment_frequency, days_in_year)
    end
  end

  defp whole_term(rate, periods, frequency, days_in_year) do
    per_period = rate |> Decimal.div(periods) |> Decimal.round(8, :half_even)

    case frequency do
      0 -> Decimal.mult(per_period, days(days_in_year))
      1 -> Decimal.mult(per_period, 52)
      2 -> Decimal.mult(per_period, 12)
      3 -> per_period
    end
  end

  defp days(1), do: 365
  defp days(days), do: days
end
