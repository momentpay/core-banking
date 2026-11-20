defmodule ECBDeposits.DepositProducts.Validate do
  @moduledoc """
  What a request to create or change a fixed or recurring deposit product must carry, after Fineract's
  `DepositProductDataValidator`. Every check runs and the problems come back together, in the order Fineract finds
  them; a request with a parameter that the product does not know is refused at once. The interest rate charts are
  checked by `ECBDeposits.InterestCharts`.
  """
  alias ECBDeposits.{DepositEnums, InterestCharts, SavingsEnums}
  alias ECBDeposits.SavingsProducts.Validate, as: Savings
  alias ECBPlatform.{Params, Validation}

  @common ~w(locale monthDayFormat name shortName description currencyCode digitsAfterDecimal inMultiplesOf
             nominalAnnualInterestRate interestCompoundingPeriodType interestPostingPeriodType
             interestCalculationType interestCalculationDaysInYearType lockinPeriodFrequency
             lockinPeriodFrequencyType accountingRule charges incomeFromFeeAccountId
             incomeFromPenaltyAccountId interestOnSavingsAccountId paymentChannelToFundSourceMappings
             savingsControlAccountId transfersInSuspenseAccountId savingsReferenceAccountId
             feeToIncomeAccountMappings penaltyToIncomeAccountMappings interestPayableAccountId
             penaltiesReceivableAccountId feesReceivableAccountId charts withHoldTax taxGroupId
             preClosurePenalApplicable preClosurePenalInterest preClosurePenalInterestOnTypeId
             minDepositTerm maxDepositTerm minDepositTermTypeId maxDepositTermTypeId
             inMultiplesOfDepositTerm inMultiplesOfDepositTermTypeId depositAmount minDepositAmount
             maxDepositAmount)

  @recurring ~w(mandatoryRecommendedDepositAmount isMandatoryDeposit allowWithdrawal
                adjustAdvanceTowardsFuturePayments recurringFrequencyType recurringFrequency
                isCalendarInherited)

  @accounting_params ~w(incomeFromFeeAccountId incomeFromPenaltyAccountId interestOnSavingsAccountId
                        paymentChannelToFundSourceMappings savingsControlAccountId
                        transfersInSuspenseAccountId savingsReferenceAccountId feeToIncomeAccountMappings
                        penaltyToIncomeAccountMappings interestPayableAccountId
                        penaltiesReceivableAccountId feesReceivableAccountId)

  @doc "The parameters a request for the kind of product may carry."
  @spec supported(:fixed | :recurring) :: [String.t()]
  def supported(:fixed), do: @common
  def supported(:recurring), do: @common ++ @recurring

  @doc "The name of the resource the problems are reported against."
  @spec resource(:fixed | :recurring) :: String.t()
  def resource(:fixed), do: "fixeddepositproduct"
  def resource(:recurring), do: "recurringdepositproduct"

  @doc "The parameters that map a product to the books."
  @spec accounting_params() :: [String.t()]
  def accounting_params, do: @accounting_params

  # --- create ---------------------------------------------------------------------------------

  @doc "Checks a create request."
  @spec create!(:fixed | :recurring, Params.t()) :: :ok
  def create!(kind, %Params{} = p) do
    Params.check_supported!(p, supported(kind))

    kind
    |> resource()
    |> Validation.new()
    |> detail_create(p)
    |> pre_closure_create(p)
    |> term_create(p)
    |> recurring(p, kind)
    |> Validation.param(nil, nil)
    |> InterestCharts.validate_request(p)
    |> amount_create(p)
    |> Validation.raise_if_errors!()
  end

  defp detail_create(v, p) do
    v
    |> Validation.param("name", Params.string(p, "name"))
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("shortName", Params.string(p, "shortName"))
    |> Validation.not_blank()
    |> Validation.max_length(4)
    |> Validation.param("description", Params.string(p, "description"))
    |> Validation.not_blank()
    |> Validation.max_length(500)
    |> Validation.param("currencyCode", Params.string(p, "currencyCode"))
    |> Validation.not_blank()
    |> Validation.param("digitsAfterDecimal", Params.integer(p, "digitsAfterDecimal"))
    |> Validation.not_null()
    |> Validation.in_range(0, 6)
    |> Savings.in_multiples_of(p)
    |> nominal_rate_create(p)
    |> Savings.enum_param(p, "interestCompoundingPeriodType", SavingsEnums.compounding_ids())
    |> Savings.enum_param(p, "interestPostingPeriodType", SavingsEnums.posting_ids())
    |> Savings.enum_param(p, "interestCalculationType", SavingsEnums.calculation_ids())
    |> Savings.enum_param(p, "interestCalculationDaysInYearType", SavingsEnums.days_in_year_ids())
    |> Savings.lockin(p, :create)
    |> accounting_rule(p)
    |> accounting_data(p)
    |> Savings.tax_withholding(p, :create)
  end

  defp nominal_rate_create(v, p) do
    if Params.exists?(p, "nominalAnnualInterestRate") do
      v
      |> Validation.param(
        "nominalAnnualInterestRate",
        Params.decimal_with_locale(p, "nominalAnnualInterestRate")
      )
      |> Validation.not_null()
      |> Validation.zero_or_positive_amount()
    else
      v
    end
  end

  defp accounting_rule(v, p) do
    v
    |> Validation.param("accountingRule", Params.integer_in_default_locale(p, "accountingRule"))
    |> Validation.not_null()
    |> Validation.in_range(1, 3)
  end

  # the accounts a product that keeps accounts in the ledger must name, and its mappings
  @base_accounts ~w(savingsControlAccountId savingsReferenceAccountId transfersInSuspenseAccountId
                    interestOnSavingsAccountId incomeFromFeeAccountId incomeFromPenaltyAccountId)
  @accrual_accounts ~w(feesReceivableAccountId penaltiesReceivableAccountId interestPayableAccountId)

  defp accounting_data(v, p) do
    rule = Params.integer_in_default_locale(p, "accountingRule")

    if rule in [2, 3] do
      v
      |> Savings.accounts(p, @base_accounts, true)
      |> Savings.accounts(p, if(rule == 3, do: @accrual_accounts, else: []), true)
      |> Savings.payment_channels(p)
      |> Savings.charge_mappings(p)
    else
      v
    end
  end

  defp pre_closure_create(v, p) do
    if Params.exists?(p, "preClosurePenalApplicable") do
      applicable = Params.boolean(p, "preClosurePenalApplicable")
      if applicable == nil, do: raise(ECBPlatform.Errors.ServerError)

      if applicable do
        v
        |> Validation.param(
          "preClosurePenalInterest",
          Params.decimal_with_locale(p, "preClosurePenalInterest")
        )
        |> Validation.must_be_provided_when("preClosurePenalApplicable", true)
        |> Validation.zero_or_positive_amount()
        |> Validation.param(
          "preClosurePenalInterestOnTypeId",
          Params.integer(p, "preClosurePenalInterestOnTypeId")
        )
        |> Validation.must_be_provided_when("preClosurePenalApplicable", true)
        |> Validation.one_of(DepositEnums.pre_closure_on_ids())
      else
        v
      end
    else
      v
    end
  end

  defp term_create(v, p) do
    v =
      v
      |> Validation.param("minDepositTerm", Params.integer(p, "minDepositTerm"))
      |> Validation.not_null()
      |> Validation.greater_than_zero()
      |> optional(p, "maxDepositTerm", &Validation.greater_than_zero/1)
      |> Validation.param("minDepositTermTypeId", Params.integer(p, "minDepositTermTypeId"))
      |> Validation.ignore_if_null()
      |> Validation.one_of(DepositEnums.term_unit_ids())

    v =
      if Params.exists?(p, "maxDepositTermTypeId"),
        do:
          v
          |> Validation.param("maxDepositTermTypeId", Params.integer(p, "maxDepositTermTypeId"))
          |> Validation.one_of(DepositEnums.term_unit_ids()),
        else: v

    if Params.exists?(p, "inMultiplesOfDepositTerm") do
      step = Params.integer(p, "inMultiplesOfDepositTerm")

      v
      |> Validation.param("inMultiplesOfDepositTerm", step)
      |> Validation.greater_than_zero()
      |> Validation.param(
        "inMultiplesOfDepositTermTypeId",
        Params.integer(p, "inMultiplesOfDepositTermTypeId")
      )
      |> Validation.must_be_provided_when("inMultiplesOfDepositTerm", step)
      |> Validation.one_of(DepositEnums.term_unit_ids())
    else
      v
    end
  end

  defp optional(v, p, key, checks) do
    if Params.exists?(p, key),
      do: v |> Validation.param(key, Params.integer(p, key)) |> checks.(),
      else: v
  end

  defp recurring(v, p, :recurring) do
    Enum.reduce(
      ~w(isMandatoryDeposit allowWithdrawal adjustAdvanceTowardsFuturePayments),
      v,
      fn key, acc ->
        if Params.exists?(p, key) do
          acc
          |> Validation.param(key, Params.boolean(p, key))
          |> Validation.ignore_if_null()
          |> Validation.true_or_false()
        else
          acc
        end
      end
    )
  end

  defp recurring(v, _p, :fixed), do: v

  defp amount_create(v, p) do
    amount = Params.decimal_with_locale(p, "depositAmount")

    v =
      v
      |> Validation.param("depositAmount", amount)
      |> Validation.not_null()
      |> Validation.positive_amount()

    {v, min} = amount_limit(v, p, "minDepositAmount")
    {v, max} = amount_limit(v, p, "maxDepositAmount")
    amount_range(v, amount, min, max)
  end

  defp amount_limit(v, p, key) do
    if Params.exists?(p, key) do
      value = Params.decimal_with_locale(p, key)

      {v |> Validation.param(key, value) |> Validation.not_null() |> Validation.positive_amount(),
       value}
    else
      {v, nil}
    end
  end

  defp amount_range(v, amount, min, max) do
    cond do
      non_negative?(max) and non_negative?(min) ->
        v = v |> Validation.param("maxDepositAmount", max) |> Validation.not_less_than_min(min)

        if Decimal.compare(min, max) != :gt,
          do:
            v
            |> Validation.param("depositAmount", amount)
            |> Validation.in_min_and_max_amount_range(min, max),
          else: v

      non_negative?(max) ->
        v |> Validation.param("depositAmount", amount) |> Validation.not_greater_than_max(max)

      non_negative?(min) ->
        v |> Validation.param("depositAmount", amount) |> Validation.not_less_than_min(min)

      true ->
        v
    end
  end

  defp non_negative?(nil), do: false
  defp non_negative?(value), do: Decimal.compare(value, 0) != :lt

  # --- update ---------------------------------------------------------------------------------

  @doc "Checks an update request."
  @spec update!(:fixed | :recurring, Params.t()) :: :ok
  def update!(kind, %Params{} = p) do
    Params.check_supported!(p, supported(kind))

    kind
    |> resource()
    |> Validation.new()
    |> detail_update(p)
    |> pre_closure_update(p)
    |> term_update(p)
    |> recurring_update(p, kind)
    |> Validation.param(nil, nil)
    |> InterestCharts.validate_request(p)
    |> amount_update(p)
    |> Validation.raise_if_errors!()
  end

  defp detail_update(v, p) do
    v
    |> Savings.present(
      p,
      "name",
      fn v -> v |> Validation.not_blank() |> Validation.max_length(100) end,
      :string
    )
    |> Savings.present(
      p,
      "shortName",
      fn v -> v |> Validation.not_blank() |> Validation.max_length(4) end,
      :string
    )
    |> Savings.present(
      p,
      "description",
      fn v -> v |> Validation.not_blank() |> Validation.max_length(500) end,
      :string
    )
    |> Savings.present(p, "currencyCode", &Validation.not_blank/1, :string)
    |> Savings.present(
      p,
      "digitsAfterDecimal",
      fn v -> v |> Validation.not_null() |> Validation.in_range(0, 6) end,
      :integer
    )
    |> Savings.in_multiples_of(p)
    |> Savings.present(
      p,
      "nominalAnnualInterestRate",
      fn v -> v |> Validation.not_null() |> Validation.zero_or_positive_amount() end,
      :decimal
    )
    |> Savings.update_enum(p, "interestCompoundingPeriodType", fn v ->
      v |> Validation.not_null() |> Validation.one_of(SavingsEnums.compounding_ids())
    end)
    |> Savings.update_enum(p, "interestCalculationType", fn v ->
      v |> Validation.not_null() |> Validation.in_range(1, 2)
    end)
    |> Savings.update_enum(p, "interestCalculationDaysInYearType", fn v ->
      v |> Validation.not_null() |> Validation.one_of([360, 365])
    end)
    |> Savings.lockin(p, :update)
    |> Savings.tax_withholding(p, :update)
  end

  defp pre_closure_update(v, p) do
    v =
      if Params.exists?(p, "preClosurePenalApplicable"),
        do:
          v
          |> Validation.param(
            "preClosurePenalApplicable",
            Params.boolean(p, "preClosurePenalApplicable")
          )
          |> Validation.not_null(),
        else: v

    v =
      if Params.exists?(p, "preClosurePenalInterest"),
        do:
          v
          |> Validation.param(
            "preClosurePenalInterest",
            Params.decimal_with_locale(p, "preClosurePenalInterest")
          )
          |> Validation.not_null()
          |> Validation.zero_or_positive_amount(),
        else: v

    if Params.exists?(p, "preClosurePenalInterestOnTypeId"),
      do:
        v
        |> Validation.param(
          "preClosurePenalInterestOnTypeId",
          Params.integer(p, "preClosurePenalInterestOnTypeId")
        )
        |> Validation.not_null()
        |> Validation.one_of(DepositEnums.pre_closure_on_ids()),
      else: v
  end

  defp term_update(v, p) do
    ids = DepositEnums.term_unit_ids()

    v
    |> optional(p, "minDepositTerm", &Validation.greater_than_zero/1)
    |> optional(p, "maxDepositTerm", &Validation.greater_than_zero/1)
    |> optional(p, "minDepositTermTypeId", &Validation.one_of(&1, ids))
    |> optional(p, "maxDepositTermTypeId", &Validation.one_of(&1, ids))
    |> optional(p, "inMultiplesOfDepositTerm", &Validation.greater_than_zero/1)
    |> optional(p, "inMultiplesOfDepositTermTypeId", &Validation.one_of(&1, ids))
  end

  defp recurring_update(v, p, :recurring), do: recurring(v, p, :recurring)
  defp recurring_update(v, _p, :fixed), do: v

  defp amount_update(v, p) do
    {v, amount} = amount_given(v, p, "depositAmount")
    {v, min} = amount_given(v, p, "minDepositAmount")
    {v, max} = amount_given(v, p, "maxDepositAmount")

    if amount != nil, do: amount_range(v, amount, min, max), else: v
  end

  defp amount_given(v, p, key) do
    if Params.exists?(p, key) do
      value = Params.decimal_with_locale(p, key)

      {v |> Validation.param(key, value) |> Validation.not_null() |> Validation.positive_amount(),
       value}
    else
      {v, nil}
    end
  end
end
