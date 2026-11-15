defmodule ECBApiFineract.Resources.Charges do
  @moduledoc """
  `/v1/charges`: the fees and penalties products can apply: list (by name), one charge (`?template=true`
  adds the choices a form needs), the template for a new charge (`?chargeAppliesTo=5` narrows it to a
  working-capital loan charge, and `chargeTimeType` narrows its calculations), create, update and delete.
  Reading needs `READ_CHARGE`. A charge in a currency the organisation has not selected is not shown.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{GLAccounts, Read, Taxes, Write}
  alias ECBCatalog.Charges, as: Catalog
  alias ECBCatalog.Charges.Enums
  alias ECBCatalog.Taxes, as: CatalogTaxes
  alias ECBOrg.Currencies

  @resource "CHARGE"

  @doc "`GET /charges`"
  def index(conn),
    do: Read.respond(conn, @resource, fn -> Enum.map(Catalog.list(), &charge_json/1) end)

  @doc "`GET /charges/template`"
  def template(conn) do
    q = conn.query_params

    with {:ok, applies_to} <- query_long(q["chargeAppliesTo"]),
         {:ok, time} <- query_long(q["chargeTimeType"]) do
      Read.respond(conn, @resource, fn -> template_json(applies_to, time) end)
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "`GET /charges/:id`"
  def show(conn, raw_id) do
    with_template? = conn.query_params["template"] == "true"

    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> one(id, with_template?) end)
    end)
  end

  defp one(id, with_template?) do
    with {:ok, charge} <- Catalog.get(id) do
      body = charge_json(charge)

      if with_template?,
        do: Map.merge(template_json(charge.applies_to, charge.time), body),
        else: body
    end
  end

  @doc "`POST /charges`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /charges/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /charges/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  # a number the web container could not read in the query is its plain 404
  defp query_long(nil), do: {:ok, nil}
  defp query_long(""), do: {:ok, nil}

  defp query_long(text) do
    case Integer.parse(text) do
      {number, ""} -> {:ok, number}
      _ -> {:error, %Errors.PathNotFound{}}
    end
  end

  # --- one charge -----------------------------------------------------------------------------

  defp charge_json(c) do
    %{
      "id" => c.id,
      "name" => c.name,
      "active" => c.active,
      "penalty" => c.penalty,
      "freeWithdrawal" => c.free_withdrawal == true,
      "isPaymentType" => c.payment_type_enabled == true,
      "freeWithdrawalChargeFrequency" => c.free_withdrawal_frequency || 0,
      "restartFrequency" => c.restart_frequency || 0,
      "restartFrequencyEnum" => c.restart_frequency_enum || 0,
      "paymentTypeOptions" =>
        c.payment_type && %{"id" => c.payment_type.id, "name" => c.payment_type.name},
      "currency" => currency(c.currency),
      "amount" => c.amount,
      "chargeTimeType" => option(Enums.time(c.time)),
      "chargeAppliesTo" => option(Enums.applies_to(c.applies_to)),
      "chargeCalculationType" => option(Enums.calculation(c.calculation)),
      "chargePaymentMode" => option(Enums.payment_mode(c.payment_mode || 0)),
      "feeOnMonthDay" => month_day(c),
      "feeInterval" => c.fee_interval,
      "minCap" => c.min_cap,
      "maxCap" => c.max_cap,
      "feeFrequency" => c.fee_frequency && option(Enums.fee_frequency(c.fee_frequency)),
      "incomeOrLiabilityAccount" =>
        c.account &&
          %{"id" => c.account.id, "name" => c.account.name, "glCode" => c.account.gl_code},
      "taxGroup" => c.tax_group && %{"id" => c.tax_group.id, "name" => c.tax_group.name},
      "overdueInstallmentCharge" => c.time == 9
    }
  end

  # the day a monthly or annual fee falls on, as `--03-15`
  defp month_day(%{fee_on_month: month, fee_on_day: day})
       when not is_nil(month) and not is_nil(day),
       do: "--" <> pad(month) <> "-" <> pad(day)

  defp month_day(_charge), do: nil

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp option(nil), do: nil
  defp option(option), do: Read.option(option)

  defp currency(c) do
    %{
      "code" => c.code,
      "name" => c.name,
      "decimalPlaces" => c.decimal_places,
      "inMultiplesOf" => c.multiples_of,
      "displaySymbol" => if(c.display_symbol in [nil, ""], do: nil, else: c.display_symbol),
      "nameCode" => c.name_code,
      "displayLabel" => Currencies.display_label(c.name, c.code, c.display_symbol)
    }
  end

  # --- the template ---------------------------------------------------------------------------

  defp template_json(applies_to, time) do
    t = Catalog.template(applies_to, time)

    base = %{
      "active" => false,
      "penalty" => false,
      "freeWithdrawal" => false,
      "isPaymentType" => false,
      "overdueInstallmentCharge" => false,
      "currencyOptions" => Enum.map(t.currencies, &currency/1),
      "chargeCalculationTypeOptions" => options(t.calculations),
      "chargeAppliesToOptions" => options(t.applies_to),
      "chargeTimeTypeOptions" => options(t.times),
      "chargePaymetModeOptions" => options(t.payment_modes)
    }

    if t.working_capital?, do: base, else: Map.merge(base, product_options(t))
  end

  defp product_options(t) do
    %{
      "loanChargeCalculationTypeOptions" => options(t.loan_calculations),
      "loanChargeTimeTypeOptions" => options(t.loan_times),
      "savingsChargeCalculationTypeOptions" => options(t.savings_calculations),
      "savingsChargeTimeTypeOptions" => options(t.savings_times),
      "clientChargeCalculationTypeOptions" => options(t.client_calculations),
      "clientChargeTimeTypeOptions" => options(t.client_times),
      "shareChargeCalculationTypeOptions" => options(t.share_calculations),
      "shareChargeTimeTypeOptions" => options(t.share_times),
      "feeFrequencyOptions" => options(t.fee_frequencies),
      "incomeOrLiabilityAccountOptions" =>
        for({type, list} <- t.income_or_liability_accounts, into: %{}) do
          {"#{type}AccountOptions", Enum.map(list, &GLAccounts.account_json/1)}
        end,
      "taxGroupOptions" => Enum.map(CatalogTaxes.groups(), &Taxes.group_json/1),
      "accountMappingForChargeConfig" => t.account_mapping,
      "expenseAccountOptions" => Enum.map(t.expense_accounts, &GLAccounts.account_json/1),
      "assetAccountOptions" => Enum.map(t.asset_accounts, &GLAccounts.account_json/1)
    }
  end

  defp options(list), do: Enum.map(list, &Read.option/1)
end
