defmodule ECBApiFineract.Resources.AccountingRules do
  @moduledoc """
  `/v1/accountingrules`: the recipes for manual journal entries: list (of the user's office and below;
  `?associations=all` shows the accounts a tagged side allows instead of its tags), one rule, the template
  that lists the offices, accounts and tags to choose from (`?template=true` on a rule too), create, update
  and delete. Reading needs `READ_ACCOUNTINGRULE`.

  Fineract reads the body of a create or update into a fixed set of fields before anything else, so a
  field it does not know is dropped and one of the wrong kind is refused as "invalid JSON data" (a number
  that is not a number is refused with its own message).
  """
  alias ECBApiFineract.Resources.{GLAccounts, Read, Write}
  alias ECBLedger.AccountingRules
  alias ECBLedger.GLAccounts, as: Accounts
  alias ECBOrg.Offices
  alias ECBPlatform.Errors.{InvalidJsonData, InvalidNumber}
  alias ECBPlatform.Params

  @resource "ACCOUNTINGRULE"

  @doc "`GET /accountingrules`"
  def index(conn) do
    pattern = Offices.user_hierarchy_pattern(conn.assigns.current_user)
    associations? = associations_all?(conn.query_params["associations"])

    Read.respond(conn, @resource, fn ->
      pattern |> AccountingRules.list(associations?) |> Enum.map(&serialize/1)
    end)
  end

  @doc "`GET /accountingrules/template`"
  def template(conn) do
    Read.respond(conn, @resource, fn ->
      with_options(
        %{
          "systemDefined" => false,
          "allowMultipleDebitEntries" => false,
          "allowMultipleCreditEntries" => false
        },
        conn.assigns.current_user,
        nil,
        nil
      )
    end)
  end

  @doc "`GET /accountingrules/:id`"
  def show(conn, raw_id) do
    template? = conn.query_params["template"] == "true"
    user = conn.assigns.current_user

    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> one(id, template?, user) end)
    end)
  end

  defp one(id, template?, user) do
    with {:ok, rule} <- AccountingRules.get(id),
         do: if(template?, do: rule_template(rule, user), else: serialize(rule))
  end

  @doc "`POST /accountingrules`"
  def create(conn), do: typed(conn, fn -> Write.execute(conn, @resource, "CREATE") end)

  @doc "`PUT /accountingrules/:id`"
  def update(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      typed(conn, fn -> Write.execute(conn, @resource, "UPDATE", id: id) end)
    end)
  end

  @doc "`DELETE /accountingrules/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  # --- the typed body -------------------------------------------------------------------------

  # Runs `fun` once the body has been read the way Fineract's typed reader reads it.
  defp typed(conn, fun) do
    case check_types(conn.assigns[:raw_body]) do
      :ok -> fun.()
      {:error, error} -> ECBApiFineract.Errors.render(conn, error)
    end
  end

  defp check_types(body) do
    params = Params.parse_typed!(body)

    for key <- ~w(officeId accountToDebit accountToCredit), do: Params.long(params, key)

    for key <- ~w(allowMultipleCreditEntries allowMultipleDebitEntries),
        do: Params.strict_boolean(params, key)

    for key <- ~w(creditTags debitTags), do: check_tags(Params.value(params, key))
    :ok
  rescue
    error ->
      if ECBPlatform.Errors.to_api(error),
        do: {:error, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp check_tags(nil), do: :ok

  defp check_tags(list) when is_list(list), do: Enum.each(list, &check_tag/1)
  defp check_tags(_other), do: raise(InvalidJsonData)

  defp check_tag(tag) when is_integer(tag) or is_nil(tag), do: :ok

  defp check_tag(tag) when is_binary(tag) do
    case Integer.parse(String.trim(tag)) do
      {_number, ""} -> :ok
      _ -> raise InvalidNumber, parameter: nil, value: tag
    end
  end

  defp check_tag(_other), do: raise(InvalidJsonData)

  defp associations_all?(nil), do: false

  defp associations_all?(text),
    do: text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.member?("all")

  # --- serialising ----------------------------------------------------------------------------

  defp serialize(rule) do
    %{
      "id" => rule.id,
      "officeId" => rule.office_id,
      "officeName" => rule.office_name,
      "name" => rule.name,
      "description" => rule.description,
      "systemDefined" => rule.system_defined,
      "allowMultipleDebitEntries" => rule.allow_multiple_debits,
      "allowMultipleCreditEntries" => rule.allow_multiple_credits,
      "creditTags" => tags_json(rule.credit.tags),
      "debitTags" => tags_json(rule.debit.tags),
      "creditAccounts" => accounts_json(rule.credit.accounts),
      "debitAccounts" => accounts_json(rule.debit.accounts),
      "allowedOffices" => [],
      "allowedAccounts" => []
    }
  end

  defp tags_json(nil), do: nil

  defp tags_json(tags) do
    for t <- tags,
        do: %{
          "id" => t.id,
          "tag" => %{"id" => t.tag.id, "name" => t.tag.name},
          "transactionType" => Read.option(AccountingRules.side(t.side))
        }
  end

  defp accounts_json(nil), do: nil

  defp accounts_json(accounts),
    do: for(a <- accounts, do: %{"id" => a.id, "name" => a.name, "glCode" => a.gl_code})

  # A rule's own details with what a form needs to change them. The tags the rule already uses on a side
  # are left out of that side's options.
  defp rule_template(rule, user) do
    %{
      "id" => rule.id,
      "officeId" => rule.office_id,
      "officeName" => rule.office_name,
      "name" => rule.name,
      "description" => rule.description,
      "systemDefined" => rule.system_defined,
      "allowMultipleDebitEntries" => rule.allow_multiple_debits,
      "allowMultipleCreditEntries" => rule.allow_multiple_credits
    }
    |> with_options(user, rule.credit.tags, rule.debit.tags)
  end

  defp with_options(body, user, credit_tags, debit_tags) do
    options = tag_options()

    Map.merge(body, %{
      "allowedOffices" =>
        for(
          o <- Offices.template(user).allowed_parents,
          do: %{"id" => o.id, "name" => o.name, "nameDecorated" => o.name_decorated}
        ),
      "allowedAccounts" =>
        [disabled: false, usage: 1] |> Accounts.list() |> Enum.map(&GLAccounts.account_json/1),
      "allowedCreditTagOptions" => unselected(options, credit_tags),
      "allowedDebitTagOptions" => unselected(options, debit_tags)
    })
  end

  # every tag of every kind of account: assets, liabilities, equity, income, then expenses
  defp tag_options do
    tags = Accounts.tag_options()
    Enum.flat_map(~w(asset liability equity income expense)a, &Map.fetch!(tags, &1))
  end

  defp unselected(options, nil), do: Enum.map(options, &GLAccounts.tag_value_json/1)

  defp unselected(options, selected) do
    taken = MapSet.new(selected, & &1.tag.id)

    options
    |> Enum.reject(&MapSet.member?(taken, &1.id))
    |> Enum.map(&GLAccounts.tag_value_json/1)
  end
end
