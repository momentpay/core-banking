defmodule ECBApiFineract.Resources.Provisioning do
  @moduledoc """
  `/v1/provisioningcategory`, `/v1/provisioningcriteria` and `/v1/provisioningentries`: loan provisioning.

  Categories can be listed, added, renamed and deleted. Criteria can be listed and read, with the template
  a form needs; entries can be listed. Defining criteria and making entries need loan products and loans,
  so they answer "not implemented" until those exist. Fineract lets any signed-in user read these; changing
  a category needs `CREATE_PROVISIONCATEGORY`, `UPDATE_PROVISIONCATEGORY` or `DELETE_PROVISIONCATEGORY`.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBApiFineract.Resources.{GLAccounts, Write}
  alias ECBLedger.Provisioning.{Categories, Criteria}

  @resource "PROVISIONCATEGORY"

  # --- categories -----------------------------------------------------------------------------

  @doc "`GET /provisioningcategory`"
  def categories(conn) do
    answer(conn, fn ->
      for c <- Categories.list(),
          do: %{"id" => c.id, "categoryName" => c.name, "categoryDescription" => c.description}
    end)
  end

  @doc "`POST /provisioningcategory`"
  def create_category(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /provisioningcategory/:id`"
  def update_category(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /provisioningcategory/:id`"
  def delete_category(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  @doc "A route Fineract has for other methods only is its web container's plain 405."
  def method_not_allowed(conn), do: Errors.spring(conn, 405, "Method Not Allowed")

  # --- criteria -------------------------------------------------------------------------------

  @doc "`GET /provisioningcriteria`"
  def criteria(conn) do
    answer(conn, fn ->
      for c <- Criteria.list(),
          do: %{"criteriaId" => c.id, "criteriaName" => c.name, "createdBy" => c.created_by}
    end)
  end

  @doc "`GET /provisioningcriteria/template`"
  def criteria_template(conn) do
    answer(conn, fn ->
      t = Criteria.template()

      %{
        "loanProducts" => t.loan_products,
        "definitions" =>
          for(
            d <- t.definitions,
            do: %{"categoryId" => d.category_id, "categoryName" => d.category_name}
          ),
        "glAccounts" => Enum.map(t.accounts, &GLAccounts.account_json/1)
      }
    end)
  end

  @doc "`GET /provisioningcriteria/:id`"
  def one_criteria(conn, raw_id) do
    template? = conn.query_params["template"] == "true"

    Write.with_path_id(conn, raw_id, fn id ->
      answer(conn, fn -> one(id, template?) end)
    end)
  end

  defp one(id, template?) do
    with {:ok, criteria} <- Criteria.get(id),
         do: if(template?, do: criteria_form(criteria), else: criteria_json(criteria))
  end

  defp criteria_json(c) do
    %{
      "criteriaId" => c.id,
      "criteriaName" => c.name,
      "loanProducts" => c.loan_products,
      "definitions" => Enum.map(c.definitions, &definition/1)
    }
  end

  # a criteria with the choices a form for changing it needs: the products not yet chosen (none exist),
  # the ones chosen and the accounts
  defp criteria_form(c) do
    t = Criteria.template()

    %{
      "criteriaId" => c.id,
      "criteriaName" => c.name,
      "selectedLoanProducts" => c.loan_products,
      "loanProducts" => t.loan_products,
      "definitions" => Enum.map(c.definitions, &definition/1),
      "glAccounts" => Enum.map(t.accounts, &GLAccounts.account_json/1)
    }
  end

  defp definition(d) do
    %{
      "id" => d.id,
      "categoryId" => d.category_id,
      "categoryName" => d.category_name,
      "minAge" => d.min_age,
      "maxAge" => d.max_age,
      "provisioningPercentage" => d.percentage,
      "liabilityAccount" => d.liability_account,
      "liabilityCode" => d.liability_code,
      "liabilityName" => d.liability_name,
      "expenseAccount" => d.expense_account,
      "expenseCode" => d.expense_code,
      "expenseName" => d.expense_name
    }
  end

  # --- entries --------------------------------------------------------------------------------

  @doc "`GET /provisioningentries` and `GET /provisioningentries/entries`: no entry exists until loans do."
  def entries(conn), do: answer(conn, fn -> %{"totalFilteredRecords" => 0, "pageItems" => []} end)

  @doc "`GET /provisioningentries/:id`: Fineract fails on an entry that does not exist."
  def one_entry(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn _id ->
      Errors.render(conn, %ECBLedger.Errors.ServerError{})
    end)
  end

  # --- internals ------------------------------------------------------------------------------

  # these reads need a signed-in user and nothing more
  defp answer(conn, fun) do
    case fun.() do
      {:error, error} -> Errors.render(conn, error)
      body -> Response.json(conn, 200, body)
    end
  end
end
