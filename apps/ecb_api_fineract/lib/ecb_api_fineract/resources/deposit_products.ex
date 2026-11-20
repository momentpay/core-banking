defmodule ECBApiFineract.Resources.DepositProducts do
  @moduledoc """
  `/v1/fixeddepositproducts` and `/v1/recurringdepositproducts`: the templates fixed and recurring deposits are opened
  from. List, one product (with its charges, interest rate charts and the chart in force; `?template=true` adds the
  choices a form needs), the template for a new product, create, update and delete. Reading needs
  `READ_FIXEDDEPOSITPRODUCT` (or `READ_RECURRINGDEPOSITPRODUCT`).
  """
  alias ECBApiFineract.Resources.{Charges, Read, SavingsProducts, Write}
  alias ECBCatalog.Charges, as: CatalogCharges
  alias ECBDeposits.{DepositEnums, DepositProducts, InterestCharts, SavingsEnums}
  alias ECBOrg.Currencies
  alias ECBParty.Clients.Options

  @resources %{fixed: "FIXEDDEPOSITPRODUCT", recurring: "RECURRINGDEPOSITPRODUCT"}

  @doc "`GET /fixeddepositproducts`"
  def index(conn, kind) do
    Read.respond(conn, @resources[kind], fn ->
      kind |> DepositProducts.list() |> Enum.map(&product_json(&1, kind))
    end)
  end

  @doc "`GET /fixeddepositproducts/template`"
  def template(conn, kind), do: Read.respond(conn, @resources[kind], fn -> new_template(kind) end)

  @doc "`GET /fixeddepositproducts/:id`"
  def show(conn, kind, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resources[kind], fn ->
        id |> one(kind) |> with_template(kind, conn.query_params["template"] == "true")
      end)
    end)
  end

  defp with_template(body, kind, true), do: Map.merge(body, template_options(kind))
  defp with_template(body, _kind, false), do: body

  defp one(id, kind) do
    product = DepositProducts.fetch!(kind, id)
    charts = DepositProducts.charts(id)
    shown = Enum.map(charts, &chart_json(&1, product, true))

    product
    |> product_json(kind)
    |> Map.put(
      "charges",
      Enum.map(CatalogCharges.for_savings_product(id), &SavingsProducts.charge/1)
    )
    |> Map.put("interestRateCharts", shown)
    |> Map.put("activeChart", active_chart(charts, product))
    |> SavingsProducts.with_accounting(product)
  end

  defp active_chart(charts, product) do
    case InterestCharts.active(charts) do
      nil -> nil
      chart -> chart_json(chart, product, true)
    end
  end

  @doc "`POST /fixeddepositproducts`"
  def create(conn, kind), do: Write.execute(conn, entity(kind), "CREATE")

  @doc "`PUT /fixeddepositproducts/:id`"
  def update(conn, kind, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, entity(kind), "UPDATE", id: &1))

  @doc "`DELETE /fixeddepositproducts/:id`"
  def delete(conn, kind, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, entity(kind), "DELETE", id: &1))

  defp entity(kind), do: @resources[kind]

  # --- one product ------------------------------------------------------------------------------

  defp product_json(p, kind) do
    %{
      "preClosurePenalApplicable" => p[:pre_closure_penal_applicable] == true,
      "preClosurePenalInterest" => p[:pre_closure_penal_interest],
      "preClosurePenalInterestOnType" =>
        option(DepositEnums.pre_closure_on(p[:pre_closure_penal_interest_on])),
      "minDepositTerm" => p[:min_deposit_term],
      "maxDepositTerm" => p[:max_deposit_term],
      "minDepositTermType" => option(DepositEnums.term_unit(p[:min_deposit_term_type])),
      "maxDepositTermType" => option(DepositEnums.term_unit(p[:max_deposit_term_type])),
      "inMultiplesOfDepositTerm" => p[:in_multiples_of_deposit_term],
      "inMultiplesOfDepositTermType" =>
        option(DepositEnums.term_unit(p[:in_multiples_of_deposit_term_type])),
      "minDepositAmount" => p[:min_deposit_amount],
      "depositAmount" => p[:deposit_amount],
      "maxDepositAmount" => p[:max_deposit_amount],
      "id" => p.id,
      "name" => p.name,
      "shortName" => p.short_name,
      "description" => p.description,
      "currency" => Charges.currency(p.currency),
      "nominalAnnualInterestRate" => p.nominal_annual_interest_rate,
      "interestCompoundingPeriodType" => SavingsProducts.option(p.compounding),
      "interestPostingPeriodType" => SavingsProducts.option(p.posting),
      "interestCalculationType" => SavingsProducts.option(p.calculation),
      "interestCalculationDaysInYearType" => SavingsProducts.option(p.days_in_year),
      "lockinPeriodFrequency" => p.lockin_period_frequency,
      "lockinPeriodFrequencyType" => SavingsProducts.option(p.lockin_type),
      "withHoldTax" => p.withhold_tax == true,
      "taxGroup" => p.tax_group && %{"id" => p.tax_group.id, "name" => p.tax_group.name},
      "accountingRule" => SavingsProducts.option(p.accounting)
    }
    |> recurring(p, kind)
  end

  defp recurring(json, p, :recurring) do
    Map.merge(json, %{
      "isMandatoryDeposit" => p[:is_mandatory],
      "allowWithdrawal" => p[:allow_withdrawal],
      "adjustAdvanceTowardsFuturePayments" => p[:adjust_advance_towards_future_payments]
    })
  end

  defp recurring(json, _p, :fixed), do: json

  defp option(nil), do: nil
  defp option(option), do: Read.option(option)

  # --- a chart ------------------------------------------------------------------------------------

  defp chart_json(chart, product, with_template?) do
    base = %{
      "id" => chart.id,
      "name" => chart.name,
      "description" => chart.description,
      "fromDate" => chart.from_date,
      "endDate" => chart.end_date,
      "productId" => product.id,
      "productName" => product.name,
      "isPrimaryGroupingByAmount" => chart.grouping == true,
      "chartSlabs" => Enum.map(chart.slabs, &slab_json/1)
    }

    if with_template?, do: Map.merge(base, chart_options()), else: base
  end

  defp slab_json(slab) do
    base = %{
      "id" => slab.id,
      "description" => slab.description,
      "periodType" => option(DepositEnums.chart_period(slab.period_type)),
      "fromPeriod" => slab.from_period,
      "toPeriod" => slab.to_period,
      "amountRangeFrom" => slab.amount_from,
      "amountRangeTo" => slab.amount_to,
      "annualInterestRate" => slab.rate,
      "currency" => slab_currency(slab.currency_code)
    }

    if slab.incentives == [],
      do: base,
      else: Map.put(base, "incentives", Enum.map(slab.incentives, &incentive_json/1))
  end

  defp incentive_json(i) do
    %{
      "id" => i.id,
      "entityType" => option(DepositEnums.incentive_entity(i.entity)),
      "attributeName" => option(DepositEnums.incentive_attribute(i.attribute)),
      "conditionType" => option(DepositEnums.incentive_condition(i.condition)),
      "attributeValue" => i.value,
      "attributeValueDesc" => i.value_desc,
      "incentiveType" => option(DepositEnums.incentive_type(i.type)),
      "amount" => i.amount
    }
  end

  defp slab_currency(code) do
    case Enum.find(Currencies.list().selected ++ Currencies.list().available, &(&1.code == code)) do
      nil -> nil
      currency -> Charges.currency(currency)
    end
  end

  # the choices that come with a chart
  defp chart_options do
    %{
      "periodTypes" => options(DepositEnums.chart_periods()),
      "entityTypeOptions" => options(DepositEnums.incentive_entities()),
      "attributeNameOptions" => options(DepositEnums.incentive_attributes()),
      "conditionTypeOptions" => options(DepositEnums.incentive_conditions()),
      "incentiveTypeOptions" => options(DepositEnums.incentive_types()),
      "genderOptions" => values("Gender"),
      "clientTypeOptions" => values("ClientType"),
      "clientClassificationOptions" => values("ClientClassification")
    }
  end

  defp options(list), do: Enum.map(list, &Read.option/1)

  defp values(name), do: Enum.map(Options.code_values(name), &code_value/1)

  defp code_value(v) do
    %{
      "id" => v.id,
      "name" => v.name,
      "position" => v.position,
      "description" => v.description,
      "active" => v.active,
      "mandatory" => v.mandatory
    }
  end

  # --- the template -------------------------------------------------------------------------------

  defp new_template(kind) do
    currency =
      case Currencies.list().selected do
        [only] -> Charges.currency(only)
        _ -> SavingsProducts.blank_currency()
      end

    Map.merge(
      %{
        "preClosurePenalApplicable" => false,
        "currency" => currency,
        "interestCompoundingPeriodType" => SavingsProducts.option(SavingsEnums.compounding(1)),
        "interestPostingPeriodType" => SavingsProducts.option(SavingsEnums.posting(4)),
        "interestCalculationType" => SavingsProducts.option(SavingsEnums.calculation(1)),
        "interestCalculationDaysInYearType" =>
          SavingsProducts.option(SavingsEnums.days_in_year(365)),
        "withHoldTax" => false,
        "accountingRule" => SavingsProducts.option(SavingsEnums.accounting(1))
      },
      template_options(kind)
    )
    |> recurring_template(kind)
  end

  defp recurring_template(json, :recurring) do
    Map.merge(json, %{
      "isMandatoryDeposit" => false,
      "allowWithdrawal" => false,
      "adjustAdvanceTowardsFuturePayments" => false
    })
  end

  defp recurring_template(json, :fixed), do: json

  # a deposit product offers the fees only; its penalties are listed apart
  defp fee_charge_options do
    case CatalogCharges.applicable_to_savings(true) do
      [] -> nil
      charges -> Enum.map(charges, &SavingsProducts.charge/1)
    end
  end

  defp template_options(_kind) do
    SavingsProducts.template_options()
    |> Map.delete("accountMappingForPayment")
    |> Map.put("chargeOptions", fee_charge_options())
    |> Map.merge(%{
      "preClosurePenalInterestOnTypeOptions" => options(DepositEnums.pre_closure_on()),
      "periodFrequencyTypeOptions" => options(DepositEnums.frequency_options()),
      "chartTemplate" =>
        Map.merge(%{"isPrimaryGroupingByAmount" => false, "chartSlabs" => []}, chart_options())
    })
  end
end
