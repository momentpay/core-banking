defmodule ECBApiFineract.Resources.Taxes do
  @moduledoc """
  `/v1/taxes/component` and `/v1/taxes/group`: the taxes charges and savings products can apply.

  A *component* is a named percentage (with, optionally, a pair of GL accounts the tax is posted between);
  a *group* collects components for stretches of time. Both have a list, one record, a template for forms,
  create and update; there is no delete. Reading needs `READ_TAXCOMPONENT` or `READ_TAXGROUP`. Dates are
  sent as `2025-01-01` text in what is read and as `[2025, 1, 1]` in what a write reports, as Fineract does.
  """
  alias ECBApiFineract.Resources.{GLAccounts, Read, Write}
  alias ECBCatalog.Taxes
  alias ECBLedger.FinancialActivities
  alias ECBLedger.GLAccounts, as: Accounts
  alias ECBPlatform.BusinessDate

  @component "TAXCOMPONENT"
  @group "TAXGROUP"

  # --- components -----------------------------------------------------------------------------

  @doc "`GET /taxes/component`"
  def components(conn),
    do: Read.respond(conn, @component, fn -> Enum.map(Taxes.components(), &component_json/1) end)

  @doc "`GET /taxes/component/template`"
  def component_template(conn) do
    Read.respond(conn, @component, fn ->
      %{
        "glAccountOptions" =>
          for({type, list} <- FinancialActivities.account_options(), into: %{}) do
            {"#{type}AccountOptions", Enum.map(list, &GLAccounts.account_json/1)}
          end,
        "glAccountTypeOptions" => Enum.map(Accounts.type_options(), &Read.option/1)
      }
    end)
  end

  @doc "`GET /taxes/component/:id`"
  def component(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @component, fn -> one_component(id) end)
    end)
  end

  defp one_component(id) do
    with {:ok, component} <- Taxes.get_component(id), do: component_json(component)
  end

  @doc "`POST /taxes/component`"
  def create_component(conn), do: Write.execute(conn, @component, "CREATE")

  @doc "`PUT /taxes/component/:id`"
  def update_component(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @component, "UPDATE", id: &1))

  # --- groups ---------------------------------------------------------------------------------

  @doc "`GET /taxes/group`"
  def groups(conn),
    do: Read.respond(conn, @group, fn -> Enum.map(Taxes.groups(), &group_json(&1, [])) end)

  @doc "`GET /taxes/group/template`"
  def group_template(conn),
    do:
      Read.respond(conn, @group, fn ->
        %{"taxComponents" => Enum.map(Taxes.components(), &component_json/1)}
      end)

  @doc "`GET /taxes/group/:id` (`?template=true` adds what a form needs)"
  def group(conn, raw_id) do
    template? = conn.query_params["template"] == "true"

    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @group, fn -> one_group(id, template?) end)
    end)
  end

  defp one_group(id, template?) do
    with {:ok, group} <- Taxes.get_group(id) do
      if template? do
        editable? = not Taxes.linked?(id)
        today = BusinessDate.current()

        group_json(group, [:today, {:template, editable?, today}])
      else
        group_json(group, [:today])
      end
    end
  end

  @doc "`POST /taxes/group`"
  def create_group(conn), do: Write.execute(conn, @group, "CREATE")

  @doc "`PUT /taxes/group/:id`"
  def update_group(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @group, "UPDATE", id: &1))

  # --- serialising ----------------------------------------------------------------------------

  # The accounts are shown with the type's own id, code and name; Fineract shows the type one place along
  # the list and the code as its name.
  defp component_json(c) do
    %{
      "id" => c.id,
      "name" => c.name,
      "percentage" => c.percentage,
      "debitAccountType" => c.debit_type && Read.option(Accounts.type_option(c.debit_type)),
      "debitAccount" => c.debit_account && account(c.debit_account),
      "creditAccountType" => c.credit_type && Read.option(Accounts.type_option(c.credit_type)),
      "creditAccount" => c.credit_account && account(c.credit_account),
      "startDate" => Date.to_iso8601(c.start_date)
    }
  end

  defp account(account), do: account |> GLAccounts.account_json() |> Map.delete("tagId")

  @doc "A group as the list shows it (and as a charge's template offers it)."
  def group_json(group), do: group_json(group, [])

  defp group_json(group, options) do
    template = Enum.find(options, &match?({:template, _, _}, &1))
    editable? = template && elem(template, 1)
    today = template && elem(template, 2)

    %{
      "id" => group.id,
      "name" => group.name,
      "taxAssociations" => Enum.map(group.associations, &association(&1, editable?, today))
    }
    |> maybe_business_date(:today in options)
    |> maybe_template(template)
  end

  defp association(a, editable?, today) do
    %{
      "id" => a.id,
      "taxComponent" => component_json(a.component),
      "startDate" => Date.to_iso8601(a.start_date),
      "endDate" => a.end_date && Date.to_iso8601(a.end_date)
    }
    |> maybe_component_editable(editable?, a, today)
  end

  # a component can be re-dated while its group is free of charges and products and it has not started
  defp maybe_component_editable(map, nil, _a, _today), do: map

  defp maybe_component_editable(map, editable?, a, today),
    do:
      Map.put(
        map,
        "componentEditable",
        editable? and Date.compare(a.start_date, today) == :gt
      )

  defp maybe_business_date(map, true),
    do: Map.put(map, "businessDate", Date.to_iso8601(BusinessDate.current()))

  defp maybe_business_date(map, false), do: map

  defp maybe_template(map, nil), do: map

  defp maybe_template(map, {:template, editable?, _today}),
    do:
      Map.merge(map, %{
        "taxComponents" => Enum.map(Taxes.components(), &component_json/1),
        "groupEditable" => editable?
      })
end
