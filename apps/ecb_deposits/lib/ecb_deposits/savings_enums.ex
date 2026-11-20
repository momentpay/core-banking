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

  @statuses [
    {100, "savingsAccountStatusType.submitted.and.pending.approval",
     "Submitted and pending approval"},
    {200, "savingsAccountStatusType.approved", "Approved"},
    {300, "savingsAccountStatusType.active", "Active"},
    {400, "savingsAccountStatusType.withdrawn.by.applicant", "Withdrawn by applicant"},
    {500, "savingsAccountStatusType.rejected", "Rejected"},
    {600, "savingsAccountStatusType.closed", "Closed"},
    {700, "savingsAccountStatusType.pre.mature.closure", "Premature Closed"},
    {800, "savingsAccountStatusType.matured", "Matured"}
  ]

  @doc """
  An account's status as Fineract shows it: the option and one flag for each state (a rejected or withdrawn
  application counts as closed too).
  """
  @spec account_status(integer) :: map | nil
  def account_status(id) do
    with %{} = option <- one(@statuses, id) do
      Map.merge(option, %{
        submittedAndPendingApproval: id == 100,
        approved: id == 200,
        rejected: id == 500,
        withdrawnByApplicant: id == 400,
        active: id == 300,
        closed: id in [400, 500, 600],
        prematureClosed: id == 700,
        transferInProgress: false,
        transferOnHold: false,
        matured: id == 800
      })
    end
  end

  @doc "The sub status of an account that is neither dormant nor blocked."
  @spec sub_status_none() :: map
  def sub_status_none, do: sub_status(0)

  @sub_statuses %{
    0 => {"none", "None"},
    100 => {"inactive", "Inactive"},
    200 => {"dormant", "Dormant"},
    300 => {"escheat", "Escheat"},
    400 => {"block", "Block"},
    500 => {"blockCredit", "BlockCredit"},
    600 => {"blockDebit", "BlockDebit"}
  }

  @doc "The sub status `id` (none, inactive, dormant, escheat, block, block credit or block debit) as Fineract shows it."
  @spec sub_status(integer | nil) :: map
  def sub_status(id) do
    id = id || 0
    {name, value} = Map.fetch!(@sub_statuses, id)

    base = %{
      id: id,
      code: "SavingsAccountSubStatusEnum." <> name,
      value: value,
      none: id == 0,
      inactive: id == 100,
      dormant: id == 200,
      escheat: id == 300,
      block: id == 400,
      blockCredit: id == 500,
      blockDebit: id == 600
    }

    base
  end

  @doc "The deposit type of an ordinary savings account."
  @spec deposit_type() :: map
  def deposit_type, do: %{id: 100, code: "depositAccountType.savingsDeposit", value: "Savings"}
end
