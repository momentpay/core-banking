defmodule ECBDeposits.SavingsProducts.Validate do
  @moduledoc """
  What a request to create or change a savings product must carry, following Fineract's
  `SavingsProductDataValidator` and `SavingsProductAccountingDataValidator`. Every check runs and the
  problems come back together, in the order Fineract finds them.
  """
  alias ECBDeposits.SavingsEnums
  alias ECBPlatform.{Json, Params, Validation}

  @resource "savingsproduct"

  @supported ~w(locale monthDayFormat name shortName description currencyCode digitsAfterDecimal
                inMultiplesOf nominalAnnualInterestRate interestCompoundingPeriodType
                interestPostingPeriodType interestCalculationType interestCalculationDaysInYearType
                minRequiredOpeningBalance lockinPeriodFrequency lockinPeriodFrequencyType
                withdrawalFeeAmount withdrawalFeeType withdrawalFeeForTransfers feeAmount feeOnMonthDay
                accountingRule charges incomeFromFeeAccountId incomeFromPenaltyAccountId
                interestOnSavingsAccountId penaltiesReceivableAccountId paymentChannelToFundSourceMappings
                savingsControlAccountId transfersInSuspenseAccountId savingsReferenceAccountId
                feeToIncomeAccountMappings penaltyToIncomeAccountMappings feesReceivableAccountId
                interestPayableAccountId overdraftPortfolioControlId writeOffAccountId
                incomeFromInterestId escheatLiabilityId interestReceivableAccountId
                isDormancyTrackingActive daysToDormancy daysToInactive daysToEscheat allowOverdraft
                overdraftLimit nominalAnnualInterestRateOverdraft minOverdraftForInterestCalculation
                minRequiredBalance enforceMinRequiredBalance maxAllowedLienLimit lienAllowed
                minBalanceForInterestCalculation withHoldTax taxGroupId)

  @doc "The parameters a request may carry."
  def supported, do: @supported

  # accounts every cash or accrual product names, in the order they are checked
  @base_accounts ~w(savingsControlAccountId savingsReferenceAccountId transfersInSuspenseAccountId
                    interestOnSavingsAccountId incomeFromFeeAccountId incomeFromPenaltyAccountId)
  @plain_accounts ~w(overdraftPortfolioControlId incomeFromInterestId writeOffAccountId)
  @accrual_accounts ~w(feesReceivableAccountId penaltiesReceivableAccountId interestPayableAccountId)

  # --- create ---------------------------------------------------------------------------------

  @doc "Checks a create request."
  @spec create!(Params.t()) :: :ok
  def create!(%Params{} = p) do
    Params.check_supported!(p, @supported)

    Validation.new(@resource)
    |> Validation.param("name", Params.string(p, "name"))
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("shortName", Params.string(p, "shortName"))
    |> Validation.not_blank()
    |> Validation.max_length(4)
    |> Validation.param("currencyCode", Params.string(p, "currencyCode"))
    |> Validation.not_blank()
    |> Validation.param("digitsAfterDecimal", Params.integer(p, "digitsAfterDecimal"))
    |> Validation.not_null()
    |> Validation.in_range(0, 6)
    |> in_multiples_of(p)
    |> Validation.param(
      "nominalAnnualInterestRate",
      Params.decimal_with_locale(p, "nominalAnnualInterestRate")
    )
    |> Validation.not_null()
    |> Validation.zero_or_positive_amount()
    |> enum_param(p, "interestCompoundingPeriodType", SavingsEnums.compounding_ids())
    |> enum_param(p, "interestPostingPeriodType", SavingsEnums.posting_ids())
    |> enum_param(p, "interestCalculationType", SavingsEnums.calculation_ids())
    |> enum_param(p, "interestCalculationDaysInYearType", SavingsEnums.days_in_year_ids())
    |> description(p, :create)
    |> opening_balance(p, :create)
    |> lockin(p, :create)
    |> annual_fee(p)
    |> then(fn v -> dormancy(v, p, nil) end)
    |> accounting(p, :create, nil)
    |> overdraft(p)
    |> min_balance_for_interest(p)
    |> tax_withholding(p, :create)
    |> lien(p)
    |> Validation.raise_if_errors!()
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Checks an update request against the product as it stands (`product` carries `accounting_id` and the dormancy fields)."
  @spec update!(Params.t(), map) :: :ok
  def update!(%Params{} = p, product) do
    Params.check_supported!(p, @supported)

    Validation.new(@resource)
    |> present(
      p,
      "name",
      fn v -> v |> Validation.not_blank() |> Validation.max_length(100) end,
      :string
    )
    |> present(
      p,
      "shortName",
      fn v -> v |> Validation.not_blank() |> Validation.max_length(4) end,
      :string
    )
    |> description(p, :update)
    |> present(p, "currencyCode", &Validation.not_blank/1, :string)
    |> present(
      p,
      "digitsAfterDecimal",
      fn v -> v |> Validation.not_null() |> Validation.in_range(0, 6) end,
      :integer
    )
    |> in_multiples_of(p)
    |> present(
      p,
      "nominalAnnualInterestRate",
      fn v -> v |> Validation.not_null() |> Validation.zero_or_positive_amount() end,
      :decimal
    )
    |> update_enum(p, "interestCompoundingPeriodType", fn v ->
      v |> Validation.not_null() |> Validation.one_of(SavingsEnums.compounding_ids())
    end)
    |> update_enum(p, "interestCalculationType", fn v ->
      v |> Validation.not_null() |> Validation.in_range(1, 2)
    end)
    |> update_enum(p, "interestCalculationDaysInYearType", fn v ->
      v |> Validation.not_null() |> Validation.one_of([360, 365])
    end)
    |> opening_balance(p, :update)
    |> lockin(p, :update)
    |> annual_fee(p)
    |> accounting_rule_on_update(p, product)
    |> then(fn v -> accounting_and_dormancy_on_update(v, p, product) end)
    |> overdraft(p)
    |> min_balance_for_interest(p)
    |> tax_withholding(p, :update)
    |> lien(p)
    |> Validation.raise_if_errors!()
  end

  # --- pieces ---------------------------------------------------------------------------------

  defp read(p, key, :string), do: Params.string(p, key)
  defp read(p, key, :integer), do: Params.integer(p, key)
  defp read(p, key, :decimal), do: Params.decimal_with_locale(p, key)

  defp present(v, p, key, checks, kind) do
    if Params.exists?(p, key),
      do: v |> Validation.param(key, read(p, key, kind)) |> checks.(),
      else: v
  end

  defp update_enum(v, p, key, checks) do
    if Params.exists?(p, key),
      do: v |> Validation.param(key, Params.integer(p, key)) |> checks.(),
      else: v
  end

  defp enum_param(v, p, key, ids) do
    v
    |> Validation.param(key, Params.integer(p, key))
    |> Validation.not_null()
    |> Validation.one_of(ids)
  end

  defp in_multiples_of(v, p) do
    if Params.exists?(p, "inMultiplesOf") do
      v
      |> Validation.param("inMultiplesOf", Params.integer_in_default_locale(p, "inMultiplesOf"))
      |> Validation.ignore_if_null()
      |> Validation.zero_or_greater()
    else
      v
    end
  end

  defp description(v, p, mode) do
    if Params.exists?(p, "description") do
      v = Validation.param(v, "description", Params.string(p, "description"))

      case mode do
        :create -> v |> Validation.ignore_if_null() |> Validation.max_length(500)
        :update -> v |> Validation.not_blank() |> Validation.max_length(500)
      end
    else
      v
    end
  end

  defp opening_balance(v, p, mode) do
    if Params.exists?(p, "minRequiredOpeningBalance") do
      v =
        Validation.param(
          v,
          "minRequiredOpeningBalance",
          Params.decimal_with_locale(p, "minRequiredOpeningBalance")
        )

      v = if mode == :update, do: Validation.ignore_if_null(v), else: v
      Validation.zero_or_positive_amount(v)
    else
      v
    end
  end

  # the lock-in period and its unit go together on create; on update each is checked on its own
  defp lockin(v, p, :create) do
    v =
      if Params.exists?(p, "lockinPeriodFrequency") do
        frequency = Params.integer_with_locale(p, "lockinPeriodFrequency")

        v =
          v
          |> Validation.param("lockinPeriodFrequency", frequency)
          |> Validation.zero_or_greater()

        if frequency do
          v
          |> Validation.param(
            "lockinPeriodFrequencyType",
            Params.integer(p, "lockinPeriodFrequencyType")
          )
          |> Validation.not_null()
          |> Validation.in_range(0, 3)
        else
          v
        end
      else
        v
      end

    if Params.exists?(p, "lockinPeriodFrequencyType") do
      type = Params.integer(p, "lockinPeriodFrequencyType")
      v = v |> Validation.param("lockinPeriodFrequencyType", type) |> Validation.in_range(0, 3)

      if type do
        v
        |> Validation.param(
          "lockinPeriodFrequency",
          Params.integer_with_locale(p, "lockinPeriodFrequency")
        )
        |> Validation.not_null()
        |> Validation.zero_or_greater()
      else
        v
      end
    else
      v
    end
  end

  defp lockin(v, p, :update) do
    v =
      if Params.exists?(p, "lockinPeriodFrequency") do
        v
        |> Validation.param(
          "lockinPeriodFrequency",
          Params.integer_with_locale(p, "lockinPeriodFrequency")
        )
        |> Validation.ignore_if_null()
        |> Validation.zero_or_greater()
      else
        v
      end

    if Params.exists?(p, "lockinPeriodFrequencyType") do
      v
      |> Validation.param(
        "lockinPeriodFrequencyType",
        Params.integer(p, "lockinPeriodFrequencyType")
      )
      |> Validation.in_range(0, 3)
    else
      v
    end
  end

  # The yearly fee and the day it falls on go together. Neither is stored by a product, but both are read.
  defp annual_fee(v, p) do
    v =
      if Params.exists?(p, "feeAmount") do
        fee = Params.decimal_with_locale(p, "feeAmount")
        v = v |> Validation.param("feeAmount", fee) |> Validation.zero_or_positive_amount()

        if fee do
          v
          |> Validation.param("feeOnMonthDay", month_day(p))
          |> Validation.not_null()
        else
          v
        end
      else
        v
      end

    if Params.exists?(p, "feeOnMonthDay") and month_day(p) != nil do
      v
      |> Validation.param("feeAmount", Params.decimal_with_locale(p, "feeAmount"))
      |> Validation.not_null()
      |> Validation.zero_or_positive_amount()
    else
      v
    end
  end

  # a day and month need the format they are written in; without it Fineract fails outright
  defp month_day(p) do
    case Params.string(p, "feeOnMonthDay") do
      nil ->
        nil

      text ->
        format = Params.string(p, "monthDayFormat") || raise ECBPlatform.Errors.ServerError

        case ECBPlatform.Params.DatePattern.parse(text <> " 2000", format <> " yyyy") do
          {:ok, date} -> {date.month, date.day}
          :error -> raise ECBPlatform.Errors.ServerError
        end
    end
  end

  # --- dormancy ---------------------------------------------------------------------------------

  defp dormancy(v, p, product) do
    active? = dormancy_active?(p, product)
    if active?, do: dormancy_days(v, p, product), else: v
  end

  defp dormancy_active?(p, product) do
    if product != nil and Params.exists?(p, "isDormancyTrackingActive"),
      do: Params.boolean(p, "isDormancyTrackingActive") == true,
      else: dormancy_of(p, product)
  end

  defp dormancy_of(p, nil), do: Params.boolean(p, "isDormancyTrackingActive") == true
  defp dormancy_of(_p, product), do: product.dormancy_tracking_active == true

  defp dormancy_days(v, p, product) do
    inactive = days(p, product, "daysToInactive", :days_to_inactive)
    dormancy = days(p, product, "daysToDormancy", :days_to_dormancy)
    escheat = days(p, product, "daysToEscheat", :days_to_escheat)

    v =
      v
      |> Validation.param("daysToInactive", inactive)
      |> Validation.not_null()
      |> Validation.greater_than_zero()
      |> Validation.param("daysToDormancy", dormancy)
      |> Validation.not_null()
      |> Validation.greater_than_zero()
      |> Validation.param("daysToEscheat", escheat)
      |> Validation.not_null()
      |> Validation.greater_than_zero()

    if inactive && dormancy && escheat do
      v
      |> Validation.param("daysToDormancy", dormancy)
      |> Validation.greater_than_number(inactive)
      |> Validation.param("daysToEscheat", escheat)
      |> Validation.greater_than_number(dormancy)
    else
      v
    end
  end

  defp days(p, nil, key, _field), do: Json.long(p, key)

  defp days(p, product, key, field),
    do: if(Params.exists?(p, key), do: Json.long(p, key), else: Map.get(product, field))

  # --- accounting -------------------------------------------------------------------------------

  defp accounting(v, p, mode, product) do
    rule = Params.integer_in_default_locale(p, "accountingRule")

    v =
      v
      |> Validation.param("accountingRule", rule)
      |> Validation.not_null()
      |> Validation.in_range(1, 3)

    accounting_accounts(v, p, rule, dormancy_active?(p, product), mode == :create)
  end

  defp accounting_rule_on_update(v, p, product) do
    if Params.exists?(p, "accountingRule") do
      rule = Params.integer_in_default_locale(p, "accountingRule")

      v
      |> Validation.param("accountingRule", rule)
      |> Validation.not_null()
      |> Validation.in_range(1, 3)
    else
      _ = product
      v
    end
  end

  defp accounting_and_dormancy_on_update(v, p, product) do
    rule =
      if Params.exists?(p, "accountingRule"),
        do: Params.integer_in_default_locale(p, "accountingRule"),
        else: product.accounting_id

    active? = dormancy_active?(p, product)
    v = accounting_accounts(v, p, rule, active?, false)

    if active? do
      v = dormancy_days(v, p, product)

      if Params.exists?(p, "escheatLiabilityId") do
        v
        |> Validation.param("escheatLiabilityId", Json.long(p, "escheatLiabilityId"))
        |> Validation.not_null()
        |> Validation.greater_than_zero()
      else
        v
      end
    else
      v
    end
  end

  defp accounting_accounts(v, p, rule, dormancy?, required?) when rule in [2, 3] do
    v
    |> accounts(p, @base_accounts, required?)
    |> accounts(p, @plain_accounts, required?)
    |> accounts(p, if(dormancy?, do: ["escheatLiabilityId"], else: []), required?)
    |> accounts(p, if(rule == 3, do: @accrual_accounts, else: []), required?)
    |> payment_channels(p)
    |> charge_mappings(p)
  end

  defp accounting_accounts(v, _p, _rule, _dormancy?, _required?), do: v

  # each account must be a positive id; on create every one must be named, on update only those that are
  defp accounts(v, p, keys, required?) do
    Enum.reduce(keys, v, fn key, v ->
      if required? or Params.exists?(p, key) do
        v
        |> Validation.param(key, Json.long(p, key))
        |> Validation.not_null()
        |> Validation.greater_than_zero()
      else
        v
      end
    end)
  end

  defp payment_channels(v, p) do
    case Params.value(p, "paymentChannelToFundSourceMappings") do
      [_ | _] = mappings ->
        mappings
        |> Enum.with_index()
        |> Enum.reduce(v, fn {m, i}, v -> payment_channel(v, m, i) end)

      _ ->
        v
    end
  end

  defp payment_channel(v, m, i) do
    type = required_long!(m, "paymentTypeId")
    account = required_long!(m, "fundSourceAccountId")
    prefix = "paymentChannelToFundSourceMappings[#{i}]."

    v
    |> Validation.param(prefix <> "PAYMENT TYPE", type)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param(prefix <> "fundSourceAccountId", account)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
  end

  # Fineract checks the penalty mappings twice and the fee mappings never
  defp charge_mappings(v, p) do
    v
    |> charge_mapping(p, "penaltyToIncomeAccountMappings")
    |> charge_mapping(p, "penaltyToIncomeAccountMappings")
  end

  defp charge_mapping(v, p, name) do
    case Params.value(p, name) do
      [_ | _] = mappings ->
        mappings
        |> Enum.with_index()
        |> Enum.reduce(v, fn {m, i}, v ->
          prefix = "#{name}[#{i}]."

          v
          |> Validation.param(
            prefix <> "chargeId",
            Json.long(%Params{map: as_map(m)}, "chargeId")
          )
          |> Validation.not_null()
          |> Validation.greater_than_zero()
          |> Validation.param(
            prefix <> "incomeAccountId",
            Json.long(%Params{map: as_map(m)}, "incomeAccountId")
          )
          |> Validation.not_null()
          |> Validation.greater_than_zero()
        end)

      _ ->
        v
    end
  end

  defp as_map(%{} = m), do: m
  defp as_map(_other), do: raise(ECBPlatform.Errors.ServerError)

  # a key that has to be there: reading a missing one fails outright in Fineract (a plain HTTP 500)
  defp required_long!(m, key) do
    case as_map(m) do
      %{^key => value} when not is_nil(value) -> Json.long(%Params{map: %{key => value}}, key)
      _ -> raise ECBPlatform.Errors.ServerError
    end
  end

  # --- overdraft, balances, tax and lien ----------------------------------------------------------

  defp overdraft(v, p) do
    v = optional_boolean(v, p, "allowOverdraft")

    Enum.reduce(
      ~w(overdraftLimit nominalAnnualInterestRateOverdraft minOverdraftForInterestCalculation),
      v,
      fn key, v ->
        if Params.exists?(p, key) do
          v
          |> Validation.param(key, Params.decimal_with_locale(p, key))
          |> Validation.ignore_if_null()
          |> Validation.zero_or_positive_amount()
        else
          v
        end
      end
    )
  end

  defp optional_boolean(v, p, key) do
    if Params.exists?(p, key),
      do: v |> Validation.param(key, Params.boolean(p, key)) |> Validation.ignore_if_null(),
      else: v
  end

  defp min_balance_for_interest(v, p) do
    if Params.exists?(p, "minBalanceForInterestCalculation") do
      v
      |> Validation.param(
        "minBalanceForInterestCalculation",
        Params.decimal_with_locale(p, "minBalanceForInterestCalculation")
      )
      |> Validation.ignore_if_null()
      |> Validation.zero_or_positive_amount()
    else
      v
    end
  end

  defp tax_withholding(v, p, mode) do
    v =
      if Params.exists?(p, "withHoldTax"),
        do:
          v
          |> Validation.param("withHoldTax", Params.string(p, "withHoldTax"))
          |> Validation.ignore_if_null()
          |> Validation.boolean_text(),
        else: v

    withhold? = Params.boolean(p, "withHoldTax") == true

    cond do
      Params.exists?(p, "taxGroupId") ->
        v =
          v
          |> Validation.param("taxGroupId", Json.long(p, "taxGroupId"))
          |> Validation.ignore_if_null()
          |> Validation.greater_than_zero()

        if withhold?,
          do:
            v
            |> Validation.param("taxGroupId", Json.long(p, "taxGroupId"))
            |> Validation.not_blank(),
          else: v

      withhold? and mode == :create ->
        v |> Validation.param("taxGroupId", nil) |> Validation.not_blank()

      true ->
        v
    end
  end

  defp lien(v, p) do
    v = optional_boolean(v, p, "lienAllowed")

    v =
      if Params.exists?(p, "maxAllowedLienLimit") do
        v
        |> Validation.param(
          "maxAllowedLienLimit",
          Params.decimal_with_locale(p, "maxAllowedLienLimit")
        )
        |> Validation.ignore_if_null()
        |> Validation.zero_or_positive_amount()
      else
        v
      end

    if Params.boolean(p, "lienAllowed") == true and Params.boolean(p, "allowOverdraft") == true do
      limit = Params.decimal_with_locale(p, "maxAllowedLienLimit")
      overdraft = Params.decimal_with_locale(p, "overdraftLimit")

      if is_nil(limit) or is_nil(overdraft), do: raise(ECBPlatform.Errors.ServerError)

      if Decimal.compare(overdraft, limit) == :gt,
        do:
          v
          |> Validation.param(nil, nil)
          |> Validation.fail_without_parameter(
            "Overdraft.limit.can.not.be.greater.than.lien.limit"
          ),
        else: v
    else
      v
    end
  end
end
