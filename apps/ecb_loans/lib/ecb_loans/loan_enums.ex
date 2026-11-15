defmodule ECBLoans.LoanEnums do
  @moduledoc """
  The fixed choices a loan product is built from, as `{id, code, value}`, following Fineract's
  `LoanEnumerations` and `PeriodFrequencyType`.
  """

  @repayment_frequency [
    {0, "repaymentFrequency.periodFrequencyType.days", "Days"},
    {1, "repaymentFrequency.periodFrequencyType.weeks", "Weeks"},
    {2, "repaymentFrequency.periodFrequencyType.months", "Months"},
    {3, "repaymentFrequency.periodFrequencyType.years", "Years"}
  ]

  @interest_frequency [
    {0, "interestRateFrequency.periodFrequencyType.days", "Per day"},
    {1, "interestRateFrequency.periodFrequencyType.weeks", "Per week"},
    {2, "interestRateFrequency.periodFrequencyType.months", "Per month"},
    {3, "interestRateFrequency.periodFrequencyType.years", "Per year"},
    {4, "interestRateFrequency.periodFrequencyType.whole_term", "Whole term"}
  ]

  @amortization [
    {0, "amortizationType.equal.principal", "Equal principal payments"},
    {1, "amortizationType.equal.installments", "Equal installments"}
  ]

  @interest_type [
    {0, "interestType.declining.balance", "Declining Balance"},
    {1, "interestType.flat", "Flat"}
  ]

  @interest_period [
    {0, "interestCalculationPeriodType.daily", "Daily"},
    {1, "interestCalculationPeriodType.same.as.repayment.period", "Same as repayment period"}
  ]

  @days_in_month [
    {1, "DaysInMonthType.actual", "Actual"},
    {30, "DaysInMonthType.days360", "30 Days"}
  ]

  @days_in_year [
    {1, "DaysInYearType.actual", "Actual"},
    {360, "DaysInYearType.days360", "360 Days"},
    {364, "DaysInYearType.days364", "364 Days"},
    {365, "DaysInYearType.days365", "365 Days"}
  ]

  @repayment_start [
    {1, "repaymentStartDateType.disbursementDate", "Disbursement Date"},
    {2, "repaymentStartDateType.submittedOnDate", "Submitted On Date"}
  ]

  @accounting [
    {1, "accountingRuleType.none", "NONE"},
    {2, "accountingRuleType.cash", "CASH BASED"},
    {3, "accountingRuleType.accrual.periodic", "ACCRUAL PERIODIC"},
    {4, "accountingRuleType.accrual.upfront", "ACCRUAL UPFRONT"}
  ]

  @tables %{
    repayment_frequency: @repayment_frequency,
    interest_frequency: @interest_frequency,
    amortization: @amortization,
    interest_type: @interest_type,
    interest_period: @interest_period,
    days_in_month: @days_in_month,
    days_in_year: @days_in_year,
    repayment_start: @repayment_start,
    accounting: @accounting
  }

  @doc "One choice of a kind as an option map, or `nil` when there is no such choice."
  @spec option(atom, integer | nil) :: map | nil
  def option(_kind, nil), do: nil

  # Fineract names only months, years and whole term when it shows how often interest is quoted; a rate per day
  # or per week is accepted and stored but shown as "Invalid"
  def option(:interest_frequency, id) when id in [0, 1],
    do: %{id: 5, code: "periodFrequencyType.invalid", value: "Invalid"}

  def option(kind, id) do
    case List.keyfind(Map.fetch!(@tables, kind), id, 0) do
      {id, code, value} -> %{id: id, code: code, value: value}
      nil -> nil
    end
  end

  @doc "The ids a kind may have."
  @spec ids(atom) :: [integer]
  def ids(kind), do: kind |> then(&Map.fetch!(@tables, &1)) |> Enum.map(&elem(&1, 0))
end
