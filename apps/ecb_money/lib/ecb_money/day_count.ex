defmodule ECBMoney.DayCount do
  @moduledoc """
  Day-count conventions used by interest calculation, with Fineract's numeric codes.

  Fineract stores these as integers on loan and savings products and sends them in the API, so the
  codes below are part of the contract:

  | Setting         | Code | Meaning                                            |
  |-----------------|-----:|----------------------------------------------------|
  | days in year    | 1    | actual: 365, or 366 in a leap year                 |
  | days in year    | 360  | 360 days                                           |
  | days in year    | 364  | 364 days                                           |
  | days in year    | 365  | 365 days                                           |
  | days in month   | 1    | actual: the real length of the month               |
  | days in month   | 30   | 30 days                                            |

  This module only answers "how many days". Turning that into an interest fraction for a period is
  done where the loan or savings schedule is built, on top of these.

  Mirrors `DaysInYearType`, `DaysInMonthType` and `DaysInYearCustomStrategyType` in
  `org.apache.fineract.portfolio.common.domain`.
  """

  @type days_in_year :: :actual | :days_360 | :days_364 | :days_365 | :invalid
  @type days_in_month :: :actual | :days_30 | :invalid
  @type custom_strategy :: :full_leap_year | :feb_29_period_only

  @doc "The days-in-year type for a Fineract code. Unknown codes and `nil` give `:invalid`."
  @spec days_in_year_from_int(integer | nil) :: days_in_year
  def days_in_year_from_int(1), do: :actual
  def days_in_year_from_int(360), do: :days_360
  def days_in_year_from_int(364), do: :days_364
  def days_in_year_from_int(365), do: :days_365
  def days_in_year_from_int(_other), do: :invalid

  @doc "The Fineract code of a days-in-year type (`:invalid` is 0)."
  @spec days_in_year_to_int(days_in_year) :: integer
  def days_in_year_to_int(:invalid), do: 0
  def days_in_year_to_int(:actual), do: 1
  def days_in_year_to_int(:days_360), do: 360
  def days_in_year_to_int(:days_364), do: 364
  def days_in_year_to_int(:days_365), do: 365

  @doc """
  Days in the year containing `reference_date`. `:actual` follows the calendar; the others are fixed.
  `nil` gives `nil`.
  """
  @spec days_in_year(days_in_year, Date.t() | nil) :: pos_integer | nil
  def days_in_year(_type, nil), do: nil
  def days_in_year(:actual, %Date{} = date), do: if(Date.leap_year?(date), do: 366, else: 365)
  def days_in_year(:days_360, %Date{}), do: 360
  def days_in_year(:days_364, %Date{}), do: 364
  def days_in_year(:days_365, %Date{}), do: 365
  def days_in_year(:invalid, %Date{}), do: 0

  @doc "The days-in-month type for a Fineract code. Unknown codes and `nil` give `:invalid`."
  @spec days_in_month_from_int(integer | nil) :: days_in_month
  def days_in_month_from_int(1), do: :actual
  def days_in_month_from_int(30), do: :days_30
  def days_in_month_from_int(_other), do: :invalid

  @doc "The Fineract code of a days-in-month type (`:invalid` is 0)."
  @spec days_in_month_to_int(days_in_month) :: integer
  def days_in_month_to_int(:invalid), do: 0
  def days_in_month_to_int(:actual), do: 1
  def days_in_month_to_int(:days_30), do: 30

  @doc "Days in the month containing `reference_date`. `nil` gives `nil`."
  @spec days_in_month(days_in_month, Date.t() | nil) :: pos_integer | nil
  def days_in_month(_type, nil), do: nil
  def days_in_month(:actual, %Date{} = date), do: Date.days_in_month(date)
  def days_in_month(:days_30, %Date{}), do: 30
  def days_in_month(:invalid, %Date{}), do: 0

  @doc "The two custom strategies for leap years that Fineract offers, as atoms."
  @spec custom_strategies() :: [custom_strategy]
  def custom_strategies, do: [:full_leap_year, :feb_29_period_only]
end
