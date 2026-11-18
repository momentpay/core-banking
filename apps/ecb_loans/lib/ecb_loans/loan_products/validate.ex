defmodule ECBLoans.LoanProducts.Validate do
  @moduledoc """
  What a request to create a loan product must carry, following Fineract's `LoanProductDataValidator`. Every
  check runs and the problems come back together, in the order Fineract finds them.

  Only the core of a loan product is supported (see `ECBLoans.LoanProducts`). A request that asks for
  anything beyond it (a floating rate, interest recalculation, several disbursements, a borrower cycle,
  guarantees, advanced payment allocation and the like) is refused with a plain statement that it is not
  supported yet, and never quietly ignored.
  """
  alias ECBLoans.{LoanEnums, LoanProducts}
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.{Json, Params, Validation}

  @resource "loanproduct"

  # every parameter Fineract accepts on a loan product (the rest is refused as unsupported by Fineract itself)
  @supported ~w(locale dateFormat name description fundId currencyCode digitsAfterDecimal inMultiplesOf
                principal minPrincipal maxPrincipal repaymentEvery numberOfRepayments minNumberOfRepayments
                maxNumberOfRepayments repaymentFrequencyType interestRatePerPeriod minInterestRatePerPeriod
                maxInterestRatePerPeriod interestRateFrequencyType amortizationType interestType
                interestCalculationPeriodType allowPartialPeriodInterestCalculation inArrearsTolerance
                transactionProcessingStrategyCode paymentAllocation creditAllocation graceOnPrincipalPayment
                recurringMoratoriumOnPrincipalPeriods graceOnInterestPayment graceOnInterestCharged charges
                accountingRule includeInBorrowerCycle startDate closeDate externalId
                isLinkedToFloatingInterestRates floatingRatesId interestRateDifferential
                minDifferentialLendingRate defaultDifferentialLendingRate maxDifferentialLendingRate
                isFloatingInterestRateCalculationAllowed syncExpectedWithDisbursementDate
                receivableFeeAccountId fundSourceAccountId incomeFromFeeAccountId incomeFromPenaltyAccountId
                interestOnLoanAccountId receivableInterestAccountId loanPortfolioAccountId
                overpaymentLiabilityAccountId transfersInSuspenseAccountId writeOffAccountId
                goodwillCreditAccountId receivablePenaltyAccountId paymentChannelToFundSourceMappings
                feeToIncomeAccountMappings incomeFromRecoveryAccountId penaltyToIncomeAccountMappings
                chargeOffFraudExpenseAccountId chargeOffExpenseAccountId incomeFromChargeOffFeesAccountId
                incomeFromChargeOffInterestAccountId incomeFromChargeOffPenaltyAccountId
                incomeFromGoodwillCreditInterestAccountId incomeFromGoodwillCreditFeesAccountId
                incomeFromGoodwillCreditPenaltyAccountId chargeOffReasonToExpenseAccountMappings
                writeOffReasonsToExpenseMappings writeOffReasonCodeValueId expenseAccountId
                chargeOffReasonCodeValueId incomeFromCapitalizationAccountId deferredIncomeLiabilityAccountId
                buyDownExpenseAccountId incomeFromBuyDownAccountId useBorrowerCycle
                principalVariationsForBorrowerCycle interestRateVariationsForBorrowerCycle
                numberOfRepaymentVariationsForBorrowerCycle shortName multiDisburseLoan outstandingLoanBalance
                maxTrancheCount graceOnArrearsAgeing overdueDaysForNPA isInterestRecalculationEnabled
                daysInYearType daysInMonthType rescheduleStrategyMethod interestRecalculationCompoundingMethod
                recalculationRestFrequencyInterval recalculationRestFrequencyType
                recalculationCompoundingFrequencyInterval recalculationCompoundingFrequencyType
                isArrearsBasedOnOriginalSchedule minimumDaysBetweenDisbursalAndFirstRepayment
                mandatoryGuarantee holdGuaranteeFunds minimumGuaranteeFromGuarantor
                minimumGuaranteeFromOwnFunds principalThresholdForLastInstallment
                accountMovesOutOfNPAOnlyOnArrearsCompletion canDefineInstallmentAmount
                installmentAmountInMultiplesOf preClosureInterestCalculationStrategy allowAttributeOverrides
                allowVariableInstallments minimumGap maximumGap recalculationCompoundingFrequencyWeekday
                recalculationCompoundingFrequencyNthDay recalculationCompoundingFrequencyOnDay
                recalculationRestFrequencyWeekday recalculationRestFrequencyNthDay
                recalculationRestFrequencyOnDay isCompoundingToBePostedAsTransaction allowCompoundingOnEod
                disallowInterestCalculationOnPastDue canUseForTopup isEqualAmortization rates
                fixedPrincipalPercentagePerInstallment disallowExpectedDisbursements
                allowApprovedDisbursedAmountsOverApplied overAppliedCalculationType overAppliedNumber
                delinquencyBucketId dueDaysForRepaymentEvent overDueDaysForRepaymentEvent enableDownPayment
                disbursedAmountPercentageForDownPayment enableAutoRepaymentForDownPayment
                repaymentStartDateType enableInstallmentLevelDelinquency loanScheduleType
                loanScheduleProcessingType fixedLength enableAccrualActivityPosting
                supportedInterestRefundTypes chargeOffBehaviour interestRecognitionOnDisbursementDate
                daysInYearCustomStrategy enableIncomeCapitalization capitalizedIncomeCalculationType
                capitalizedIncomeStrategy capitalizedIncomeType enableBuyDownFee buyDownFeeCalculationType
                buyDownFeeStrategy buyDownFeeIncomeType merchantBuyDownFee
                capitalizedIncomeClassificationToIncomeAccountMappings
                buydownfeeClassificationToIncomeAccountMappings allowFullTermForTranche datatables)

  @doc "The parameters a request may carry."
  def supported, do: @supported

  # What a request may carry beyond the core, each with the one value that means "not asked for".
  @beyond_core %{
    "paymentAllocation" => [nil, []],
    "creditAllocation" => [nil, []],
    "isLinkedToFloatingInterestRates" => [nil, false],
    "floatingRatesId" => [nil],
    "interestRateDifferential" => [nil],
    "minDifferentialLendingRate" => [nil],
    "defaultDifferentialLendingRate" => [nil],
    "maxDifferentialLendingRate" => [nil],
    "isFloatingInterestRateCalculationAllowed" => [nil, false],
    "useBorrowerCycle" => [nil, false],
    "principalVariationsForBorrowerCycle" => [nil, []],
    "interestRateVariationsForBorrowerCycle" => [nil, []],
    "numberOfRepaymentVariationsForBorrowerCycle" => [nil, []],
    "isInterestRecalculationEnabled" => [nil, false],
    "rescheduleStrategyMethod" => [nil],
    "interestRecalculationCompoundingMethod" => [nil],
    "recalculationRestFrequencyInterval" => [nil],
    "recalculationRestFrequencyType" => [nil],
    "recalculationCompoundingFrequencyInterval" => [nil],
    "recalculationCompoundingFrequencyType" => [nil],
    "isArrearsBasedOnOriginalSchedule" => [nil, false],
    "mandatoryGuarantee" => [nil],
    "holdGuaranteeFunds" => [nil, false],
    "minimumGuaranteeFromGuarantor" => [nil],
    "minimumGuaranteeFromOwnFunds" => [nil],
    "preClosureInterestCalculationStrategy" => [nil],
    "allowAttributeOverrides" => [nil],
    "allowVariableInstallments" => [nil, false],
    "minimumGap" => [nil],
    "maximumGap" => [nil],
    "isEqualAmortization" => [nil, false],
    "rates" => [nil, []],
    "fixedPrincipalPercentagePerInstallment" => [nil],
    "allowApprovedDisbursedAmountsOverApplied" => [nil, false],
    "overAppliedCalculationType" => [nil],
    "overAppliedNumber" => [nil],
    "delinquencyBucketId" => [nil],
    "enableDownPayment" => [nil, false],
    "disbursedAmountPercentageForDownPayment" => [nil],
    "enableAutoRepaymentForDownPayment" => [nil, false],
    "enableInstallmentLevelDelinquency" => [nil, false],
    "loanScheduleType" => [nil, "CUMULATIVE"],
    "loanScheduleProcessingType" => [nil, "HORIZONTAL"],
    "fixedLength" => [nil],
    "supportedInterestRefundTypes" => [nil, []],
    "chargeOffBehaviour" => [nil, "REGULAR"],
    "interestRecognitionOnDisbursementDate" => [nil, false],
    "daysInYearCustomStrategy" => [nil],
    "enableIncomeCapitalization" => [nil, false],
    "capitalizedIncomeCalculationType" => [nil],
    "capitalizedIncomeStrategy" => [nil],
    "capitalizedIncomeType" => [nil],
    "enableBuyDownFee" => [nil, false],
    "buyDownFeeCalculationType" => [nil],
    "buyDownFeeStrategy" => [nil],
    "buyDownFeeIncomeType" => [nil],
    "merchantBuyDownFee" => [nil],
    "capitalizedIncomeClassificationToIncomeAccountMappings" => [nil, []],
    "buydownfeeClassificationToIncomeAccountMappings" => [nil, []],
    "chargeOffReasonToExpenseAccountMappings" => [nil, []],
    "writeOffReasonsToExpenseMappings" => [nil, []],
    "incomeFromCapitalizationAccountId" => [nil],
    "deferredIncomeLiabilityAccountId" => [nil],
    "buyDownExpenseAccountId" => [nil],
    "incomeFromBuyDownAccountId" => [nil],
    "allowFullTermForTranche" => [nil, false],
    "datatables" => [nil, []],
    "recurringMoratoriumOnPrincipalPeriods" => [nil, 0]
  }

  @doc "The parameters a request that is supported so far may leave to their defaults but not set."
  def beyond_core, do: Map.keys(@beyond_core)

  @doc """
  Refuses a request that asks for something past the core of a loan product, naming what it asked for.
  """
  @spec refuse_beyond_core!(Params.t()) :: :ok
  def refuse_beyond_core!(%Params{} = p) do
    asked =
      for {key, defaults} <- @beyond_core,
          Params.exists?(p, key),
          Params.value(p, key) not in defaults,
          do: key

    case Enum.sort(asked) do
      [] ->
        :ok

      names ->
        raise DomainRuleViolation,
          code: "error.msg.loanproduct.feature.not.supported.yet",
          message:
            "These loan product settings are not supported yet by E-CoreBank: " <>
              Enum.join(names, ", "),
          args: names
    end
  end

  # --- create ---------------------------------------------------------------------------------

  @doc "Checks a create request."
  @spec create!(Params.t()) :: :ok
  def create!(%Params{} = p) do
    Params.check_supported!(p, @supported)

    if multi?(p) and Params.boolean(p, "isEqualAmortization") == true,
      do: ECBLoans.Schedule.TrancheInput.equal_amortization!()

    refuse_beyond_core!(p)

    principal = Params.decimal_with_locale(p, "principal")

    {min_principal, max_principal} =
      {optional_decimal(p, "minPrincipal"), optional_decimal(p, "maxPrincipal")}

    repayments = Params.integer_with_locale(p, "numberOfRepayments")

    {min_repayments, max_repayments} =
      {optional_integer(p, "minNumberOfRepayments"), optional_integer(p, "maxNumberOfRepayments")}

    interest = Params.decimal_with_locale(p, "interestRatePerPeriod")

    {min_interest, max_interest} =
      {optional_decimal(p, "minInterestRatePerPeriod"),
       optional_decimal(p, "maxInterestRatePerPeriod")}

    Validation.new(@resource)
    |> Validation.param("name", Params.string(p, "name"))
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("shortName", Params.string(p, "shortName"))
    |> Validation.not_blank()
    |> Validation.max_length(4)
    |> Validation.param("description", Params.string(p, "description"))
    |> Validation.max_length(500)
    |> fund(p)
    |> min_days(p)
    |> flag(p, "includeInBorrowerCycle")
    |> Validation.param("currencyCode", Params.string(p, "currencyCode"))
    |> Validation.not_blank()
    |> Validation.max_length(3)
    |> Validation.param(
      "digitsAfterDecimal",
      Params.integer_in_default_locale(p, "digitsAfterDecimal")
    )
    |> Validation.not_null()
    |> Validation.in_range(0, 6)
    |> Validation.param("inMultiplesOf", Params.integer_in_default_locale(p, "inMultiplesOf"))
    |> Validation.ignore_if_null()
    |> Validation.zero_or_greater()
    |> Validation.param("principal", principal)
    |> Validation.positive_amount()
    |> optional_positive(p, "minPrincipal", min_principal)
    |> optional_positive(p, "maxPrincipal", max_principal)
    |> amount_range("principal", principal, "maxPrincipal", min_principal, max_principal)
    |> Validation.param("numberOfRepayments", repayments)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> optional_whole(p, "minNumberOfRepayments", min_repayments)
    |> optional_whole(p, "maxNumberOfRepayments", max_repayments)
    |> count_range(repayments, min_repayments, max_repayments)
    |> Validation.param("repaymentEvery", Params.integer_with_locale(p, "repaymentEvery"))
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> enum(p, "repaymentFrequencyType", 0, 3)
    |> enum(p, "amortizationType", 0, 1)
    |> enum(p, "interestType", 0, 1)
    |> enum(p, "interestCalculationPeriodType", 0, 1)
    |> Validation.param("inArrearsTolerance", Params.decimal_with_locale(p, "inArrearsTolerance"))
    |> Validation.ignore_if_null()
    |> Validation.zero_or_positive_amount()
    |> strategy(p)
    |> grace(p, "graceOnPrincipalPayment", :amount)
    |> grace(p, "graceOnInterestPayment", :amount)
    |> grace(p, "graceOnInterestCharged", :amount)
    |> grace(p, "graceOnArrearsAgeing", :integer)
    |> grace(p, "overdueDaysForNPA", :integer)
    |> Validation.param("daysInYearType", Params.integer_in_default_locale(p, "daysInYearType"))
    |> Validation.not_null()
    |> Validation.one_of([1, 360, 364, 365])
    |> Validation.param("daysInMonthType", Params.integer_in_default_locale(p, "daysInMonthType"))
    |> Validation.not_null()
    |> Validation.one_of([1, 30])
    |> npa_flag(p)
    |> recalculation_flag(p)
    |> interest_rate(p, interest, min_interest, max_interest)
    |> installment_amount(p)
    |> accounting(p)
    |> accrual_posting(p)
    |> topup(p)
    |> Validation.param(
      "dueDaysForRepaymentEvent",
      Params.integer_with_locale(p, "dueDaysForRepaymentEvent")
    )
    |> Validation.zero_or_greater()
    |> Validation.param(
      "overDueDaysForRepaymentEvent",
      Params.integer_with_locale(p, "overDueDaysForRepaymentEvent")
    )
    |> Validation.zero_or_greater()
    |> repayment_start(p)
    |> multi_disburse(p)
    |> partial_period(p)
    |> grace_against_term(p, repayments)
    |> Validation.raise_if_errors!()
  end

  # --- pieces ---------------------------------------------------------------------------------

  defp optional_decimal(p, key),
    do: if(Params.exists?(p, key), do: Params.decimal_with_locale(p, key))

  defp optional_integer(p, key),
    do: if(Params.exists?(p, key), do: Params.integer_with_locale(p, key))

  defp fund(v, p) do
    if Params.exists?(p, "fundId"),
      do:
        v
        |> Validation.param("fundId", Json.long(p, "fundId"))
        |> Validation.ignore_if_null()
        |> Validation.greater_than_zero(),
      else: v
  end

  defp min_days(v, p) do
    if Params.exists?(p, "minimumDaysBetweenDisbursalAndFirstRepayment"),
      do:
        v
        |> Validation.param(
          "minimumDaysBetweenDisbursalAndFirstRepayment",
          Json.long(p, "minimumDaysBetweenDisbursalAndFirstRepayment")
        )
        |> Validation.ignore_if_null()
        |> Validation.greater_than_zero(),
      else: v
  end

  # a flag that is only checked for being a flag, which any value is
  defp flag(v, _p, _key), do: v

  defp optional_positive(v, p, key, value) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, value)
        |> Validation.ignore_if_null()
        |> Validation.positive_amount(),
      else: v
  end

  defp optional_whole(v, p, key, value) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, value)
        |> Validation.ignore_if_null()
        |> Validation.greater_than_zero(),
      else: v
  end

  # the amount must sit within the minimum and maximum, whichever of them the request names
  defp amount_range(v, name, value, max_name, min, max) do
    max? = positive_or_zero?(max)
    min? = positive_or_zero?(min)

    cond do
      max? and min? ->
        both_limits(v, name, value, max_name, min, max)

      max? and value != nil ->
        v |> Validation.param(name, value) |> Validation.not_greater_than_max(max)

      min? and value != nil ->
        v |> Validation.param(name, value) |> not_less_than_min(min)

      true ->
        v
    end
  end

  defp both_limits(v, name, value, max_name, min, max) do
    v = v |> Validation.param(max_name, max) |> not_less_than_min(min)

    if Decimal.compare(min, max) != :gt and value != nil,
      do: v |> Validation.param(name, value) |> in_min_max_amount(min, max),
      else: v
  end

  defp positive_or_zero?(nil), do: false
  defp positive_or_zero?(%Decimal{} = d), do: Decimal.compare(d, 0) != :lt

  @doc false
  def amount_in_range(v, min, max), do: in_min_max_amount(v, min, max)

  @doc """
  The amount must be within limits read from the product (a stored number, which Fineract writes as a double:
  `1.0`, where a limit taken from a request is written as it was sent).
  """
  def stored_amount_in_range(%{value: %Decimal{} = value} = v, min, max) do
    if Decimal.compare(value, min) == :lt or Decimal.compare(value, max) == :gt,
      do:
        Validation.add_error(
          v,
          "validation.msg.#{v.resource}.#{v.parameter}.amount.is.not.within.min.max.range",
          "The parameter `#{v.parameter}` amount #{shown(value)} must be between #{shown(min)} and #{shown(max)} .",
          v.parameter,
          [shown_value(value), shown_value(min), shown_value(max)]
        ),
      else: v
  end

  def stored_amount_in_range(v, _min, _max), do: v

  # limits kept as money are shown with the currency's decimals (`1000.00`)
  @doc false
  def stored_amount_in_range(%{value: %Decimal{} = value} = v, min, max, digits) do
    shown_money = fn d -> d |> Decimal.round(digits) |> Decimal.to_string(:normal) end

    if Decimal.compare(value, min) == :lt or Decimal.compare(value, max) == :gt,
      do:
        Validation.add_error(
          v,
          "validation.msg.#{v.resource}.#{v.parameter}.amount.is.not.within.min.max.range",
          "The parameter `#{v.parameter}` amount #{shown(value)} must be between #{shown_money.(min)} and #{shown_money.(max)} .",
          v.parameter,
          [shown_value(value), shown_value(min), shown_value(max)]
        ),
      else: v
  end

  def stored_amount_in_range(v, _min, _max, _digits), do: v

  @doc false
  def amount_not_below(v, min), do: not_less_than_min(v, min)

  @doc false
  def count_not_above(v, max), do: count_not_greater_than_max(v, max)

  @doc false
  def count_not_below(v, min), do: count_not_less_than_min(v, min)

  defp not_less_than_min(%{value: %Decimal{} = value} = v, %Decimal{} = min) do
    if Decimal.compare(value, min) == :lt,
      do:
        Validation.add_error(
          v,
          "validation.msg.#{v.resource}.#{v.parameter}.is.less.than.min",
          "The parameter `#{v.parameter}` value #{shown(value)} must not be less than the minimum value #{plain(min)}",
          v.parameter,
          [shown_value(value), plain_value(min)]
        ),
      else: v
  end

  defp not_less_than_min(v, _min), do: v

  defp in_min_max_amount(%{value: %Decimal{} = value} = v, min, max) do
    if Decimal.compare(value, min) == :lt or Decimal.compare(value, max) == :gt,
      do:
        Validation.add_error(
          v,
          "validation.msg.#{v.resource}.#{v.parameter}.amount.is.not.within.min.max.range",
          "The parameter `#{v.parameter}` amount #{shown(value)} must be between #{plain(min)} and #{plain(max)} .",
          v.parameter,
          [shown_value(value), plain_value(min), plain_value(max)]
        ),
      else: v
  end

  defp in_min_max_amount(v, _min, _max), do: v

  # an amount as Fineract writes it after passing through a double: `1000.0`
  defp shown(%Decimal{} = d), do: d |> Decimal.to_float() |> java_double()
  defp shown_value(%Decimal{} = d), do: Decimal.to_float(d)

  # Java writes a double as plain digits from 0.001 up to 10 million and in scientific form outside that
  defp java_double(f) when abs(f) >= 1.0e-3 and abs(f) < 1.0e7 do
    text = f |> Decimal.from_float() |> Decimal.to_string(:normal)
    if String.contains?(text, "."), do: text, else: text <> ".0"
  end

  defp java_double(f), do: f |> Float.to_string() |> String.replace("e", "E")

  # the limits are written as they were sent (`1000`), only the amount checked has been through a double
  defp plain(%Decimal{} = d), do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp plain_value(%Decimal{} = d),
    do: if(Decimal.integer?(d), do: Decimal.to_integer(d), else: Decimal.to_float(d))

  # the number of repayments must sit within the minimum and maximum, whichever of them the request names
  defp count_range(v, repayments, min, max) do
    max? = is_integer(max) and max > 0
    min? = is_integer(min) and min > 0

    cond do
      max? and min? ->
        both_counts(v, repayments, min, max)

      max? ->
        v |> Validation.param("numberOfRepayments", repayments) |> count_not_greater_than_max(max)

      min? ->
        v |> Validation.param("numberOfRepayments", repayments) |> count_not_less_than_min(min)

      true ->
        v
    end
  end

  defp both_counts(v, repayments, min, max) do
    v = v |> Validation.param("maxNumberOfRepayments", max) |> count_not_less_than_min(min)

    if min <= max,
      do:
        v |> Validation.param("numberOfRepayments", repayments) |> Validation.in_range(min, max),
      else: v
  end

  defp count_not_less_than_min(%{value: value} = v, min) when is_integer(value) do
    if value < min,
      do:
        Validation.add_error(
          v,
          "validation.msg.#{v.resource}.#{v.parameter}.is.less.than.min",
          "The parameter `#{v.parameter}` must be greater than the minimum value #{min}",
          v.parameter,
          [value, min]
        ),
      else: v
  end

  defp count_not_less_than_min(v, _min), do: v

  defp count_not_greater_than_max(%{value: value} = v, max) when is_integer(value) do
    if value > max,
      do:
        Validation.add_error(
          v,
          "validation.msg.#{v.resource}.#{v.parameter}.is.greater.than.max",
          "The parameter `#{v.parameter}` must be less than the maximum value #{max}",
          v.parameter,
          [value, max]
        ),
      else: v
  end

  defp count_not_greater_than_max(v, _max), do: v

  defp enum(v, p, key, min, max) do
    v
    |> Validation.param(key, Params.integer_in_default_locale(p, key))
    |> Validation.not_null()
    |> Validation.in_range(min, max)
  end

  defp strategy(v, p) do
    code = Params.string(p, "transactionProcessingStrategyCode")
    v = v |> Validation.param("transactionProcessingStrategyCode", code) |> Validation.not_blank()

    if LoanProducts.strategy_name(code) == nil do
      raise ECBPlatform.Errors.ResourceNotFound,
        code: "error.msg.transactions.processing.strategy.code.invalid",
        message:
          "Loan transaction processing strategy with code #{code || "null"} does not exist",
        args: [code]
    end

    v
  end

  defp grace(v, p, key, :amount) do
    v
    |> Validation.param(key, Params.integer_with_locale(p, key))
    |> Validation.zero_or_positive_amount()
  end

  defp grace(v, p, key, :integer) do
    v
    |> Validation.param(key, Params.integer_with_locale(p, key))
    |> Validation.zero_or_greater()
  end

  defp npa_flag(v, p) do
    if Params.exists?(p, "accountMovesOutOfNPAOnlyOnArrearsCompletion"),
      do:
        v
        |> Validation.param(
          "accountMovesOutOfNPAOnlyOnArrearsCompletion",
          Params.boolean(p, "accountMovesOutOfNPAOnlyOnArrearsCompletion")
        )
        |> Validation.not_null(),
      else: v
  end

  # recalculation is asked for as a flag that must be there, even when it is off
  defp recalculation_flag(v, p) do
    v
    |> Validation.param(
      "isInterestRecalculationEnabled",
      Params.boolean(p, "isInterestRecalculationEnabled")
    )
    |> Validation.not_null()
    |> Validation.one_of([true, false])
  end

  defp interest_rate(v, p, rate, min, max) do
    v =
      v
      |> Validation.param("interestRatePerPeriod", rate)
      |> Validation.not_null()
      |> Validation.zero_or_positive_amount()
      |> optional_rate(p, "minInterestRatePerPeriod", min)
      |> optional_rate(p, "maxInterestRatePerPeriod", max)

    v
    |> amount_range("interestRatePerPeriod", rate, "maxInterestRatePerPeriod", min, max)
    |> enum(p, "interestRateFrequencyType", 0, 4)
  end

  defp optional_rate(v, p, key, value) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, value)
        |> Validation.ignore_if_null()
        |> Validation.zero_or_positive_amount(),
      else: v
  end

  defp installment_amount(v, p) do
    v =
      if Params.exists?(p, "installmentAmountInMultiplesOf"),
        do:
          v
          |> Validation.param(
            "installmentAmountInMultiplesOf",
            Params.integer_with_locale(p, "installmentAmountInMultiplesOf")
          )
          |> Validation.ignore_if_null()
          |> Validation.greater_than_zero(),
        else: v

    v
  end

  defp topup(v, _p), do: v

  defp repayment_start(v, p) do
    if Params.exists?(p, "repaymentStartDateType"),
      do:
        v
        |> Validation.param(
          "repaymentStartDateType",
          Params.integer_in_default_locale(p, "repaymentStartDateType")
        )
        |> Validation.not_null()
        |> Validation.one_of([1, 2]),
      else: v
  end

  defp accrual_posting(v, p) do
    rule = Params.integer_in_default_locale(p, "accountingRule")

    if rule not in [3, 4] and Params.exists?(p, "enableAccrualActivityPosting") and
         Params.boolean(p, "enableAccrualActivityPosting") == true do
      v
      |> Validation.param("enableAccrualActivityPosting", true)
      |> Validation.fail_with_code("should be false for non accrual accounting")
    else
      v
    end
  end

  # a loan product may allow several disbursements (tranches), up to a number, with a limit on what may be
  # outstanding (`validateMultiDisburseLoanData`)
  defp multi_disburse(v, p) do
    v =
      if Params.exists?(p, "multiDisburseLoan"),
        do:
          v
          |> Validation.param("multiDisburseLoan", Params.boolean(p, "multiDisburseLoan"))
          |> Validation.ignore_if_null()
          |> Validation.true_or_false(),
        else: v

    if multi?(p) do
      v =
        if Params.exists?(p, "outstandingLoanBalance"),
          do:
            v
            |> Validation.param(
              "outstandingLoanBalance",
              Params.decimal_with_locale(p, "outstandingLoanBalance")
            )
            |> Validation.ignore_if_null()
            |> Validation.zero_or_positive_amount(),
          else: v

      v
      |> Validation.param(
        "maxTrancheCount",
        Params.integer_in_default_locale(p, "maxTrancheCount")
      )
      |> Validation.not_null()
      |> Validation.greater_than_zero()
    else
      v
    end
  end

  @doc "Whether the request makes a product that allows several disbursements."
  def multi?(p), do: Params.boolean(p, "multiDisburseLoan") == true

  # a day-by-day interest calculation takes no partial periods; several disbursements need interest worked out
  # day by day or by partial period (a product that pays out by the advanced allocation strategy would do too, but
  # that is not built)
  defp partial_period(v, p) do
    case Params.integer_in_default_locale(p, "interestCalculationPeriodType") do
      nil ->
        v

      period ->
        {v, partial?} = partial_given(v, p, period)

        if not partial? and multi?(p),
          do:
            v
            |> Validation.param("multiDisburseLoan", true)
            |> then(&%{&1 | value: nil})
            |> Validation.fail_with_code("not.supported.for.selected.interest.calculation.type"),
          else: v
    end
  end

  # the problem with a flag for partial periods on daily interest, and whether interest is worked out by partial
  # period (daily interest always is)
  defp partial_given(v, p, period) do
    if Params.exists?(p, "allowPartialPeriodInterestCalculation") do
      allowed = Params.boolean(p, "allowPartialPeriodInterestCalculation")

      v =
        v
        |> Validation.param("allowPartialPeriodInterestCalculation", allowed)
        |> Validation.not_null()

      cond do
        period == 0 and allowed == true ->
          {Validation.fail_with_code(%{v | value: nil}, "not.supported.for.daily.calculations"),
           true}

        period == 0 ->
          {v, true}

        true ->
          {v, allowed == true}
      end
    else
      {v, period == 0}
    end
  end

  # the periods of grace must leave at least one repayment
  @doc false
  def grace_against_term(v, p, repayments) do
    if repayments == nil do
      v
    else
      v
      |> grace_vs(
        "graceOnPrincipalPayment",
        Params.integer_with_locale(p, "graceOnPrincipalPayment"),
        repayments,
        :le
      )
      |> grace_vs(
        "graceOnInterestPayment",
        Params.integer_with_locale(p, "graceOnInterestPayment"),
        repayments,
        :le
      )
      |> grace_vs(
        "graceOnInterestCharged",
        Params.integer_with_locale(p, "graceOnInterestCharged"),
        repayments,
        :lt
      )
    end
  end

  defp grace_vs(v, key, grace, repayments, mode) do
    value = grace || 0
    too_long? = if mode == :le, do: repayments <= value, else: repayments < value

    if too_long?,
      do:
        v
        |> Validation.param(key, grace)
        |> Validation.fail_with_code("mustBeLessThan.numberOfRepayments"),
      else: v
  end

  # --- accounting -------------------------------------------------------------------------------

  @base_accounts ~w(fundSourceAccountId loanPortfolioAccountId transfersInSuspenseAccountId
                    interestOnLoanAccountId incomeFromFeeAccountId incomeFromPenaltyAccountId
                    incomeFromRecoveryAccountId writeOffAccountId)
  @optional_accounts ~w(goodwillCreditAccountId)
  @required_after ~w(overpaymentLiabilityAccountId)
  @optional_after ~w(incomeFromChargeOffInterestAccountId incomeFromChargeOffFeesAccountId
                     incomeFromChargeOffPenaltyAccountId incomeFromGoodwillCreditInterestAccountId
                     incomeFromGoodwillCreditFeesAccountId incomeFromGoodwillCreditPenaltyAccountId
                     chargeOffExpenseAccountId chargeOffFraudExpenseAccountId)
  @accrual_accounts ~w(receivableInterestAccountId receivableFeeAccountId receivablePenaltyAccountId)

  defp accounting(v, p) do
    rule = Params.integer_in_default_locale(p, "accountingRule")

    v =
      v
      |> Validation.param("accountingRule", rule)
      |> Validation.not_null()
      |> Validation.in_range(1, 4)

    v = if rule in [2, 3, 4], do: accounts(v, p), else: v
    if rule in [3, 4], do: accrual_accounts(v, p), else: v
  end

  defp accounts(v, p) do
    v
    |> required(p, @base_accounts -- ["writeOffAccountId"])
    |> required(p, ["writeOffAccountId"])
    |> optional(p, @optional_accounts)
    |> required(p, @required_after)
    |> optional(p, @optional_after)
    |> payment_channels(p)
    |> charge_mappings(p, "feeToIncomeAccountMappings")
    |> charge_mappings(p, "penaltyToIncomeAccountMappings")
  end

  defp accrual_accounts(v, p), do: required(v, p, @accrual_accounts)

  defp required(v, p, keys) do
    Enum.reduce(keys, v, fn key, v ->
      v
      |> Validation.param(key, Json.long(p, key))
      |> Validation.not_null()
      |> Validation.greater_than_zero()
    end)
  end

  defp optional(v, p, keys) do
    Enum.reduce(keys, v, fn key, v ->
      v
      |> Validation.param(key, Json.long(p, key))
      |> Validation.ignore_if_null()
      |> Validation.greater_than_zero()
    end)
  end

  defp payment_channels(v, p) do
    case Params.value(p, "paymentChannelToFundSourceMappings") do
      [_ | _] = mappings ->
        mappings
        |> Enum.with_index()
        |> Enum.reduce(v, fn {m, i}, v ->
          prefix = "paymentChannelToFundSourceMappings[#{i}]."

          v
          |> Validation.param(prefix <> "paymentTypeId", required_long!(m, "paymentTypeId"))
          |> Validation.not_null()
          |> Validation.greater_than_zero()
          |> Validation.param(
            prefix <> "fundSourceAccountId",
            required_long!(m, "fundSourceAccountId")
          )
          |> Validation.not_null()
          |> Validation.greater_than_zero()
        end)

      _ ->
        v
    end
  end

  defp charge_mappings(v, p, name) do
    case Params.value(p, name) do
      [_ | _] = mappings ->
        mappings
        |> Enum.with_index()
        |> Enum.reduce(v, fn {m, i}, v ->
          prefix = "#{name}[#{i}]."
          params = %Params{map: as_map(m)}

          v
          |> Validation.param(prefix <> "chargeId", Json.long(params, "chargeId"))
          |> Validation.not_null()
          |> Validation.greater_than_zero()
          |> Validation.param(prefix <> "incomeAccountId", Json.long(params, "incomeAccountId"))
          |> Validation.not_null()
          |> Validation.greater_than_zero()
        end)

      _ ->
        v
    end
  end

  defp as_map(%{} = m), do: m
  defp as_map(_other), do: raise(ECBPlatform.Errors.ServerError)

  defp required_long!(m, key) do
    case as_map(m) do
      %{^key => value} when not is_nil(value) -> Json.long(%Params{map: %{key => value}}, key)
      _ -> raise ECBPlatform.Errors.ServerError
    end
  end

  # kept for the options a product offers
  @doc false
  def option_ids(kind), do: LoanEnums.ids(kind)
end
