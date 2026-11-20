defmodule ECBDeposits.DepositAccounts.Submit do
  @moduledoc """
  Applying for a fixed deposit account, changing the application and deleting it, after Fineract's
  `DepositApplicationProcessWritePlatformServiceJpaRepositoryImpl`, `DepositAccountAssembler`,
  `DepositAccountDataValidator`, `FixedDepositAccount` and `DepositAccountTermAndPreClosure`.

  The account copies what it needs of its product (the interest settings, the term and the pre-closure penalty and
  the interest rate chart in force on the day of application) and may override the term. The rate it earns is that
  of the chart for its amount and term, which also gives the maturity date and amount. Applications that link a
  savings account, ask for withholding tax, or whose chart has incentives, are refused as not supported yet.
  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBDeposits.{DepositAccounts, DepositEnums, DepositProducts, SavingsEnums}
  alias ECBDeposits.DepositAccounts.Maturity
  alias ECBDeposits.DepositProducts.TermChanges
  alias ECBDeposits.DepositProducts.Validate, as: ProductValidate
  alias ECBDeposits.Savings.{ApplicationCharges, Charges}
  alias ECBDeposits.Savings.Submit, as: SavingsSubmit
  alias ECBParty.Clients
  alias ECBPlatform.{BusinessDate, Integrity, Json, Params, TenantRepo, Validation}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, UnsupportedParameter}

  @pending 100

  @supported ~w(locale dateFormat monthDayFormat accountNo externalId clientId groupId productId fieldOfficerId
                submittedOnDate nominalAnnualInterestRate interestCompoundingPeriodType interestPostingPeriodType
                interestCalculationType interestCalculationDaysInYearType lockinPeriodFrequency
                lockinPeriodFrequencyType charges charts depositAmount depositPeriod depositPeriodFrequencyId
                savingsAccounts expectedFirstDepositOnDate withHoldTax maturityInstructionId transferToSavingsId
                preClosurePenalApplicable preClosurePenalInterest preClosurePenalInterestOnTypeId minDepositTerm
                maxDepositTerm minDepositTermTypeId maxDepositTermTypeId inMultiplesOfDepositTerm
                inMultiplesOfDepositTermTypeId depositAmount minDepositAmount maxDepositAmount linkAccountId
                transferInterestToSavings)

  @doc "The parameters an application or a change may carry."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  # --- applying -----------------------------------------------------------------------------------

  @doc "Submits the application `p` describes."
  @spec create!(struct, Params.t()) :: Result.t()
  def create!(user, %Params{} = p) do
    Params.check_supported!(p, @supported)
    on = Params.date(p, "submittedOnDate")
    validate!(p, :create)
    ApplicationCharges.validate!(p)
    refuse_beyond_core!(p)

    product = DepositProducts.fetch!(:fixed, Json.long(p, "productId"))
    client = SavingsSubmit.client!(p)
    staff = SavingsSubmit.staff!(p)
    refuse_withholding!(p, product)
    charges = ApplicationCharges.build!(p, product)
    chart = chart_for(product, on)
    refuse_incentives!(chart)

    row = on |> account_row(user, p, product, client, staff) |> rated(chart, p, product)
    term = term_row(p, product)
    domain_rules!("fixeddepositaccount", row, term, chart, on)
    new_application_state!(on, client)

    {row, term} = matured(row, term, on, chart)
    id = SavingsSubmit.insert!(row)

    TenantRepo.insert_all("m_deposit_account_term_and_preclosure", [
      Map.put(term, :savings_account_id, id)
    ])

    if chart, do: copy_chart!(id, chart)
    Enum.each(charges, &Charges.create!(user, id, &1))
    supplied? = SavingsSubmit.blank_to_nil(Params.string(p, "accountNo")) != nil
    unless supplied?, do: SavingsSubmit.generate_account_no!(id, product, client)

    Result.new(
      office_id: client.office_id,
      client_id: client.id,
      savings_id: id,
      resource_id: id
    )
  end

  defp account_row(on, user, p, product, client, staff) do
    row = SavingsSubmit.new_row(user, p, product, client, staff, on)
    %{row | deposit_type_enum: DepositEnums.fixed(), withdrawal_fee_for_transfer: false}
  end

  # the interest rate is that of the chart for the amount and the term, or else the account's own
  defp rated(row, nil, _p, _product), do: row
  defp rated(row, _chart, _p, _product), do: row

  # --- the chart in force -----------------------------------------------------------------------------

  defp chart_for(product, on) do
    today = BusinessDate.current()

    product.id
    |> DepositProducts.charts()
    |> Enum.filter(&chart_in_force?(&1, on, today))
    |> List.first()
  end

  defp chart_in_force?(chart, on, today) do
    last = chart.end_date || today
    Date.compare(on, chart.from_date) != :lt and Date.compare(on, last) != :gt
  end

  defp refuse_incentives!(nil), do: :ok

  defp refuse_incentives!(chart) do
    if Enum.any?(chart.slabs, &(&1.incentives != [])) do
      unsupported!("Interest rate charts with incentives", ["incentives"])
    end
  end

  defp copy_chart!(account_id, chart) do
    {1, [%{id: chart_id}]} =
      TenantRepo.insert_all(
        "m_savings_account_interest_rate_chart",
        [
          %{
            savings_account_id: account_id,
            name: chart.name,
            description: chart.description,
            from_date: chart.from_date,
            end_date: chart.end_date,
            is_primary_grouping_by_amount: chart.grouping
          }
        ],
        returning: [:id]
      )

    for slab <- chart.slabs do
      TenantRepo.insert_all("m_savings_account_interest_rate_slab", [
        %{
          savings_account_interest_rate_chart_id: chart_id,
          description: slab.description,
          period_type_enum: slab.period_type,
          from_period: slab.from_period,
          to_period: slab.to_period,
          amount_range_from: slab.amount_from,
          amount_range_to: slab.amount_to,
          annual_interest_rate: slab.rate,
          currency_code: slab.currency_code
        }
      ])
    end
  end

  # --- the term -------------------------------------------------------------------------------------

  # what the application says about the term and the pre-closure penalty, else what the product says
  defp term_row(p, product) do
    {applicable, interest, basis} = pre_closure(p, product)

    %{
      pre_closure_penal_applicable: applicable,
      pre_closure_penal_interest: interest,
      pre_closure_penal_interest_on_enum: basis,
      min_deposit_term: given_int(p, "minDepositTerm", product[:min_deposit_term]),
      max_deposit_term: given_int(p, "maxDepositTerm", product[:max_deposit_term]),
      min_deposit_term_type_enum:
        given_int(p, "minDepositTermTypeId", product[:min_deposit_term_type]),
      max_deposit_term_type_enum:
        given_int(p, "maxDepositTermTypeId", product[:max_deposit_term_type]),
      in_multiples_of_deposit_term:
        given_int(p, "inMultiplesOfDepositTerm", product[:in_multiples_of_deposit_term]),
      # Fineract looks for the penalty's flag, not the unit's own parameter, to decide whether this was sent
      in_multiples_of_deposit_term_type_enum:
        if(Params.exists?(p, "preClosurePenalApplicable"),
          do: Params.integer(p, "inMultiplesOfDepositTermTypeId"),
          else: product[:in_multiples_of_deposit_term_type]
        ),
      deposit_amount: Params.decimal_with_locale(p, "depositAmount"),
      deposit_period: Params.integer(p, "depositPeriod"),
      deposit_period_frequency_enum: Params.integer(p, "depositPeriodFrequencyId"),
      expected_firstdepositon_date: Params.date(p, "expectedFirstDepositOnDate"),
      transfer_interest_to_linked_account: Params.boolean(p, "transferInterestToSavings") == true,
      on_account_closure_enum: Params.integer(p, "maturityInstructionId"),
      transfer_to_savings_account_id: Json.long(p, "transferToSavingsId")
    }
  end

  defp given_int(p, key, fallback),
    do: if(Params.exists?(p, key), do: Params.integer(p, key), else: fallback)

  # the pre-closure penalty: as the application says when it says whether there is one, else the product's
  defp pre_closure(p, product) do
    cond do
      not Params.exists?(p, "preClosurePenalApplicable") ->
        {product[:pre_closure_penal_applicable] == true, product[:pre_closure_penal_interest],
         product[:pre_closure_penal_interest_on]}

      Params.boolean(p, "preClosurePenalApplicable") != true ->
        {false, nil, nil}

      true ->
        asked? = Params.exists?(p, "preClosurePenalInterest")

        {true,
         if(asked?,
           do: Params.decimal_with_locale(p, "preClosurePenalInterest"),
           else: product[:pre_closure_penal_interest]
         ),
         if(asked?,
           do: Params.integer(p, "preClosurePenalInterestOnTypeId"),
           else: product[:pre_closure_penal_interest_on]
         )}
    end
  end

  # --- what the application is made of -------------------------------------------------------------------

  # the rate and maturity of the term, from the chart or the account's own rate
  defp matured(row, term, on, chart) do
    close = Maturity.date(on, term.deposit_period, term.deposit_period_frequency_enum)
    rate = effective_rate(row, term, chart, on, close)
    row = %{row | nominal_annual_interest_rate: rate}

    amount =
      Maturity.amount(%{
        start: on,
        maturity: close,
        amount: term.deposit_amount,
        rate: rate,
        posting: row.interest_posting_period_enum,
        compounding: row.interest_compounding_period_enum,
        calculation: row.interest_calculation_type_enum,
        days_in_year: row.interest_calculation_days_in_year_type_enum,
        min_balance: row.min_balance_for_interest_calculation,
        decimals: row.currency_digits
      })

    {row, Map.merge(term, %{maturity_date: close, maturity_amount: amount})}
  end

  defp effective_rate(row, _term, nil, _on, _close), do: row.nominal_annual_interest_rate

  defp effective_rate(_row, term, chart, on, close),
    do: Maturity.rate(chart.slabs, term.deposit_amount, on, close)

  # --- the rules of a whole application ---------------------------------------------------------------

  @doc false
  def domain_rules!(resource, row, term, chart, on) do
    Validation.new(resource)
    |> terms_ordered(term)
    |> deposit_period(term, on)
    |> chart_rules(chart, term, on, row)
    |> Validation.raise_if_errors!()
  end

  defp terms_ordered(v, term) do
    if term.min_deposit_term && term.max_deposit_term &&
         TermChanges.days(term.min_deposit_term, term.min_deposit_term_type_enum) >
           TermChanges.days(term.max_deposit_term, term.max_deposit_term_type_enum) do
      Validation.scoped(v, fn v ->
        v
        |> Validation.param("maxDepositTerm", term.max_deposit_term)
        |> Validation.fail_without_parameter("max.term.lessthan.min.term")
      end)
    else
      v
    end
  end

  defp deposit_period(v, term, on) do
    close = Maturity.date(on, term.deposit_period, term.deposit_period_frequency_enum)

    if between_min_and_max?(term, on, close) do
      multiples(v, term)
    else
      Validation.scoped(v, fn v ->
        v
        |> Validation.param("depositPeriod", term.deposit_period)
        |> Validation.fail_without_parameter(
          "deposit.period.not.between.min.and.max.deposit.term"
        )
      end)
    end
  end

  defp between_min_and_max?(term, start, close) do
    at_least?(term, start, close) and at_most?(term, start, close)
  end

  defp at_least?(%{min_deposit_term: nil}, _start, _close), do: true

  defp at_least?(term, start, close),
    do: Maturity.between(start, close, term.min_deposit_term_type_enum) >= term.min_deposit_term

  defp at_most?(%{max_deposit_term: nil}, _start, _close), do: true

  defp at_most?(term, start, close),
    do: Maturity.between(start, close, term.max_deposit_term_type_enum) <= term.max_deposit_term

  # the period, less the minimum, must be a whole number of the steps the term goes up in
  defp multiples(v, %{in_multiples_of_deposit_term: nil}), do: v

  defp multiples(v, term) do
    step =
      TermChanges.days(
        term.in_multiples_of_deposit_term,
        term.in_multiples_of_deposit_term_type_enum
      )

    period = TermChanges.days(term.deposit_period, term.deposit_period_frequency_enum)
    minimum = TermChanges.days(term.min_deposit_term || 0, term.min_deposit_term_type_enum)

    if step != 0 and rem(period - minimum, step) != 0 do
      Validation.scoped(v, fn v ->
        v
        |> Validation.param("depositPeriod", term.deposit_period)
        |> Validation.fail_without_parameter("deposit.period.not.multiple.of.term")
      end)
    else
      v
    end
  end

  defp chart_rules(v, nil, _term, _on, row) do
    rate = row.nominal_annual_interest_rate

    if rate == nil or Decimal.eq?(rate, 0) do
      Validation.scoped(v, fn v ->
        v
        |> Validation.param("nominalAnnualInterestRate", rate)
        |> Validation.fail_without_parameter(
          "valid.interest.chart.or.nominal.interest.rate.required"
        )
      end)
    else
      v
    end
  end

  defp chart_rules(v, chart, term, on, _row) do
    today = BusinessDate.current()
    close = Maturity.date(on, term.deposit_period, term.deposit_period_frequency_enum)
    last = chart.end_date || today

    v =
      if Date.compare(on, chart.from_date) != :lt and Date.compare(on, last) != :gt,
        do: v,
        else:
          Validation.scoped(
            v,
            &Validation.fail_without_parameter(&1, "no.valid.interest.rate.slab.available")
          )

    rate = Maturity.rate(chart.slabs, term.deposit_amount, on, close)

    if Decimal.eq?(rate, 0),
      do:
        Validation.scoped(v, fn v ->
          Validation.fail_without_parameter(
            v,
            "no.applicable.interest.rate.is.found.based.on.amount.and.deposit.period"
          )
        end),
      else: v
  end

  # an application is not for a day that is to come, nor before the client was activated
  defp new_application_state!(on, client) do
    v =
      "fixeddepositaccount.summital"
      |> Validation.new()
      |> Validation.param("submittedOnDate", on)

    cond do
      Date.compare(on, BusinessDate.current()) == :gt ->
        v
        |> Validation.fail_without_parameter("cannot.be.a.future.date")
        |> Validation.raise_if_errors!()

      client && client.activation_date && Date.compare(client.activation_date, on) == :gt ->
        v
        |> Validation.param("submittedOnDate", client.activation_date)
        |> Validation.fail_without_parameter("cannot.be.before.client.activation.date")
        |> Validation.raise_if_errors!()

      true ->
        :ok
    end
  end

  # --- what is refused --------------------------------------------------------------------------------

  defp refuse_beyond_core!(p) do
    asked =
      for {key, asked?} <- [
            {"linkAccountId", Json.long(p, "linkAccountId") != nil},
            {"transferInterestToSavings", Params.boolean(p, "transferInterestToSavings") == true},
            {"groupId", Json.long(p, "groupId") != nil and Json.long(p, "clientId") == nil}
          ],
          asked?,
          do: key

    if asked != [], do: unsupported!("These fixed deposit account settings are", asked)
  end

  # Fineract refuses withholding tax on an account whose product has no tax group
  defp refuse_withholding!(p, product) do
    if Params.boolean(p, "withHoldTax") == true do
      if product.tax_group == nil,
        do: raise(UnsupportedParameter, parameters: ["withHoldTax"]),
        else: unsupported!("Withholding tax on deposits is", ["withHoldTax"])
    end
  end

  defp unsupported!(what, args) do
    raise DomainRuleViolation,
      code: "error.msg.depositaccount.feature.not.supported.yet",
      message: "#{what} not supported yet by E-CoreBank: " <> Enum.join(args, ", "),
      args: args
  end

  # --- checking a request ------------------------------------------------------------------------------

  defp validate!(p, mode) do
    "fixeddepositaccount"
    |> Validation.new()
    |> references(p, mode)
    |> field_officer(p)
    |> submitted_on(p, mode)
    |> text_fields(p)
    |> interest_settings(p)
    |> lockin(p)
    |> linked_account(p)
    |> maturity_instruction(p)
    |> pre_closure(p, mode)
    |> term(p, mode)
    |> withholding(p)
    |> Validation.raise_if_errors!()
  end

  defp references(v, p, mode) do
    client = Json.long(p, "clientId")
    group = Json.long(p, "groupId")
    v = if mode == :create, do: given_positive(v, "clientId", client), else: update_client(v, p)
    v = if group != nil, do: given_positive(v, "groupId", group), else: v

    v =
      if mode == :create and client == nil and group == nil,
        do:
          scoped(
            v,
            &(&1
              |> Validation.param("clientId", nil)
              |> Validation.not_null()
              |> Validation.greater_than_zero())
          ),
        else: v

    product_id(v, p, mode)
  end

  defp product_id(v, p, :create), do: required_product(v, p)

  defp product_id(v, p, :update),
    do: if(Params.exists?(p, "productId"), do: required_product(v, p), else: v)

  defp required_product(v, p) do
    scoped(
      v,
      &(&1
        |> Validation.param("productId", Json.long(p, "productId"))
        |> Validation.not_null()
        |> Validation.greater_than_zero())
    )
  end

  defp update_client(v, p) do
    if Params.exists?(p, "clientId"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("clientId", Json.long(p, "clientId"))
            |> Validation.ignore_if_null()
            |> Validation.greater_than_zero())
        ),
      else: v
  end

  defp given_positive(v, key, id) when is_integer(id),
    do: scoped(v, &(&1 |> Validation.param(key, id) |> Validation.greater_than_zero()))

  defp given_positive(v, _key, _id), do: v

  defp scoped(v, fun), do: Validation.scoped(v, fun)

  defp field_officer(v, p) do
    if Params.exists?(p, "fieldOfficerId"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("fieldOfficerId", Json.long(p, "fieldOfficerId"))
            |> Validation.ignore_if_null()
            |> Validation.greater_than_zero())
        ),
      else: v
  end

  defp submitted_on(v, p, mode) do
    if mode == :create or Params.exists?(p, "submittedOnDate"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("submittedOnDate", Params.date(p, "submittedOnDate"))
            |> Validation.not_null())
        ),
      else: v
  end

  defp text_fields(v, p) do
    v =
      if Params.exists?(p, "accountNo"),
        do:
          scoped(
            v,
            &(&1
              |> Validation.param("accountNo", Params.string(p, "accountNo"))
              |> Validation.not_blank()
              |> Validation.max_length(20))
          ),
        else: v

    if Params.exists?(p, "externalId"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("externalId", Params.string(p, "externalId"))
            |> Validation.max_length(100))
        ),
      else: v
  end

  @enums [
    {"interestCompoundingPeriodType", :compounding_ids},
    {"interestPostingPeriodType", :posting_ids},
    {"interestCalculationType", :calculation_ids},
    {"interestCalculationDaysInYearType", :days_in_year_ids}
  ]

  defp interest_settings(v, p) do
    v =
      if Params.exists?(p, "nominalAnnualInterestRate"),
        do:
          scoped(
            v,
            &(&1
              |> Validation.param(
                "nominalAnnualInterestRate",
                Params.decimal_with_locale(p, "nominalAnnualInterestRate")
              )
              |> Validation.not_null()
              |> Validation.zero_or_positive_amount())
          ),
        else: v

    Enum.reduce(@enums, v, fn {key, ids}, acc ->
      if Params.exists?(p, key),
        do:
          scoped(
            acc,
            &(&1
              |> Validation.param(key, Params.integer(p, key))
              |> Validation.not_null()
              |> Validation.one_of(apply(SavingsEnums, ids, [])))
          ),
        else: acc
    end)
  end

  # the lock-in period and its unit: a period alone checks nothing, a unit alone must be a unit
  defp lockin(v, p) do
    freq? = Params.exists?(p, "lockinPeriodFrequency")
    freq = if freq?, do: Params.integer_with_locale(p, "lockinPeriodFrequency")
    type? = Params.exists?(p, "lockinPeriodFrequencyType")
    type = if type?, do: Params.integer(p, "lockinPeriodFrequencyType")

    v =
      if freq?,
        do:
          scoped(
            v,
            &(&1
              |> Validation.param("lockinPeriodFrequency", freq)
              |> Validation.ignore_if_null())
          ),
        else: v

    cond do
      freq? and freq != nil -> unit_given_with_period(v, type)
      type? -> unit_alone(v, type, freq?)
      true -> v
    end
  end

  defp unit_given_with_period(v, type) do
    scoped(
      v,
      &(&1
        |> Validation.param("lockinPeriodFrequencyType", type)
        |> Validation.ignore_if_null()
        |> Validation.in_range(0, 3))
    )
  end

  defp unit_alone(v, type, freq?) do
    v =
      scoped(
        v,
        &(&1 |> Validation.param("lockinPeriodFrequencyType", type) |> Validation.in_range(0, 3))
      )

    if type != nil and not freq?,
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("lockinPeriodFrequency", nil)
            |> Validation.ignore_if_null()
            |> Validation.zero_or_greater())
        ),
      else: v
  end

  defp linked_account(v, p) do
    required? = Params.boolean(p, "transferInterestToSavings") == true
    id = Json.long(p, "linkAccountId")

    if required?,
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("linkAccountId", id)
            |> Validation.not_null()
            |> Validation.greater_than_zero())
        ),
      else:
        scoped(
          v,
          &(&1
            |> Validation.param("linkAccountId", id)
            |> Validation.ignore_if_null()
            |> Validation.greater_than_zero())
        )
  end

  defp maturity_instruction(v, p) do
    if Params.exists?(p, "maturityInstructionId") do
      id = Params.integer(p, "maturityInstructionId")

      v =
        scoped(
          v,
          &(&1
            |> Validation.param("maturityInstructionId", id)
            |> Validation.not_null()
            |> Validation.one_of([100, 200, 300, 400]))
        )

      if id == 200,
        do:
          scoped(
            v,
            &(&1
              |> Validation.param("transferToSavingsId", Json.long(p, "transferToSavingsId"))
              |> Validation.not_null()
              |> Validation.greater_than_zero())
          ),
        else: v
    else
      v
    end
  end

  defp pre_closure(v, p, :create), do: ProductValidate.pre_closure_create(v, p)

  defp pre_closure(v, p, :update) do
    v
    |> optional(
      p,
      "preClosurePenalApplicable",
      fn x -> Params.boolean(p, x) end,
      &Validation.not_null/1
    )
    |> optional(
      p,
      "preClosurePenalInterest",
      fn x -> Params.decimal_with_locale(p, x) end,
      &(&1 |> Validation.not_null() |> Validation.zero_or_positive_amount())
    )
    |> optional(
      p,
      "preClosurePenalInterestOnTypeId",
      fn x -> Params.integer(p, x) end,
      &(&1 |> Validation.not_null() |> Validation.one_of(DepositEnums.pre_closure_on_ids()))
    )
  end

  defp optional(v, p, key, reader, checks) do
    if Params.exists?(p, key),
      do: scoped(v, &(&1 |> Validation.param(key, reader.(key)) |> checks.())),
      else: v
  end

  defp term(v, p, mode) do
    ids = DepositEnums.term_unit_ids()
    positive = &Validation.greater_than_zero/1

    v =
      v
      |> optional(p, "minDepositTerm", &Params.integer(p, &1), positive)
      |> optional(p, "maxDepositTerm", &Params.integer(p, &1), positive)
      |> optional(p, "minDepositTermTypeId", &Params.integer(p, &1), &Validation.one_of(&1, ids))
      |> optional(p, "maxDepositTermTypeId", &Params.integer(p, &1), &Validation.one_of(&1, ids))

    v = in_multiples(v, p, mode, ids)
    v = term_amount(v, p, mode)
    period(v, p, mode, ids)
  end

  defp in_multiples(v, p, :create, ids) do
    if Params.exists?(p, "inMultiplesOfDepositTerm") do
      step = Params.integer(p, "inMultiplesOfDepositTerm")

      v
      |> scoped(
        &(&1
          |> Validation.param("inMultiplesOfDepositTerm", step)
          |> Validation.greater_than_zero())
      )
      |> scoped(fn v ->
        v
        |> Validation.param(
          "inMultiplesOfDepositTermTypeId",
          Params.integer(p, "inMultiplesOfDepositTermTypeId")
        )
        |> Validation.must_be_provided_when("inMultiplesOfDepositTerm", step)
        |> Validation.one_of(ids)
      end)
    else
      v
    end
  end

  defp in_multiples(v, p, :update, ids) do
    v
    |> optional(
      p,
      "inMultiplesOfDepositTerm",
      &Params.integer(p, &1),
      &Validation.greater_than_zero/1
    )
    |> optional(
      p,
      "inMultiplesOfDepositTermTypeId",
      &Params.integer(p, &1),
      &Validation.one_of(&1, ids)
    )
  end

  defp term_amount(v, p, :create) do
    amount = Params.decimal_with_locale(p, "depositAmount")

    scoped(
      v,
      &(&1
        |> Validation.param("depositAmount", amount)
        |> Validation.not_null()
        |> Validation.positive_amount())
    )
  end

  defp term_amount(v, p, :update) do
    if Params.exists?(p, "depositAmount") do
      amount = Params.decimal_with_locale(p, "depositAmount")

      scoped(
        v,
        &(&1
          |> Validation.param("depositAmount", amount)
          |> Validation.not_null()
          |> Validation.positive_amount())
      )
    else
      v
    end
  end

  defp period(v, p, mode, ids) do
    v =
      if mode == :create or Params.exists?(p, "depositPeriod"),
        do:
          scoped(
            v,
            &(&1
              |> Validation.param("depositPeriod", Params.integer(p, "depositPeriod"))
              |> Validation.not_null()
              |> Validation.greater_than_zero())
          ),
        else: v

    if mode == :create or Params.exists?(p, "depositPeriodFrequencyId"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param(
              "depositPeriodFrequencyId",
              Params.integer(p, "depositPeriodFrequencyId")
            )
            |> Validation.one_of(ids))
        ),
      else: v
  end

  defp withholding(v, p) do
    if Params.exists?(p, "withHoldTax"),
      do:
        scoped(
          v,
          &(&1
            |> Validation.param("withHoldTax", Params.string(p, "withHoldTax"))
            |> Validation.ignore_if_null()
            |> Validation.boolean_text())
        ),
      else: v
  end

  # --- changing an application -------------------------------------------------------------------

  @doc "Changes what an application that is awaiting approval says."
  @spec modify!(struct, integer, Params.t()) :: Result.t()
  def modify!(user, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    validate!(p, :update)
    refuse_beyond_core!(p)

    account = writable!(id)
    client = Clients.fetch!(account.client_id)
    if client.status_enum != Clients.status(:active), do: SavingsSubmit.not_active!(client.id)

    if account.status_enum != @pending do
      Validation.new("fixeddepositaccount.modify")
      |> Validation.fail_without_parameter("not.in.submittedandpendingapproval.state")
      |> Map.update!(:errors, fn [e | rest] -> [Map.put(e, :parameter, nil) | rest] end)
      |> Validation.raise_if_errors!()
    end

    {changes, set, term_set} = changes(p, account)
    check_references!(p, changes)

    if changes != %{} do
      row = Map.merge(account, Map.new(set))

      term =
        Map.merge(
          account.term,
          Map.new(term_set, fn {column, value} -> {term_field(column), value} end)
        )

      matured_update!(user, id, row, term, set, term_set, account)
    end

    Result.new(
      resource_id: id,
      savings_id: id,
      office_id: client.office_id,
      client_id: client.id,
      changes: changes
    )
  end

  # the chart in force on the application's day decides the rate; its rules are asked again as a modification
  defp matured_update!(user, id, row, term, set, term_set, account) do
    on = row.submittedon_date
    chart = DepositAccounts.chart(id)
    term_row = term |> term_columns() |> Map.merge(%{})

    domain_rules!("fixeddepositaccount.modify", row_for_rules(row), term_row, chart, on)
    new_application_state!(on, client_of(account))

    {row2, term2} = matured(row_for_rules(row), term_row, on, chart)

    set =
      Keyword.merge(set,
        nominal_annual_interest_rate: row2.nominal_annual_interest_rate,
        last_modified_by: user.id,
        last_modified_on_utc: DateTime.utc_now()
      )

    term_set =
      Keyword.merge(term_set,
        maturity_date: term2.maturity_date,
        maturity_amount: term2.maturity_amount
      )

    Integrity.translate(
      fn ->
        TenantRepo.update_all(from(a in "m_savings_account", where: a.id == ^id), set: set)

        TenantRepo.update_all(
          from(t in "m_deposit_account_term_and_preclosure", where: t.savings_account_id == ^id),
          set: term_set
        )
      end,
      %{},
      {"error.msg.savingsaccount.unknown.data.integrity.issue",
       "Unknown data integrity issue with savings account."}
    )
  end

  defp client_of(account), do: Clients.fetch!(account.client_id)

  defp row_for_rules(account) do
    %{
      nominal_annual_interest_rate: account.nominal_annual_interest_rate,
      interest_posting_period_enum: account.interest_posting_period_enum,
      interest_compounding_period_enum: account.interest_compounding_period_enum,
      interest_calculation_type_enum: account.interest_calculation_type_enum,
      interest_calculation_days_in_year_type_enum:
        account.interest_calculation_days_in_year_type_enum,
      min_balance_for_interest_calculation: account.min_balance_for_interest_calculation,
      currency_digits: account.currency_digits
    }
  end

  # the term of an account as the rules read it
  defp term_columns(term) do
    %{
      min_deposit_term: term.min_deposit_term,
      max_deposit_term: term.max_deposit_term,
      min_deposit_term_type_enum: term.min_deposit_term_type,
      max_deposit_term_type_enum: term.max_deposit_term_type,
      in_multiples_of_deposit_term: term.in_multiples_of_deposit_term,
      in_multiples_of_deposit_term_type_enum: term.in_multiples_of_deposit_term_type,
      deposit_amount: term.deposit_amount,
      deposit_period: term.deposit_period,
      deposit_period_frequency_enum: term.deposit_period_frequency
    }
  end

  @doc false
  def writable!(id) do
    case DepositAccounts.get(:fixed, id) do
      nil -> raise ECBDeposits.Savings.not_found(id)
      account -> account
    end
  end

  defp check_references!(p, changes) do
    if Map.has_key?(changes, "productId"),
      do: DepositProducts.fetch!(:fixed, Json.long(p, "productId"))

    if Map.has_key?(changes, "clientId") and Json.long(p, "clientId") != nil do
      client = Clients.fetch!(Json.long(p, "clientId"))
      if client.status_enum != Clients.status(:active), do: SavingsSubmit.not_active!(client.id)
    end

    if Map.has_key?(changes, "fieldOfficerId") and Json.long(p, "fieldOfficerId") != nil,
      do: ECBOrg.Staff.fetch!(Json.long(p, "fieldOfficerId"))

    :ok
  end

  @account_fields [
    {"accountNo", :account_no, :text},
    {"externalId", :external_id, :text},
    {"productId", :product_id, :id},
    {"clientId", :client_id, :id},
    {"fieldOfficerId", :field_officer_id, :id},
    {"nominalAnnualInterestRate", :nominal_annual_interest_rate, :decimal},
    {"interestCompoundingPeriodType", :interest_compounding_period_enum, :integer},
    {"interestPostingPeriodType", :interest_posting_period_enum, :integer},
    {"interestCalculationType", :interest_calculation_type_enum, :integer},
    {"interestCalculationDaysInYearType", :interest_calculation_days_in_year_type_enum, :integer}
  ]

  @term_fields [
    {"depositAmount", :deposit_amount, :decimal},
    {"depositPeriod", :deposit_period, :integer},
    {"depositPeriodFrequencyId", :deposit_period_frequency_enum, :unit},
    {"expectedFirstDepositOnDate", :expected_firstdepositon_date, :date},
    {"transferInterestToSavings", :transfer_interest_to_linked_account, :boolean},
    {"maturityInstructionId", :on_account_closure_enum, :integer},
    {"transferToSavingsId", :transfer_to_savings_account_id, :id},
    {"preClosurePenalApplicable", :pre_closure_penal_applicable, :boolean},
    {"preClosurePenalInterest", :pre_closure_penal_interest, :decimal},
    {"preClosurePenalInterestOnTypeId", :pre_closure_penal_interest_on_enum, :pre_closure_on},
    {"minDepositTerm", :min_deposit_term, :integer},
    {"maxDepositTerm", :max_deposit_term, :integer},
    {"minDepositTermTypeId", :min_deposit_term_type_enum, :unit},
    {"maxDepositTermTypeId", :max_deposit_term_type_enum, :unit},
    {"inMultiplesOfDepositTerm", :in_multiples_of_deposit_term, :integer},
    {"inMultiplesOfDepositTermTypeId", :in_multiples_of_deposit_term_type_enum, :unit}
  ]

  # answers the changes to show, the columns of the account and those of its term
  defp changes(p, account) do
    changes = %{}

    {changes, set} =
      if Params.exists?(p, "submittedOnDate") and
           Params.date(p, "submittedOnDate") != account.submittedon_date do
        shown = %{
          "submittedOnDate" => Params.string(p, "submittedOnDate"),
          "locale" => Params.locale(p),
          "dateFormat" => Params.date_format(p)
        }

        {Map.merge(changes, shown), [submittedon_date: Params.date(p, "submittedOnDate")]}
      else
        {changes, []}
      end

    {changes, set} =
      Enum.reduce(@account_fields, {changes, set}, &account_change(&1, &2, p, account))

    term = account.term
    {changes, term_set} = Enum.reduce(@term_fields, {changes, []}, &term_change(&1, &2, p, term))
    {changes, set, penalty_reset(term_set, term)}
  end

  # a penalty that does not apply has no rate and no basis
  defp penalty_reset(term_set, term) do
    applicable =
      Keyword.get(term_set, :pre_closure_penal_applicable, term.pre_closure_penal_applicable)

    if applicable == true,
      do: term_set,
      else:
        Keyword.merge(term_set,
          pre_closure_penal_interest: nil,
          pre_closure_penal_interest_on_enum: nil
        )
  end

  defp account_change({key, column, kind}, {changes, set}, p, account) do
    if Params.exists?(p, key) do
      new = read(p, key, kind)
      old = Map.get(account, column)

      if differs?(new, old),
        do: {Map.put(changes, key, new), Keyword.put(set, column, new)},
        else: {changes, set}
    else
      {changes, set}
    end
  end

  defp term_change({key, column, kind}, {changes, set}, p, term) do
    if Params.exists?(p, key) do
      new = read(p, key, kind)
      old = Map.get(term, term_field(column))

      if differs?(new, old) do
        shown = shown(kind, new)
        changes = Map.put(changes, key, shown)
        changes = with_request(changes, p, key, kind)
        {changes, Keyword.put(set, column, new)}
      else
        {changes, set}
      end
    else
      {changes, set}
    end
  end

  # a date shows the way it was written; the pre-closure penalty's numbers show the locale
  defp with_request(changes, p, _key, :date),
    do: Map.merge(changes, %{"locale" => Params.locale(p), "dateFormat" => Params.date_format(p)})

  defp with_request(changes, p, key, _kind)
       when key in ["preClosurePenalInterest", "preClosurePenalInterestOnTypeId"],
       do: Map.put(changes, "locale", Params.locale(p) || "")

  defp with_request(changes, _p, _key, _kind), do: changes

  defp shown(:unit, new), do: DepositEnums.term_unit(new)
  defp shown(:pre_closure_on, new), do: DepositEnums.pre_closure_on(new)
  defp shown(_kind, new), do: new

  defp term_field(:min_deposit_term_type_enum), do: :min_deposit_term_type
  defp term_field(:max_deposit_term_type_enum), do: :max_deposit_term_type
  defp term_field(:in_multiples_of_deposit_term_type_enum), do: :in_multiples_of_deposit_term_type
  defp term_field(:deposit_period_frequency_enum), do: :deposit_period_frequency
  defp term_field(:pre_closure_penal_interest_on_enum), do: :pre_closure_penal_interest_on
  defp term_field(:expected_firstdepositon_date), do: :expected_first_deposit_on
  defp term_field(:transfer_interest_to_linked_account), do: :transfer_interest
  defp term_field(:on_account_closure_enum), do: :on_closure
  defp term_field(:transfer_to_savings_account_id), do: :transfer_to_savings_id
  defp term_field(other), do: other

  defp read(p, key, :text), do: Params.string(p, key)
  defp read(p, key, :id), do: Json.long(p, key)
  defp read(p, key, :decimal), do: Params.decimal_with_locale(p, key)
  defp read(p, key, :date), do: Params.date(p, key)
  defp read(p, key, :boolean), do: Params.boolean(p, key) == true

  defp read(p, key, kind) when kind in [:integer, :unit, :pre_closure_on],
    do: Params.integer(p, key)

  defp differs?(%Decimal{} = new, %Decimal{} = old), do: not Decimal.eq?(new, old)
  defp differs?(new, old), do: new != old

  # --- deleting ---------------------------------------------------------------------------------------

  @doc "Deletes an application that is awaiting approval."
  @spec delete!(struct, integer) :: Result.t()
  def delete!(_user, id) do
    account = writable!(id)
    client = Clients.fetch!(account.client_id)
    if client.status_enum != Clients.status(:active), do: SavingsSubmit.not_active!(client.id)

    if account.status_enum != @pending do
      Validation.new("fixeddepositaccount.delete")
      |> Validation.param("activatedOnDate", nil)
      |> Validation.fail_without_parameter("not.in.submittedandpendingapproval.state")
      |> Validation.raise_if_errors!()
    end

    TenantRepo.delete_all(from(n in "m_note", where: n.savings_account_id == ^id))

    TenantRepo.delete_all(
      from(h in "m_savings_officer_assignment_history", where: h.account_id == ^id)
    )

    delete_chart!(id)

    TenantRepo.delete_all(
      from(t in "m_deposit_account_term_and_preclosure", where: t.savings_account_id == ^id)
    )

    TenantRepo.delete_all(from(a in "m_savings_account", where: a.id == ^id))
    Result.new(resource_id: id, savings_id: id, office_id: client.office_id, client_id: client.id)
  end

  defp delete_chart!(id) do
    chart_ids =
      TenantRepo.all(
        from(c in "m_savings_account_interest_rate_chart",
          where: c.savings_account_id == ^id,
          select: c.id
        )
      )

    slab_ids =
      TenantRepo.all(
        from(s in "m_savings_account_interest_rate_slab",
          where: s.savings_account_interest_rate_chart_id in ^chart_ids,
          select: s.id
        )
      )

    TenantRepo.delete_all(
      from(i in "m_savings_interest_incentives",
        where: i.deposit_account_interest_rate_slab_id in ^slab_ids
      )
    )

    TenantRepo.delete_all(
      from(s in "m_savings_account_interest_rate_slab", where: s.id in ^slab_ids)
    )

    TenantRepo.delete_all(
      from(c in "m_savings_account_interest_rate_chart", where: c.id in ^chart_ids)
    )
  end
end
