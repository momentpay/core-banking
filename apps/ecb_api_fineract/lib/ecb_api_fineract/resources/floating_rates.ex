defmodule ECBApiFineract.Resources.FloatingRates do
  @moduledoc """
  `/v1/floatingrates`: named series of interest rates, one of which can be the base lending rate the others
  are stated against. List (without the periods), one rate (with the periods in use, latest first),
  create and update. Fineract lets any signed-in user read these; changing one needs `CREATE_FLOATINGRATE`
  or `UPDATE_FLOATINGRATE`. Times are sent as ISO 8601 text.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBApiFineract.Resources.Write
  alias ECBCatalog.FloatingRates, as: Catalog

  @resource "FLOATINGRATE"

  @doc "`GET /floatingrates`"
  def index(conn), do: answer(conn, fn -> Enum.map(Catalog.list(), &rate_json/1) end)

  @doc "`GET /floatingrates/:id`"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id -> answer(conn, fn -> one(id) end) end)
  end

  defp one(id) do
    with {:ok, rate} <- Catalog.get(id) do
      Map.put(rate_json(rate), "ratePeriods", Enum.map(rate.periods, &period_json/1))
    end
  end

  @doc "`POST /floatingrates`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /floatingrates/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  # reading needs a signed-in user and nothing more
  defp answer(conn, fun) do
    case fun.() do
      {:error, error} -> Errors.render(conn, error)
      body -> Response.json(conn, 200, body)
    end
  end

  defp rate_json(r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "isBaseLendingRate" => r.base_lending_rate,
      "isActive" => r.active,
      "createdBy" => r.created_by,
      "createdOn" => time(r.created_on),
      "modifiedBy" => r.modified_by,
      "modifiedOn" => time(r.modified_on)
    }
  end

  defp period_json(p) do
    %{
      "id" => p.id,
      "fromDate" => Date.to_iso8601(p.from_date),
      "interestRate" => p.interest_rate,
      "isDifferentialToBaseLendingRate" => p.differential,
      "isActive" => p.active,
      "createdBy" => p.created_by,
      "createdOn" => time(p.created_on),
      "modifiedBy" => p.modified_by,
      "modifiedOn" => time(p.modified_on)
    }
  end

  defp time(nil), do: nil
  defp time(%DateTime{} = time), do: DateTime.to_iso8601(time)
end
