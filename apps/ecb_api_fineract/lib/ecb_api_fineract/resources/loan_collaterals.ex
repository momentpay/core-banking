defmodule ECBApiFineract.Resources.LoanCollaterals do
  @moduledoc """
  `/loans/{id}/collaterals`: the collateral offered for a loan, one of them, the template for adding one, and
  adding, changing and removing them, after Fineract's `CollateralsApiResource`.
  """
  alias ECBApiFineract.Resources.{LoanAccounts, LoanProducts, Read, Write}
  alias ECBLoans.{Collaterals, Loans}

  @resource "COLLATERAL"

  @doc "`GET /loans/:id/collaterals`"
  def index(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        loan = Loans.fetch!(id)
        id |> Collaterals.list() |> Enum.map(&item(&1, loan))
      end)
    end)
  end

  @doc "`GET /loans/:id/collaterals/template`"
  def template(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn ->
        Loans.fetch!(id)
        %{"allowedCollateralTypes" => LoanProducts.code_values("LoanCollateral")}
      end)
    end)
  end

  @doc "`GET /loans/:id/collaterals/:collateral_id`"
  def show(conn, raw_id, raw_collateral_id) do
    with_ids(conn, raw_id, raw_collateral_id, fn id, collateral_id ->
      Read.respond(conn, @resource, fn -> one(id, collateral_id) end)
    end)
  end

  defp one(id, collateral_id) do
    loan = Loans.fetch!(id)

    case Collaterals.get(id, collateral_id) do
      nil -> {:error, Collaterals.not_found(id, collateral_id)}
      c -> item(c, loan)
    end
  end

  defp item(c, loan) do
    %{
      "id" => c.id,
      "type" => %{"id" => c.type_id, "name" => c.type_name},
      "currency" => LoanAccounts.charge_currency_json(loan)
    }
    |> put("value", nonzero(c.value))
    |> put("description", c.description)
  end

  defp nonzero(nil), do: nil
  defp nonzero(value), do: if(Decimal.eq?(value, 0), do: nil, else: value)

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  @doc "`POST /loans/:id/collaterals`"
  def create(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "CREATE", id: &1))

  @doc "`PUT /loans/:id/collaterals/:collateral_id`"
  def update(conn, raw_id, raw_collateral_id) do
    with_ids(conn, raw_id, raw_collateral_id, fn id, collateral_id ->
      Write.execute(conn, @resource, "UPDATE", id: id, subentity_id: collateral_id)
    end)
  end

  @doc "`DELETE /loans/:id/collaterals/:collateral_id`"
  def delete(conn, raw_id, raw_collateral_id) do
    with_ids(conn, raw_id, raw_collateral_id, fn id, collateral_id ->
      Write.execute(conn, @resource, "DELETE", id: id, subentity_id: collateral_id)
    end)
  end

  defp with_ids(conn, raw_id, raw_collateral_id, fun) do
    with {:ok, id} <- Write.path_id(raw_id),
         {:ok, collateral_id} <- Write.path_id(raw_collateral_id) do
      fun.(id, collateral_id)
    else
      {:error, error} -> ECBApiFineract.Errors.render(conn, error)
    end
  end
end
