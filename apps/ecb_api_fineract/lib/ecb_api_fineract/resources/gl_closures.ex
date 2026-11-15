defmodule ECBApiFineract.Resources.GLClosures do
  @moduledoc """
  `/v1/glclosures`: accounting closures, which stop postings dated on or before the closing date in an
  office. List (all, or one office with `?officeId=`), one closure (`?template=true` adds the offices),
  create, update (the comments only) and delete (the latest closure of an office only).
  Reading needs `READ_GLCLOSURE`. Dates are sent as `2025-03-01` text, as Fineract sends them.
  """
  alias ECBApiFineract.Errors.PathNotFound
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBLedger.Closures
  alias ECBOrg.Offices

  @resource "GLCLOSURE"

  @doc "`GET /glclosures`"
  def index(conn) do
    Read.respond(conn, @resource, fn ->
      with {:ok, office_id} <- office_filter(conn.query_params["officeId"]),
           do: office_id |> Closures.list() |> Enum.map(&serialize/1)
    end)
  end

  @doc "`GET /glclosures/:id`"
  def show(conn, raw_id) do
    with_offices? = conn.query_params["template"] == "true"

    Write.with_path_id(conn, raw_id, fn id ->
      Read.respond(conn, @resource, fn -> one(id, with_offices?, conn.assigns.current_user) end)
    end)
  end

  defp one(id, with_offices?, user) do
    with {:ok, closure} <- Closures.get(id) do
      Map.put(
        serialize(closure),
        "allowedOffices",
        if(with_offices?, do: offices(user), else: [])
      )
    end
  end

  @doc "`POST /glclosures`"
  def create(conn), do: Write.execute(conn, @resource, "CREATE")

  @doc "`PUT /glclosures/:id`"
  def update(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "UPDATE", id: &1))

  @doc "`DELETE /glclosures/:id`"
  def delete(conn, raw_id),
    do: Write.with_path_id(conn, raw_id, &Write.execute(conn, @resource, "DELETE", id: &1))

  # No filter or an empty one means every office; text that is not a number is the plain 404.
  defp office_filter(nil), do: {:ok, nil}

  defp office_filter(text) do
    case Integer.parse(text) do
      {id, ""} -> {:ok, id}
      _ -> {:error, %PathNotFound{}}
    end
  end

  defp offices(user) do
    for o <- Offices.template(user).allowed_parents,
        do: %{"id" => o.id, "name" => o.name, "nameDecorated" => o.name_decorated}
  end

  defp serialize(c) do
    %{
      "id" => c.id,
      "officeId" => c.office_id,
      "officeName" => c.office_name,
      "closingDate" => Date.to_iso8601(c.closing_date),
      "deleted" => c.deleted,
      "createdDate" => c.created_date && Date.to_iso8601(c.created_date),
      "lastUpdatedDate" => c.updated_date && Date.to_iso8601(c.updated_date),
      "createdByUserId" => c.created_by_id,
      "createdByUsername" => c.created_by_name,
      "lastUpdatedByUserId" => c.updated_by_id,
      "lastUpdatedByUsername" => c.updated_by_name,
      "allowedOffices" => []
    }
    |> put_unless_nil("comments", c.comments)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
