defmodule ECBApiFineract.Resources.LoanProducts do
  @moduledoc """
  `/v1/loanproducts`: what loans are made from. List, one product (with its charges and, when it keeps accounts
  in the ledger, the accounts its money goes to; `?template=true` adds the choices a form needs), the template
  for a new product, create, update and delete. Reading needs `READ_LOANPRODUCT`.

  Fineract writes the many fixed settings and lists of choices into every product it shows; those are kept in
  `priv/loan_product_static.json` (recorded from it) and the settings that belong to the product are laid over
  them.
  """
  alias ECBApiFineract.Resources.{Charges, GLAccounts, PaymentTypes, Read, Write}
  alias ECBCatalog.Charges, as: CatalogCharges
  alias ECBLedger.GLAccounts, as: Ledger
  alias ECBLoans.LoanProducts
  alias ECBOrg.{Codes, Currencies, Funds}
  alias ECBOrg.PaymentTypes, as: OrgPaymentTypes

  @resource "LOANPRODUCT"

  # The names `fields` may ask for; Fineract refuses any other name in `fields`.
  @choosable ~w(id name shortName description fundId fundName includeInBorrowerCycle currency principal
                minPrincipal maxPrincipal numberOfRepayments minNumberOfRepayments maxNumberOfRepayments
                repaymentEvery repaymentFrequencyType graceOnPrincipalPayment
                recurringMoratoriumOnPrincipalPeriods graceOnInterestPayment graceOnInterestCharged
                interestRatePerPeriod minInterestRatePerPeriod maxInterestRatePerPeriod
                interestRateFrequencyType annualInterestRate amortizationType interestType
                interestCalculationPeriodType allowPartialPeriodInterestCalculation inArrearsTolerance
                transactionProcessingStrategyCode transactionProcessingStrategyName charges
                accountingRule externalId datatables accountingMappings
                paymentChannelToFundSourceMappings fundOptions paymentTypeOptions currencyOptions
                repaymentFrequencyTypeOptions interestRateFrequencyTypeOptions amortizationTypeOptions
                interestTypeOptions interestCalculationPeriodTypeOptions
                transactionProcessingStrategyOptions chargeOptions accountingOptions
                accountingRuleOptions accountingMappingOptions floatingRateOptions
                isLinkedToFloatingInterestRates floatingRatesId interestRateDifferential
                minDifferentialLendingRate defaultDifferentialLendingRate maxDifferentialLendingRate
                isFloatingInterestRateCalculationAllowed canUseForTopup isEqualAmortization rates
                fixedPrincipalPercentagePerInstallment dueDaysForRepaymentEvent
                overDueDaysForRepaymentEvent enableDownPayment disbursedAmountPercentageForDownPayment
                enableAutoRepaymentForDownPayment repaymentStartDateType daysInYearCustomStrategy
                enableIncomeCapitalization capitalizedIncomeCalculationType capitalizedIncomeStrategy
                capitalizedIncomeType enableBuyDownFee buyDownFeeCalculationType buyDownFeeStrategy
                buyDownFeeIncomeType)

  @doc "`GET /loanproducts`"
  def index(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      omits = LoanProducts.static()["list_omits"]

      LoanProducts.list()
      |> Enum.map(&(&1 |> product_json() |> Map.drop(omits)))
      |> only_fields(q)
    end)
  end

  @doc "`GET /loanproducts/template`"
  def template(conn) do
    q = conn.query_params
    Read.respond(conn, @resource, fn -> new_template() |> only_fields(q) end)
  end

  @doc "`GET /loanproducts/:id`"
  def show(conn, raw_id) do
    q = conn.query_params

    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> id |> one(q["template"] == "true") |> only_fields(q) end)
    end)
  end

  @doc "The loan product as `GET /loanproducts/:id` shows it."
  def detail(id), do: one(id, false)

  defp one(id, template?) do
    with {:ok, product} <- LoanProducts.get(id) do
      body =
        product
        |> product_json()
        |> Map.put("charges", Enum.map(CatalogCharges.for_loan_product(id), &charge/1))
        |> with_accounting(product)

      # a read for a form carries the choices instead of the (empty) list of delinquency buckets
      if template?,
        do: Map.merge(body, template_options()),
        else: Map.put(body, "delinquencyBucketOptions", [])
    end
  end

  @doc "`POST /loanproducts`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /loanproducts/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "Fineract has no delete for a loan product; its web container answers a plain 405."
  def method_not_allowed(conn), do: ECBApiFineract.Errors.spring(conn, 405, "Method Not Allowed")

  # --- one product ------------------------------------------------------------------------------

  defp product_json(p) do
    LoanProducts.static()["one_static"]
    |> with_dates(p)
    |> Map.merge(%{
      "id" => p.id,
      "name" => p.name,
      "shortName" => p.short_name,
      "description" => p.description,
      "fundId" => p.fund_id,
      "fundName" => p.fund_name,
      "externalId" => p.external_id,
      "includeInBorrowerCycle" => p.include_in_borrower_cycle == true,
      "useBorrowerCycle" => p.use_borrower_cycle == true,
      "status" => status(p),
      "currency" => Charges.currency(p.currency),
      "principal" => p.principal,
      "minPrincipal" => p.min_principal,
      "maxPrincipal" => p.max_principal,
      "numberOfRepayments" => p.number_of_repayments,
      "minNumberOfRepayments" => p.min_number_of_repayments,
      "maxNumberOfRepayments" => p.max_number_of_repayments,
      "repaymentEvery" => p.repay_every,
      "repaymentFrequencyType" => option(p.repayment_frequency),
      "interestRatePerPeriod" => p.interest_rate,
      "minInterestRatePerPeriod" => p.min_interest_rate,
      "maxInterestRatePerPeriod" => p.max_interest_rate,
      "interestRateFrequencyType" => option(p.interest_frequency),
      "annualInterestRate" => p.annual_interest_rate,
      "amortizationType" => option(p.amortization),
      "interestType" => option(p.interest_type),
      "interestCalculationPeriodType" => option(p.interest_period),
      "allowPartialPeriodInterestCalculation" => p.allow_partial_period == true,
      "inArrearsTolerance" => p.in_arrears_tolerance,
      "transactionProcessingStrategyCode" => p.strategy_code,
      "transactionProcessingStrategyName" => p.strategy_name,
      "graceOnPrincipalPayment" => p.grace_on_principal,
      "graceOnInterestPayment" => p.grace_on_interest,
      "graceOnInterestCharged" => p.grace_on_interest_charged,
      "graceOnArrearsAgeing" => p.grace_on_arrears_ageing,
      "overdueDaysForNPA" => p.overdue_days_for_npa,
      "daysInMonthType" => option(p.days_in_month),
      "daysInYearType" => option(p.days_in_year),
      "minimumDaysBetweenDisbursalAndFirstRepayment" =>
        p.min_days_between_disbursal_and_first_repayment,
      "canDefineInstallmentAmount" => p.can_define_installment_amount == true,
      "installmentAmountInMultiplesOf" => p.installment_amount_in_multiples_of,
      "repaymentStartDateType" => option(p.repayment_start),
      "accountingRule" => option(p.accounting),
      "canUseForTopup" => p.can_use_for_topup == true,
      "enableAccrualActivityPosting" => p.enable_accrual_activity_posting == true,
      "principalThresholdForLastInstallment" => p.principal_threshold_for_last_installment,
      "holdGuaranteeFunds" => p.hold_guarantee_funds == true,
      "accountMovesOutOfNPAOnlyOnArrearsCompletion" => p.account_moves_out_of_npa == true,
      "dueDaysForRepaymentEvent" => p.due_days_for_repayment_event,
      "overDueDaysForRepaymentEvent" => p.overdue_days_for_repayment_event,
      "syncExpectedWithDisbursementDate" => p.sync_expected_with_disbursement_date == true,
      "multiDisburseLoan" => p.multi_disburse == true,
      "maxTrancheCount" => p.max_tranche_count || 0,
      "outstandingLoanBalance" => p.outstanding_loan_balance,
      "disallowExpectedDisbursements" => p.disallow_expected_disbursements == true
    })
  end

  defp status(%{close_date: nil}), do: "loanProduct.active"

  defp status(%{close_date: close}),
    do:
      if(Date.compare(close, ECBPlatform.BusinessDate.current()) == :lt,
        do: "loanProduct.inActive",
        else: "loanProduct.active"
      )

  # Fineract leaves a date out of the product when it has none
  defp with_dates(body, p) do
    body
    |> put_date("startDate", p.start_date)
    |> put_date("closeDate", p.close_date)
  end

  defp put_date(body, _key, nil), do: body
  defp put_date(body, key, date), do: Map.put(body, key, [date.year, date.month, date.day])

  defp option(nil), do: nil
  defp option(option), do: Read.option(option)

  # a charge as a product shows it: without the flag about overdue installments, which only the charge list has
  defp charge(c), do: c |> Charges.charge_json() |> Map.delete("overdueInstallmentCharge")

  # the accounts a product that keeps accounts in the ledger is mapped to
  defp with_accounting(body, product) do
    if LoanProducts.accounting?(product) do
      d = LoanProducts.accounting_details(product)

      body
      |> Map.put("accountingMappings", Map.new(d.mappings, &{&1.name, account(&1.account)}))
      |> Map.put(
        "paymentChannelToFundSourceMappings",
        d.payment_types && Enum.map(d.payment_types, &payment_mapping/1)
      )
      |> Map.put("feeToIncomeAccountMappings", d.fees && Enum.map(d.fees, &charge_mapping/1))
      |> Map.put(
        "penaltyToIncomeAccountMappings",
        d.penalties && Enum.map(d.penalties, &charge_mapping/1)
      )
    else
      body
    end
  end

  defp account(a), do: %{"id" => a.id, "name" => a.name, "glCode" => a.gl_code}

  defp payment_mapping(m),
    do: %{
      "paymentType" => %{"id" => m.payment_type.id, "name" => m.payment_type.name},
      "fundSourceAccount" => account(m.account)
    }

  defp charge_mapping(m),
    do: %{
      "charge" => %{
        "id" => m.charge.id,
        "name" => m.charge.name,
        "active" => false,
        "penalty" => m.charge.penalty,
        "freeWithdrawal" => false,
        "isPaymentType" => false
      },
      "incomeAccount" => account(m.account)
    }

  # --- the template ---------------------------------------------------------------------------

  defp new_template, do: Map.merge(LoanProducts.static()["template_static"], template_options())

  defp template_options do
    static = LoanProducts.static()["template_static"]

    option_keys =
      for {key, _} <- static,
          String.ends_with?(key, "Options") or String.ends_with?(key, "Types"),
          do: key

    static
    |> Map.take(option_keys)
    |> Map.merge(%{
      "fundOptions" => Enum.map(Funds.list(), &%{"id" => &1.id, "name" => &1.name}),
      "paymentTypeOptions" => Enum.map(OrgPaymentTypes.list(), &PaymentTypes.serialize/1),
      "currencyOptions" => Enum.map(Currencies.list().selected, &Charges.currency/1),
      "chargeOptions" =>
        none_if_empty(Enum.map(CatalogCharges.applicable_to_loans(false), &charge/1)),
      "penaltyOptions" =>
        none_if_empty(Enum.map(CatalogCharges.applicable_to_loans(true), &charge/1)),
      "accountingMappingOptions" => account_options(),
      "floatingRateOptions" => [],
      "writeOffReasonOptions" => code_values("WriteOffReasons"),
      "chargeOffReasonOptions" => code_values("ChargeOffReasons"),
      "capitalizedIncomeClassificationOptions" =>
        code_values("capitalized_income_transaction_classification"),
      "buydownFeeClassificationOptions" => code_values("buydown_fee_transaction_classification")
    })
  end

  defp none_if_empty([]), do: nil
  defp none_if_empty(list), do: list

  @doc "The values of the code named `name`, as Fineract's code value data."
  @spec code_values(String.t()) :: [map]
  def code_values(name) do
    case Codes.get_by_name(name) do
      {:ok, code} ->
        Enum.map(Codes.values(code.id), fn v ->
          %{
            "id" => v.id,
            "name" => v.name,
            "position" => v.position,
            "description" => v.description,
            "active" => v.active,
            "mandatory" => v.mandatory
          }
        end)

      {:error, _} ->
        []
    end
  end

  # the accounts a product can be mapped to, by kind, leaving out a kind that has none
  defp account_options do
    for {key, type} <- [
          {"assetAccountOptions", 1},
          {"liabilityAccountOptions", 2},
          {"equityAccountOptions", 3},
          {"incomeAccountOptions", 4},
          {"expenseAccountOptions", 5}
        ],
        accounts = Ledger.list(type: type, usage: 1, disabled: false),
        accounts != [],
        into: %{},
        do: {key, Enum.map(accounts, &GLAccounts.account_json/1)}
  end

  # --- `fields` -------------------------------------------------------------------------------

  defp only_fields({:error, _} = error, _q), do: error

  defp only_fields(body, q) do
    case q["fields"] do
      fields when is_binary(fields) and fields != "" ->
        wanted = fields |> String.split(",") |> Enum.map(&String.trim/1)

        case Enum.reject(wanted, &(&1 in @choosable)) do
          [] -> filter(body, MapSet.new(@choosable -- wanted))
          unknown -> {:error, %ECBPlatform.Errors.UnsupportedParameter{parameters: unknown}}
        end

      _ ->
        body
    end
  end

  # A field Fineract lets `fields` choose between is dropped unless asked for, at every depth (the filter is
  # by name, so a nested `id` or `name` goes too); every other field stays.
  defp filter(list, drop) when is_list(list), do: Enum.map(list, &filter(&1, drop))

  defp filter(map, drop) when is_map(map) and not is_struct(map) do
    for {key, value} <- map,
        not MapSet.member?(drop, key),
        into: %{},
        do: {key, filter(value, drop)}
  end

  defp filter(other, _drop), do: other
end
