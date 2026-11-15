defmodule ECBApiFineract.Resources.GLAccounts do
  @moduledoc """
  `/v1/glaccounts`: the chart of accounts: list (with filters), one account, the new-account template,
  create, update and delete. Reading needs `READ_GLACCOUNT`.

  List filters: `type` (1 to 5), `usage` (1 detail, 2 header), `manualEntriesAllowed`, `disabled`,
  `searchParam` (part of name or code). A single account or the template carries the form's options with
  `?template=true`.
  """
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBLedger.GLAccounts

  @doc "`GET /glaccounts`"
  def index(conn) do
    q = conn.query_params

    Read.respond(conn, "GLACCOUNT", fn ->
      filters = [
        type: Read.int_param(q, "type"),
        search: q["searchParam"],
        usage: Read.int_param(q, "usage"),
        manual_entries_allowed: bool(q["manualEntriesAllowed"]),
        disabled: bool(q["disabled"])
      ]

      Enum.map(GLAccounts.list(filters), &serialize/1)
    end)
  end

  @doc "`GET /glaccounts/template`"
  def template(conn) do
    type = Read.int_param(conn.query_params, "type")

    Read.respond(conn, "GLACCOUNT", fn ->
      GLAccounts.new_account(type) |> serialize() |> with_options()
    end)
  end

  @doc "`GET /glaccounts/:id`"
  def show(conn, raw_id) do
    with_options? = conn.query_params["template"] == "true"

    Read.respond(conn, "GLACCOUNT", fn ->
      with {:ok, id} <- Write.path_id(raw_id),
           {:ok, account} <- GLAccounts.get(id),
           do: account |> serialize() |> maybe_options(with_options?)
    end)
  end

  defp maybe_options(body, true), do: with_options(body)
  defp maybe_options(body, false), do: body

  @doc "`POST /glaccounts`"
  def create(conn), do: Write.execute(conn, "GLACCOUNT", "CREATE")

  @doc "`PUT /glaccounts/:id`"
  def update(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "GLACCOUNT", "UPDATE", id: &1)
      )

  @doc "`DELETE /glaccounts/:id`"
  def delete(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "GLACCOUNT", "DELETE", id: &1)
      )

  # --- serialising ----------------------------------------------------------------------------

  @doc "One account as Fineract's account JSON, for other resources that list accounts."
  def account_json(account), do: serialize(account)

  defp bool("true"), do: true
  defp bool("false"), do: false
  defp bool(_), do: nil

  defp serialize(a) do
    %{
      "id" => Map.get(a, :id),
      "name" => Map.get(a, :name),
      "parentId" => Map.get(a, :parent_id),
      "glCode" => Map.get(a, :gl_code),
      "disabled" => a.disabled,
      "manualEntriesAllowed" => a.manual_entries_allowed,
      "type" => Read.option(a.type),
      "usage" => Read.option(a.usage),
      "description" => if(Map.has_key?(a, :id), do: Map.get(a, :description) || "", else: nil),
      "nameDecorated" => Map.get(a, :name_decorated)
    }
    |> maybe_tag(Map.get(a, :tag), Map.has_key?(a, :id))
  end

  # A stored account shows `tagId` (`{"id": 0}` when it has none); the template's defaults show none.
  defp maybe_tag(body, nil, true), do: Map.put(body, "tagId", %{"id" => 0})
  defp maybe_tag(body, nil, false), do: body
  defp maybe_tag(body, tag, _), do: Map.put(body, "tagId", %{"id" => tag.id, "name" => tag.name})

  defp with_options(body) do
    tags = GLAccounts.tag_options()

    headers =
      for {type, key} <- [
            {1, "assetHeaderAccountOptions"},
            {2, "liabilityHeaderAccountOptions"},
            {3, "equityHeaderAccountOptions"},
            {4, "incomeHeaderAccountOptions"},
            {5, "expenseHeaderAccountOptions"}
          ],
          accounts = GLAccounts.header_accounts(type),
          accounts != [],
          into: %{},
          do: {key, Enum.map(accounts, &serialize/1)}

    body
    |> Map.merge(%{
      "accountTypeOptions" => Enum.map(GLAccounts.type_options(), &Read.option/1),
      "usageOptions" => Enum.map(GLAccounts.usage_options(), &Read.option/1),
      "allowedAssetsTagOptions" => tag_values(tags.asset),
      "allowedLiabilitiesTagOptions" => tag_values(tags.liability),
      "allowedEquityTagOptions" => tag_values(tags.equity),
      "allowedIncomeTagOptions" => tag_values(tags.income),
      "allowedExpensesTagOptions" => tag_values(tags.expense)
    })
    |> Map.merge(headers)
  end

  defp tag_values(values) do
    for v <- values do
      %{
        "id" => v.id,
        "name" => v.name,
        "position" => v.position,
        "description" => v.description,
        "active" => v.active,
        "mandatory" => v.mandatory
      }
    end
  end
end
