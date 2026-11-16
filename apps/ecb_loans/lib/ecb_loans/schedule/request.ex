defmodule ECBLoans.Schedule.Request do
  @moduledoc """
  What a loan application says, checked and turned into the terms a schedule is worked out from. Follows
  Fineract's `LoanApplicationValidator`, `LoanScheduleValidator` and `LoanScheduleAssembler` for an individual
  loan on a core term loan product.

  The terms come from the request and, where the request is silent (or the product does not allow the
  request to override), from the product. A request that asks for something past the core (several
  disbursements, charges, a group or JLG loan, collateral, a linked savings account, a calendar, interest
  charged from a later date, a fixed EMI, an equal-amortisation or topup loan) is refused with a plain "not
  supported yet" and never ignored.
  """
  alias ECBLoans.{Apr, LoanProducts}
  alias ECBParty.Clients
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Json, Params, Validation}

  @resource "loan"

  # every parameter a loan application may carry (`LoanApplicationValidator.SUPPORTED_PARAMETERS`)
  @supported ~w(dateFormat locale id clientId groupId loanType productId principal totalLoan parentAccount
                loanTermFrequency loanTermFrequencyType numberOfRepayments repaymentEvery repaymentFrequencyType
                repaymentFrequencyNthDayType repaymentFrequencyDayOfWeekType interestRatePerPeriod amortizationType
                amortizationTypeOptions interestType isFloatingInterestRate interestRateDifferential
                interestCalculationPeriodType allowPartialPeriodInterestCalculation interestRateFrequencyType
                expectedDisbursementDate repaymentsStartingFromDate graceOnPrincipalPayment graceOnInterestPayment
                graceOnInterestCharged interestChargedFromDate submittedOnDate submittedOnNote accountNo externalId
                fundId loanOfficerId loanPurposeId inArrearsTolerance charges collateral
                transactionProcessingStrategyCode calendarId syncDisbursementWithMeeting linkAccountId
                disbursementData fixedEmiAmount maxOutstandingLoanBalance graceOnArrearsAgeing
                createStandingInstructionAtDisbursement isTopup loanIdToClose datatables isEqualAmortization rates
                applicationId lastApplication daysInYearType fixedPrincipalPercentagePerInstallment
                disallowExpectedDisbursements fraud loanScheduleProcessingType fixedLength
                enableInstallmentLevelDelinquency enableDownPayment enableAutoRepaymentForDownPayment
                disbursedAmountPercentageForDownPayment interestRecognitionOnDisbursementDate
                daysInYearCustomStrategy allowFullTermForTranche originators repaymentStartDateType)

  # what a request may carry beyond the core, each with the one value that means "not asked for"
  @beyond_core %{
    "groupId" => [nil],
    "calendarId" => [nil],
    "syncDisbursementWithMeeting" => [nil, false],
    "linkAccountId" => [nil],
    "createStandingInstructionAtDisbursement" => [nil, false],
    "collateral" => [nil, []],
    "charges" => [nil, []],
    "disbursementData" => [nil, []],
    "fixedEmiAmount" => [nil],
    "maxOutstandingLoanBalance" => [nil],
    "isEqualAmortization" => [nil, false],
    "isTopup" => [nil, false],
    "loanIdToClose" => [nil],
    "datatables" => [nil, []],
    "rates" => [nil, []],
    "isFloatingInterestRate" => [nil],
    "interestRateDifferential" => [nil],
    "repaymentFrequencyNthDayType" => [nil],
    "repaymentFrequencyDayOfWeekType" => [nil],
    "fixedPrincipalPercentagePerInstallment" => [nil],
    "disallowExpectedDisbursements" => [nil, false],
    "enableDownPayment" => [nil, false],
    "enableAutoRepaymentForDownPayment" => [nil, false],
    "disbursedAmountPercentageForDownPayment" => [nil],
    "enableInstallmentLevelDelinquency" => [nil, false],
    "interestChargedFromDate" => [nil],
    "fixedLength" => [nil],
    "interestRecognitionOnDisbursementDate" => [nil, false],
    "daysInYearCustomStrategy" => [nil],
    "allowFullTermForTranche" => [nil, false],
    "originators" => [nil, []],
    "fraud" => [nil, false],
    "applicationId" => [nil],
    "lastApplication" => [nil],
    "loanScheduleProcessingType" => [nil, "HORIZONTAL"]
  }

  @doc "The parameters a loan application may carry."
  def supported, do: @supported

  @doc """
  Checks a request to calculate a schedule and returns what the schedule is worked out from:
  `%{terms:, product:, client:}`.
  """
  @spec assemble!(Params.t()) :: map
  def assemble!(%Params{} = p) do
    Params.check_supported!(p, @supported)

    product_id = Json.long(p, "productId")
    if product_id == nil, do: mandatory_product!()
    product = LoanProducts.fetch!(product_id)

    client = client!(p)
    group!(p)
    check_client_given!(p, client)
    check!(p, product, client)
    check_schedule!(p)
    refuse_beyond_core!(p)

    terms = terms(p, product)
    check_calendar!(client, terms.disbursement_date)
    check_first_repayment!(terms, product)
    %{product: product, client: client, terms: terms}
  end

  # --- the checks, in Fineract's order ----------------------------------------------------------

  defp mandatory_product! do
    raise ECBPlatform.Errors.PlatformApiDataValidation,
      errors: [
        %{
          code: "validation.msg.loans.productId.cannot.be.blank",
          developer_message: "The parameter `productId` is mandatory.",
          default_message: "The parameter `productId` is mandatory.",
          parameter: "productId",
          args: [0]
        }
      ]
  end

  defp client!(p) do
    case Json.long(p, "clientId") do
      nil ->
        nil

      id ->
        client = Clients.fetch!(id)
        if client.status_enum != Clients.status(:active), do: not_active!(id)
        client
    end
  end

  # a group is looked up after the client; groups are not built yet, so any group id is not found
  defp group!(p) do
    case Json.long(p, "groupId") do
      nil -> :ok
      id -> ECBParty.Lookups.group!(id)
    end
  end

  # without a client (a group loan is not supported yet) the application has nobody to lend to
  defp check_client_given!(p, nil) do
    if Params.exists?(p, "groupId") and Params.value(p, "groupId") != nil do
      refuse!(["groupId"])
    else
      Validation.new(@resource)
      |> Validation.param("clientId", nil)
      |> Validation.not_null()
      |> Validation.raise_if_errors!()
    end
  end

  defp check_client_given!(_p, _client), do: :ok

  defp not_active!(id) do
    raise DomainRuleViolation,
      code: "error.msg.client.not.active.exception",
      message: "The Client with id `#{id}` is not active",
      args: [id]
  end

  defp check!(p, product, client) do
    v = Validation.new(@resource)

    type = Params.string(p, "loanType")

    v =
      v
      |> Validation.param("loanType", type)
      |> Validation.not_null()
      |> individual_client(p, type, client)

    v
    |> Validation.param("productId", Json.long(p, "productId"))
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> text(p, "accountNo", 20)
    |> text(p, "externalId", 100)
    |> positive_id(p, "fundId")
    |> positive_id(p, "loanOfficerId")
    |> positive_id(p, "loanPurposeId")
    |> Validation.param("loanTermFrequency", Params.integer_with_locale(p, "loanTermFrequency"))
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param(
      "loanTermFrequencyType",
      Params.integer_in_default_locale(p, "loanTermFrequencyType")
    )
    |> Validation.not_null()
    |> Validation.in_range(0, 3)
    |> Validation.param("numberOfRepayments", Params.integer_with_locale(p, "numberOfRepayments"))
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("repaymentEvery", Params.integer_with_locale(p, "repaymentEvery"))
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> enum(p, "repaymentFrequencyType", 0, 3)
    |> enum(p, "interestType", 0, 1)
    |> enum(p, "interestCalculationPeriodType", 0, 1)
    |> Validation.param(
      "interestRatePerPeriod",
      Params.decimal_with_locale(p, "interestRatePerPeriod")
    )
    |> Validation.not_null()
    |> Validation.zero_or_positive_amount()
    |> enum(p, "amortizationType", 0, 1)
    |> Validation.param("expectedDisbursementDate", Params.date(p, "expectedDisbursementDate"))
    |> Validation.not_null()
    |> amount(p, "graceOnPrincipalPayment")
    |> amount(p, "graceOnInterestPayment")
    |> amount(p, "graceOnInterestCharged")
    |> amount(p, "graceOnArrearsAgeing")
    |> optional_tolerance(p)
    |> Validation.param("submittedOnDate", Params.date(p, "submittedOnDate"))
    |> Validation.not_null()
    |> text(p, "submittedOnNote", 500)
    |> Validation.param(
      "transactionProcessingStrategyCode",
      Params.string(p, "transactionProcessingStrategyCode")
    )
    |> Validation.not_null()
    |> days_in_year(p)
    |> product_limits(p, product)
    |> rate_limits(p, product)
    |> ECBLoans.LoanProducts.Validate.grace_against_term(
      p,
      Params.integer_with_locale(p, "numberOfRepayments")
    )
    |> partial_period(p)
    |> Validation.raise_if_errors!()

    submitted_on!(p, product, client)
    strategy!(p, product)
  end

  # the loan type by name: individual 1, group 2, JLG 3, GLIM 4; any other name is 0, which is out of range
  defp type_number(nil), do: nil

  defp type_number(type) do
    case String.downcase(type) do
      "individual" -> 1
      "group" -> 2
      "jlg" -> 3
      "glim" -> 4
      _ -> 0
    end
  end

  defp individual_client(v, p, type, _client) do
    case type_number(type) do
      nil ->
        v

      number ->
        v = v |> Validation.param("loanType", number) |> Validation.in_range(1, 4)

        if number == 1 do
          v
          |> Validation.param("clientId", Json.long(p, "clientId"))
          |> Validation.not_null()
          |> Validation.greater_than_zero()
        else
          v
        end
    end
  end

  defp text(v, p, key, max) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, Params.string(p, key))
        |> Validation.ignore_if_null()
        |> Validation.max_length(max),
      else: v
  end

  defp positive_id(v, p, key) do
    if Params.exists?(p, key),
      do:
        v
        |> Validation.param(key, Json.long(p, key))
        |> Validation.ignore_if_null()
        |> Validation.greater_than_zero(),
      else: v
  end

  defp enum(v, p, key, min, max) do
    v
    |> Validation.param(key, Params.integer_in_default_locale(p, key))
    |> Validation.not_null()
    |> Validation.in_range(min, max)
  end

  defp amount(v, p, key) do
    v
    |> Validation.param(key, Params.integer_with_locale(p, key))
    |> Validation.zero_or_positive_amount()
  end

  defp optional_tolerance(v, p) do
    if Params.exists?(p, "inArrearsTolerance"),
      do:
        v
        |> Validation.param(
          "inArrearsTolerance",
          Params.decimal_with_locale(p, "inArrearsTolerance")
        )
        |> Validation.ignore_if_null()
        |> Validation.zero_or_positive_amount(),
      else: v
  end

  defp days_in_year(v, p) do
    if Params.exists?(p, "daysInYearType"),
      do:
        v
        |> Validation.param(
          "daysInYearType",
          Params.integer_in_default_locale(p, "daysInYearType")
        )
        |> Validation.not_null()
        |> Validation.one_of([1, 360, 364, 365]),
      else: v
  end

  # the request against the product's own limits
  defp product_limits(v, p, product) do
    v
    |> principal_limits(p, product)
    |> repayment_limits(p, product)
  end

  defp principal_limits(v, p, product) do
    if Params.exists?(p, "principal") do
      principal = Params.decimal_with_locale(p, "principal")
      min = product.min_principal
      max = product.max_principal
      v = Validation.param(v, "principal", principal)

      cond do
        positive?(min) and positive?(max) ->
          ECBLoans.LoanProducts.Validate.stored_amount_in_range(
            v,
            min,
            max,
            product.currency.decimal_places
          )

        positive?(min) ->
          ECBLoans.LoanProducts.Validate.amount_not_below(v, min)

        positive?(max) ->
          Validation.not_greater_than_max(v, max)

        true ->
          v
      end
    else
      v
    end
  end

  defp repayment_limits(v, p, product) do
    if Params.exists?(p, "numberOfRepayments") do
      repayments = Params.integer_with_locale(p, "numberOfRepayments")

      v
      |> Validation.param("numberOfRepayments", repayments)
      |> count_limits(product.min_number_of_repayments, product.max_number_of_repayments)
    else
      v
    end
  end

  defp count_limits(v, min, max) do
    case {limit?(min), limit?(max)} do
      {true, true} -> Validation.in_range(v, min, max)
      {false, true} -> ECBLoans.LoanProducts.Validate.count_not_above(v, max)
      {true, false} -> ECBLoans.LoanProducts.Validate.count_not_below(v, min)
      {false, false} -> v
    end
  end

  defp limit?(n), do: is_integer(n) and n > 0

  # the rate against the product's limits (a rate linked to floating rates is not supported)
  defp rate_limits(v, p, product) do
    if Params.exists?(p, "interestRatePerPeriod") do
      min = product.min_interest_rate
      max = product.max_interest_rate
      rate = Params.decimal_with_locale(p, "interestRatePerPeriod")
      v = Validation.param(v, "interestRatePerPeriod", rate)

      cond do
        max != nil and min != nil ->
          ECBLoans.LoanProducts.Validate.stored_amount_in_range(v, min, max)

        max != nil ->
          Validation.not_greater_than_max(v, max)

        min != nil ->
          ECBLoans.LoanProducts.Validate.amount_not_below(v, min)

        true ->
          v
      end
    else
      v
    end
  end

  # a day-by-day interest calculation takes no partial periods
  defp partial_period(v, p) do
    period = Params.integer_in_default_locale(p, "interestCalculationPeriodType")

    if period != nil and Params.exists?(p, "allowPartialPeriodInterestCalculation") do
      allowed = Params.boolean(p, "allowPartialPeriodInterestCalculation")

      v =
        v
        |> Validation.param("allowPartialPeriodInterestCalculation", allowed)
        |> Validation.not_null()
        |> Validation.one_of([true, false])

      if period == 0 and allowed == true,
        do: Validation.fail_with_code(%{v | value: nil}, "not.supported.for.daily.calcualtions"),
        else: v
    else
      v
    end
  end

  # the second validator (`LoanScheduleValidator`), run when the first has found nothing wrong
  defp check_schedule!(p) do
    term = Params.integer_with_locale(p, "loanTermFrequency")
    term_type = Params.integer_with_locale(p, "loanTermFrequencyType")
    repayments = Params.integer_with_locale(p, "numberOfRepayments")
    every = Params.integer_with_locale(p, "repaymentEvery")
    every_type = Params.integer_with_locale(p, "repaymentFrequencyType")

    errors =
      same_frequency_errors(term, term_type, repayments, every, every_type) ++
        starts_before_disbursement(p)

    if errors != [],
      do: raise(ECBPlatform.Errors.PlatformApiDataValidation, errors: errors)
  end

  defp same_frequency_errors(term, term_type, repayments, every, every_type) do
    if term_type != nil and term_type != every_type do
      [
        schedule_error(
          "loanTermFrequencyType.not.the.same.as.repaymentFrequencyType",
          "The parameters loanTermFrequencyType and repaymentFrequencyType must be the same.",
          "loanTermFrequencyType",
          [term_type, every_type]
        )
      ]
    else
      term_against_structure(term, repayments, every)
    end
  end

  defp term_against_structure(term, repayments, every)
       when is_integer(term) and is_integer(repayments) and is_integer(every) do
    suggested = every * repayments

    cond do
      term < suggested ->
        [
          schedule_error(
            "loanTermFrequency.less.than.repayment.structure.suggests",
            "The parameter loanTermFrequency is less than the suggest loan term as indicated by numberOfRepayments and repaymentEvery.",
            "loanTermFrequency",
            [term, repayments, every]
          )
        ]

      term > suggested ->
        [
          schedule_error(
            "loanTermFrequency.greater.than.repayment.structure.suggests",
            "The parameter loanTermFrequency is greater than the suggested loan term as indicated by numberOfRepayments and repaymentEvery.",
            "loanTermFrequency",
            [term, repayments, every]
          )
        ]

      true ->
        []
    end
  end

  defp term_against_structure(_term, _repayments, _every), do: []

  defp starts_before_disbursement(p) do
    expected = Params.date(p, "expectedDisbursementDate")
    first = Params.date(p, "repaymentsStartingFromDate")

    if first != nil and Date.compare(expected, first) == :gt,
      do: [
        schedule_error(
          "expectedDisbursementDate.cannot.be.after.first.repayment.date",
          "The parameter expectedDisbursementDate has a date which falls after the date for repaymentsStartingFromDate.",
          "expectedDisbursementDate",
          [Date.to_iso8601(expected), Date.to_iso8601(first)]
        )
      ],
      else: []
  end

  defp schedule_error(code, message, parameter, args) do
    %{
      code: "validation.msg.loan." <> code,
      developer_message: message,
      default_message: message,
      parameter: parameter,
      args: args
    }
  end

  defp positive?(nil), do: false
  defp positive?(%Decimal{} = d), do: Decimal.gt?(d, 0)

  defp submitted_on!(p, product, client) do
    submitted = Params.date(p, "submittedOnDate")
    expected = Params.date(p, "expectedDisbursementDate")

    product_dates!(submitted, product)
    not_in_future!(submitted)
    client_dates!(submitted, client)
    not_after_disbursement!(submitted, expected)
  end

  defp product_dates!(submitted, product) do
    cond do
      product.start_date && Date.compare(submitted, product.start_date) == :lt ->
        date_error!(
          "submitted.on.date.cannot.be.before.the.loan.product.start.date",
          "submittedOnDate cannot be before the loan product startDate.",
          [Date.to_iso8601(submitted), Date.to_iso8601(product.start_date)]
        )

      product.close_date && Date.compare(submitted, product.close_date) == :gt ->
        date_error!(
          "submitted.on.date.cannot.be.after.the.loan.product.close.date",
          "submittedOnDate cannot be after the loan product closeDate.",
          [Date.to_iso8601(submitted), Date.to_iso8601(product.close_date)]
        )

      true ->
        :ok
    end
  end

  defp not_in_future!(submitted) do
    today = ECBPlatform.BusinessDate.current()

    if Date.compare(submitted, today) == :gt,
      do:
        state_error!(
          "cannot.be.a.future.date",
          "The date on which a loan is submitted cannot be in the future.",
          [submitted, today]
        )
  end

  defp client_dates!(submitted, client) do
    if client && client.activation_date && Date.compare(client.activation_date, submitted) == :gt,
      do:
        state_error!(
          "cannot.be.before.client.activation.date",
          "The date on which a loan is submitted cannot be earlier than client's activation date.",
          [submitted, client.activation_date]
        )
  end

  defp not_after_disbursement!(submitted, expected) do
    if Date.compare(submitted, expected) == :gt,
      do:
        state_error!(
          "cannot.be.after.expected.disbursement.date",
          "The date on which a loan is submitted cannot be after its expected disbursement date: " <>
            Date.to_iso8601(expected),
          [submitted, expected]
        )
  end

  defp date_error!(code, message, args) do
    raise DomainRuleViolation,
      code: "error.msg.loan.application." <> code,
      message: message,
      args: args
  end

  defp state_error!(code, message, args) do
    raise DomainRuleViolation,
      code: "error.msg.loan.submittal." <> code,
      message: message,
      args: Enum.map(args, &Date.to_iso8601/1)
  end

  defp strategy!(p, product) do
    code = Params.string(p, "transactionProcessingStrategyCode")

    cond do
      code == "advanced-payment-allocation-strategy" and
          product.strategy_code != "advanced-payment-allocation-strategy" ->
        raise DomainRuleViolation,
          code: "strategy.cannot.be.advanced.payment.allocation.if.not.configured",
          message:
            "Loan transaction processing strategy cannot be Advanced Payment Allocation Strategy if it's not configured on loan product",
          args: []

      LoanProducts.strategy_name(code) == nil ->
        raise ResourceNotFound,
          code: "error.msg.transactions.processing.strategy.code.invalid",
          message:
            "Loan transaction processing strategy with code #{code || "null"} does not exist",
          args: [code]

      true ->
        _ = product
        :ok
    end
  end

  defp refuse_beyond_core!(p) do
    asked =
      for {key, defaults} <- @beyond_core,
          Params.exists?(p, key),
          Params.value(p, key) not in defaults,
          do: key

    type = Params.string(p, "loanType")

    asked =
      if type != nil and String.downcase(type) in ["group", "jlg", "glim"],
        do: ["loanType" | asked],
        else: asked

    case Enum.sort(asked) do
      [] -> :ok
      names -> refuse!(names)
    end
  end

  defp refuse!(names) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message:
        "These loan application settings are not supported yet by E-CoreBank: " <>
          Enum.join(names, ", "),
      args: names
  end

  # --- the terms --------------------------------------------------------------------------------

  @doc false
  def terms(p, product) do
    context = ECBMoney.Context.new(:half_even)

    currency =
      ECBMoney.Currency.new(product.currency.code, product.currency.decimal_places,
        in_multiples_of: positive_or_nil(product.currency.multiples_of)
      )

    %{
      currency: currency,
      context: context,
      principal: ECBMoney.new(currency, Params.decimal_with_locale(p, "principal"), context),
      amortization: Params.integer_in_default_locale(p, "amortizationType"),
      interest_method: Params.integer_in_default_locale(p, "interestType"),
      interest_calculation_period:
        Params.integer_in_default_locale(p, "interestCalculationPeriodType"),
      allow_partial_period: partial(p, product),
      days_in_month: product.days_in_month_id,
      interest_charged_from: nil,
      loan_term_frequency: Params.integer_with_locale(p, "loanTermFrequency"),
      installment_multiples_of: product.installment_amount_in_multiples_of,
      principal_threshold: product.principal_threshold_for_last_installment || Decimal.new(0)
    }
    |> Map.merge(repayment_terms(p, product))
    |> Map.merge(grace_terms(p, product))
    |> Map.merge(date_terms(p, product))
    |> then(&Map.merge(&1, rate_terms(p, product, &1)))
  end

  defp repayment_terms(p, product) do
    %{
      number_of_repayments: Params.integer_with_locale(p, "numberOfRepayments"),
      repayment_every: Params.integer_with_locale(p, "repaymentEvery") || product.repay_every,
      repayment_frequency: Params.integer_in_default_locale(p, "repaymentFrequencyType")
    }
  end

  defp grace_terms(p, product) do
    %{
      grace_principal:
        Params.integer_with_locale(p, "graceOnPrincipalPayment") || product.grace_on_principal ||
          0,
      grace_interest:
        Params.integer_with_locale(p, "graceOnInterestPayment") || product.grace_on_interest || 0,
      grace_interest_charged: Params.integer_with_locale(p, "graceOnInterestCharged") || 0
    }
  end

  # the yearly rate, from the rate per period and how often it is quoted
  defp rate_terms(p, product, terms) do
    rate_frequency =
      if Params.exists?(p, "interestRateFrequencyType"),
        do: Params.integer_with_locale(p, "interestRateFrequencyType"),
        else: product.interest_frequency_id

    days_in_year =
      if Params.exists?(p, "daysInYearType"),
        do: Params.integer_in_default_locale(p, "daysInYearType"),
        else: product.days_in_year_id

    rate = Params.decimal_with_locale(p, "interestRatePerPeriod")

    %{
      days_in_year: days_in_year,
      annual_rate:
        Apr.calculate(
          rate_frequency,
          rate,
          terms.number_of_repayments,
          terms.repayment_every,
          terms.repayment_frequency,
          days_in_year
        )
    }
  end

  defp date_terms(p, product) do
    expected = Params.date(p, "expectedDisbursementDate")
    submitted = Params.date(p, "submittedOnDate")
    start = if (product.repayment_start_id || 1) == 1, do: expected, else: submitted
    every = Params.integer_with_locale(p, "repaymentEvery") || product.repay_every
    frequency = Params.integer_in_default_locale(p, "repaymentFrequencyType")
    min_days = product.min_days_between_disbursal_and_first_repayment || 0
    given_first = Params.date(p, "repaymentsStartingFromDate")

    {seed_from, first} =
      first_repayment(given_first, start, expected, every, frequency, min_days)

    %{
      disbursement_date: expected,
      submitted_date: submitted,
      repayment_start: start,
      first_repayment_date: first,
      seed_date: seed_from || start
    }
  end

  # Due dates that fall on a non-working day or a holiday are moved by Fineract; that is not built yet, so a
  # tenant whose calendar would move one is refused instead of getting dates that are not moved
  defp check_calendar!(client, disbursement) do
    unless seven_day_week?() do
      refuse!(["working days other than every day of the week"])
    end

    holidays = if client, do: ECBOrg.Holidays.list(client.office_id), else: []

    active =
      Enum.filter(holidays, fn h ->
        h.status_id == 300 and Date.compare(h.to_date, disbursement) != :lt
      end)

    if active != [] and ECBPlatform.Configuration.enabled?("reschedule-repayments-on-holidays") do
      refuse!(["holidays that move repayments"])
    end

    on_holiday =
      not ECBPlatform.Configuration.enabled?("allow-transactions-on-holiday") and
        Enum.any?(active, &(Date.compare(&1.from_date, disbursement) != :gt))

    if on_holiday do
      date_error!(
        "disbursement.date.on.holiday",
        "Expected disbursement date cannot be on a holiday",
        [Date.to_iso8601(disbursement)]
      )
    end
  end

  defp seven_day_week? do
    case ECBOrg.WorkingDays.get() do
      %{recurrence: recurrence} when is_binary(recurrence) ->
        case Regex.run(~r/BYDAY=([A-Z,]+)/, recurrence) do
          [_, days] -> length(String.split(days, ",")) == 7
          _ -> false
        end

      _ ->
        true
    end
  end

  # the first repayment must be at least the product's number of days after disbursement
  defp check_first_repayment!(terms, product) do
    min = product.min_days_between_disbursal_and_first_repayment || 0

    if product.repayment_start_id in [nil, 1] and
         Date.compare(terms.first_repayment_date, Date.add(terms.disbursement_date, min)) == :lt do
      raise DomainRuleViolation,
        code:
          "error.msg.loan.days.between.first.repayment.and.disbursal.are.less.than.minimum.allowed",
        message:
          "Number of days between loan disbursal  (#{terms.disbursement_date}) and first repayment (#{terms.first_repayment_date}) can't be less than (#{min}).",
        args: [
          Date.to_iso8601(terms.disbursement_date),
          Date.to_iso8601(terms.first_repayment_date),
          min
        ]
    end
  end

  defp positive_or_nil(n) when is_integer(n) and n > 0, do: n
  defp positive_or_nil(_), do: nil

  defp partial(p, product) do
    case Params.boolean(p, "allowPartialPeriodInterestCalculation") do
      nil -> product.allow_partial_period == true
      value -> value
    end
  end

  # the first due date: the one asked for, or the later of "one period after the start" and "the minimum
  # number of days after disbursement"
  defp first_repayment(given, _start, _expected, _every, _frequency, _min) when given != nil,
    do: {given, given}

  defp first_repayment(nil, start, expected, every, frequency, min_days) do
    by_frequency = ECBLoans.Schedule.Dates.plus(start, frequency, every)
    by_minimum = Date.add(expected, min_days)
    first = if Date.compare(by_frequency, by_minimum) == :gt, do: by_frequency, else: by_minimum
    plain = by_frequency

    if plain == first, do: {nil, first}, else: {first, first}
  end
end
