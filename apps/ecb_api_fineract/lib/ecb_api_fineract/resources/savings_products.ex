defmodule ECBApiFineract.Resources.SavingsProducts do
  @moduledoc """
  `/v1/savingsproducts`: the templates savings accounts are opened from. List, one product (with its
  charges and, when it keeps accounts in the ledger, the accounts its money goes to; `?template=true` adds the
  choices a form needs), the template for a new product, create, update and delete. Reading needs
  `READ_SAVINGSPRODUCT`.
  """
  alias ECBApiFineract.Resources.{Charges, GLAccounts, PaymentTypes, Read, Taxes, Write}
  alias ECBCatalog.Charges, as: CatalogCharges
  alias ECBCatalog.Taxes, as: CatalogTaxes
  alias ECBDeposits.{SavingsEnums, SavingsProducts}
  alias ECBLedger.GLAccounts, as: Ledger
  alias ECBOrg.Currencies
  alias ECBOrg.PaymentTypes, as: OrgPaymentTypes

  @resource "SAVINGSPRODUCT"

  # The names `fields` may ask for; Fineract refuses any other name in `fields`.
  @choosable ~w(id name shortName description currency digitsAfterDecimal inMultiplesOf
                nominalAnnualInterestRate interestCompoundingPeriodType interestPostingPeriodType
                interestCalculationType interestCalculationDaysInYearType minRequiredOpeningBalance
                lockinPeriodFrequency lockinPeriodFrequencyType withdrawalFeeAmount withdrawalFeeType
                withdrawalFeeForTransfers feeAmount feeOnMonthDay currencyOptions
                interestCompoundingPeriodTypeOptions interestPostingPeriodTypeOptions
                interestCalculationTypeOptions interestCalculationDaysInYearTypeOptions
                lockinPeriodFrequencyTypeOptions withdrawalFeeTypeOptions
                nominalAnnualInterestRateOverdraft minOverdraftForInterestCalculation withHoldTax
                taxGroupId isDormancyTrackingActive daysToInactive daysToDormancy
                accountMappingForPayment)

  @doc "`GET /savingsproducts`"
  def index(conn) do
    q = conn.query_params

    Read.respond(conn, @resource, fn ->
      SavingsProducts.list() |> Enum.map(&product_json/1) |> only_fields(q)
    end)
  end

  @doc "`GET /savingsproducts/template`"
  def template(conn) do
    q = conn.query_params
    Read.respond(conn, @resource, fn -> new_template() |> only_fields(q) end)
  end

  @doc "`GET /savingsproducts/:id`"
  def show(conn, raw_id) do
    q = conn.query_params

    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> id |> one(q["template"] == "true") |> only_fields(q) end)
    end)
  end

  defp one(id, template?) do
    with {:ok, product} <- SavingsProducts.get(id) do
      body =
        product
        |> product_json()
        |> Map.put(
          "charges",
          Enum.map(CatalogCharges.for_savings_product(id), &charge/1)
        )
        |> with_accounting(product)

      if template?, do: Map.merge(body, template_options()), else: body
    end
  end

  @doc "`POST /savingsproducts`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /savingsproducts/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /savingsproducts/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  # --- one product ------------------------------------------------------------------------------

  defp product_json(p) do
    %{
      "id" => p.id,
      "name" => p.name,
      "shortName" => p.short_name,
      "description" => p.description,
      "currency" => currency(p.currency),
      "nominalAnnualInterestRate" => p.nominal_annual_interest_rate,
      "interestCompoundingPeriodType" => option(p.compounding),
      "interestPostingPeriodType" => option(p.posting),
      "interestCalculationType" => option(p.calculation),
      "interestCalculationDaysInYearType" => option(p.days_in_year),
      "minRequiredOpeningBalance" => p.min_required_opening_balance,
      "lockinPeriodFrequency" => p.lockin_period_frequency,
      "lockinPeriodFrequencyType" => option(p.lockin_type),
      "withdrawalFeeForTransfers" => p.withdrawal_fee_for_transfers == true,
      "allowOverdraft" => p.allow_overdraft == true,
      "overdraftLimit" => p.overdraft_limit,
      "minRequiredBalance" => p.min_required_balance,
      "enforceMinRequiredBalance" => p.enforce_min_required_balance == true,
      "maxAllowedLienLimit" => p.max_allowed_lien_limit,
      "lienAllowed" => p.lien_allowed == true,
      "nominalAnnualInterestRateOverdraft" => p.nominal_annual_interest_rate_overdraft,
      "minOverdraftForInterestCalculation" => p.min_overdraft_for_interest_calculation,
      "minBalanceForInterestCalculation" => p.min_balance_for_interest_calculation,
      "withHoldTax" => p.withhold_tax == true,
      "taxGroup" => p.tax_group && %{"id" => p.tax_group.id, "name" => p.tax_group.name},
      "accountingRule" => option(p.accounting),
      "isDormancyTrackingActive" => p.dormancy_tracking_active == true,
      "daysToInactive" => p.days_to_inactive,
      "daysToDormancy" => p.days_to_dormancy,
      "daysToEscheat" => p.days_to_escheat
    }
  end

  defp option(nil), do: nil
  defp option(option), do: Read.option(option)

  defp currency(c), do: Charges.currency(c)

  # a charge as a product shows it: without the flag about overdue installments, which only loans have
  defp charge(c), do: c |> Charges.charge_json() |> Map.delete("overdueInstallmentCharge")

  # the accounts a product that keeps accounts in the ledger is mapped to
  defp with_accounting(body, product) do
    if SavingsProducts.accounting?(product) do
      d = SavingsProducts.accounting_details(product)

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

  # the charge here is shown as Fineract builds it for a mapping: whether it is active is not read
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

  defp new_template do
    currency =
      case Currencies.list().selected do
        [only] -> Charges.currency(only)
        _ -> blank_currency()
      end

    Map.merge(
      %{
        "currency" => currency,
        "interestCompoundingPeriodType" => option(SavingsEnums.compounding(1)),
        "interestPostingPeriodType" => option(SavingsEnums.posting(4)),
        "interestCalculationType" => option(SavingsEnums.calculation(1)),
        "interestCalculationDaysInYearType" => option(SavingsEnums.days_in_year(365)),
        "withdrawalFeeForTransfers" => false,
        "allowOverdraft" => false,
        "enforceMinRequiredBalance" => false,
        "lienAllowed" => false,
        "withHoldTax" => false,
        "accountingRule" => option(SavingsEnums.accounting(1)),
        "isDormancyTrackingActive" => false
      },
      template_options()
    )
  end

  defp blank_currency,
    do: %{
      "code" => "",
      "name" => "",
      "decimalPlaces" => 0,
      "inMultiplesOf" => 0,
      "displaySymbol" => "",
      "nameCode" => "",
      "displayLabel" => ""
    }

  defp template_options do
    %{
      "currencyOptions" => Enum.map(Currencies.list().selected, &Charges.currency/1),
      "interestCompoundingPeriodTypeOptions" => options(SavingsEnums.compounding()),
      "interestPostingPeriodTypeOptions" => options(SavingsEnums.posting()),
      "interestCalculationTypeOptions" => options(SavingsEnums.calculation()),
      "interestCalculationDaysInYearTypeOptions" => options(SavingsEnums.days_in_year()),
      "lockinPeriodFrequencyTypeOptions" => options(SavingsEnums.lockin()),
      "withdrawalFeeTypeOptions" => options(SavingsEnums.withdrawal_fee()),
      "paymentTypeOptions" => Enum.map(OrgPaymentTypes.list(), &PaymentTypes.serialize/1),
      "accountingRuleOptions" => options(SavingsEnums.accounting()),
      "accountingMappingOptions" => account_options(),
      "chargeOptions" =>
        none_if_empty(Enum.map(CatalogCharges.applicable_to_savings(false), &charge/1)),
      "penaltyOptions" => none_if_empty(Enum.map(CatalogCharges.savings_penalties(), &charge/1)),
      "taxGroupOptions" =>
        Enum.map(CatalogTaxes.groups(), &(&1 |> Taxes.group_json() |> dates_as_arrays())),
      "accountMappingForPayment" => account_mapping_for_payment()
    }
  end

  # Fineract writes the dates of a tax group inside a product as arrays, and as text on its own
  defp dates_as_arrays(%{__struct__: _} = struct), do: struct

  defp dates_as_arrays(%{} = map) do
    Map.new(map, fn
      {key, text} when key in ["startDate", "endDate"] and is_binary(text) ->
        {key, Date.from_iso8601!(text)}

      {key, value} ->
        {key, dates_as_arrays(value)}
    end)
  end

  defp dates_as_arrays(list) when is_list(list), do: Enum.map(list, &dates_as_arrays/1)
  defp dates_as_arrays(other), do: other

  defp none_if_empty([]), do: nil
  defp none_if_empty(list), do: list

  defp options(list), do: Enum.map(list, &Read.option/1)

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

  defp account_mapping_for_payment do
    case ECBPlatform.Configuration.get("account-mapping-for-payment-type") do
      %{enabled: true, string_value: value} when is_binary(value) -> value
      _ -> "Asset"
    end
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

  # a field Fineract lets `fields` choose between is dropped unless asked for; every other field stays
  defp filter(list, drop) when is_list(list), do: Enum.map(list, &filter(&1, drop))
  defp filter(map, drop), do: Map.reject(map, fn {key, _} -> MapSet.member?(drop, key) end)
end
