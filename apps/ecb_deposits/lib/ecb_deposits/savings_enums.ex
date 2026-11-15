defmodule ECBDeposits.SavingsEnums do
  @moduledoc """
  The fixed choices a savings product is built from, as `{id, code, value}` (Fineract's `SavingsEnumerations`
  and the dropdown lists of `SavingsDropdownReadPlatformServiceImpl`).
  """

  @compounding_prefix "savings.interest.period.savingsCompoundingInterestPeriodType."
  @posting_prefix "savings.interest.posting.period.savingsPostingInterestPeriodType."

  @compounding [
    {1, @compounding_prefix <> "daily", "Daily"},
    {4, @compounding_prefix <> "monthly", "Monthly"},
    {5, @compounding_prefix <> "quarterly", "Quarterly"},
    {6, @compounding_prefix <> "biannual", "Semi-Annual"},
    {7, @compounding_prefix <> "annual", "Annually"}
  ]

  @posting [
    {1, @posting_prefix <> "daily", "Daily"},
    {4, @posting_prefix <> "monthly", "Monthly"},
    {5, @posting_prefix <> "quarterly", "Quarterly"},
    {6, @posting_prefix <> "biannual", "BiAnnual"},
    {7, @posting_prefix <> "annual", "Annually"},
    {8, @posting_prefix <> "anniversaryMonthly", "Anniversary Monthly"},
    {9, @posting_prefix <> "anniversaryQuarterly", "Anniversary Quarterly"},
    {10, @posting_prefix <> "anniversaryBiAnnual", "Anniversary BiAnnual"},
    {11, @posting_prefix <> "anniversaryAnnual", "Anniversary Annually"}
  ]

  @calculation [
    {1, "savingsInterestCalculationType.dailybalance", "Daily Balance"},
    {2, "savingsInterestCalculationType.averagedailybalance", "Average Daily Balance"}
  ]

  @days_in_year [
    {360, "savingsInterestCalculationDaysInYearType.days360", "360 Days"},
    {365, "savingsInterestCalculationDaysInYearType.days365", "365 Days"}
  ]

  @lockin [
    {0, "savings.lockin.savingsPeriodFrequencyType.days", "Days"},
    {1, "savings.lockin.savingsPeriodFrequencyType.weeks", "Weeks"},
    {2, "savings.lockin.savingsPeriodFrequencyType.months", "Months"},
    {3, "savings.lockin.savingsPeriodFrequencyType.years", "Years"}
  ]

  @withdrawal_fee [
    {1, "savingsWithdrawalFeesType.flat", "Flat"},
    {2, "savingsWithdrawalFeesType.percent.of.amount", "% of Amount"}
  ]

  @accounting [
    {1, "accountingRuleType.none", "NONE"},
    {2, "accountingRuleType.cash", "CASH BASED"},
    {3, "accountingRuleType.accrual.periodic", "ACCRUAL PERIODIC"},
    {4, "accountingRuleType.accrual.upfront", "ACCRUAL UPFRONT"}
  ]

  @doc "The compounding periods, as options."
  def compounding, do: options(@compounding)
  @doc "The posting periods, as options."
  def posting, do: options(@posting)
  @doc "The ways interest is calculated, as options."
  def calculation, do: options(@calculation)
  @doc "The day counts of a year, as options."
  def days_in_year, do: options(@days_in_year)
  @doc "The units of a lock-in period, as options."
  def lockin, do: options(@lockin)
  @doc "The kinds of withdrawal fee, as options."
  def withdrawal_fee, do: options(@withdrawal_fee)
  @doc "The accounting rules, as options."
  def accounting, do: options(@accounting)

  @doc "The ids a compounding period may have."
  def compounding_ids, do: ids(@compounding)
  @doc "The ids a posting period may have."
  def posting_ids, do: ids(@posting)
  @doc "The ids an interest calculation type may have."
  def calculation_ids, do: ids(@calculation)
  @doc "The ids a day count may have."
  def days_in_year_ids, do: ids(@days_in_year)

  @doc "One compounding period as an option, or `nil`."
  def compounding(id), do: one(@compounding, id)
  @doc "One posting period as an option, or `nil`."
  def posting(id), do: one(@posting, id)
  @doc "One calculation type as an option, or `nil`."
  def calculation(id), do: one(@calculation, id)
  @doc "One day count as an option, or `nil`."
  def days_in_year(id), do: one(@days_in_year, id)
  @doc "One lock-in unit as an option, or `nil`."
  def lockin(id), do: one(@lockin, id)
  @doc "One accounting rule as an option, or `nil`."
  def accounting(id), do: one(@accounting, id)

  defp options(list),
    do: Enum.map(list, fn {id, code, value} -> %{id: id, code: code, value: value} end)

  defp ids(list), do: Enum.map(list, &elem(&1, 0))

  defp one(_list, nil), do: nil

  defp one(list, id) do
    case List.keyfind(list, id, 0) do
      {id, code, value} -> %{id: id, code: code, value: value}
      nil -> nil
    end
  end
end
