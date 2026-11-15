defmodule ECBApiFineract.Resources.Funds do
  @moduledoc "`/v1/funds`: list, one fund, create and update."
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBOrg.Funds

  @doc "`GET /funds`"
  def index(conn) do
    Read.respond(conn, "FUND", fn -> Enum.map(Funds.list(), &serialize/1) end)
  end

  @doc "`GET /funds/:id`"
  def show(conn, raw_id) do
    Read.respond(conn, "FUND", fn ->
      with {:ok, id} <- Write.path_id(raw_id),
           {:ok, fund} <- Funds.get(id),
           do: serialize(fund)
    end)
  end

  @doc "`POST /funds`"
  def create(conn), do: Write.execute(conn, "FUND", "CREATE")

  @doc "`PUT /funds/:id`"
  def update(conn, raw_id) do
    Write.with_path_id(conn, raw_id, &Write.execute(conn, "FUND", "UPDATE", id: &1))
  end

  defp serialize(f), do: %{"id" => f.id, "name" => f.name, "externalId" => f.external_id}
end
