defmodule ECBApiFineract.Resources.Rates do
  @moduledoc """
  `/v1/rates`: named percentages a loan product can carry. List, one rate, create and update; no delete.
  Reading needs `READ_RATE`.
  """
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBCatalog.Rates, as: Catalog

  @resource "RATE"

  @doc "`GET /rates`"
  def index(conn),
    do: Read.respond(conn, @resource, fn -> Enum.map(Catalog.list(), &json/1) end)

  @doc "`GET /rates/:id`"
  def show(conn, raw_id) do
    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> one(id) end)
    end)
  end

  defp one(id) do
    with {:ok, rate} <- Catalog.get(id), do: json(rate)
  end

  @doc "`POST /rates`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /rates/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  defp json(rate) do
    %{
      "id" => rate.id,
      "name" => rate.name,
      "percentage" => rate.percentage,
      "productApply" => Read.option(rate.applies),
      "active" => rate.active
    }
  end
end
