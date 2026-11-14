defmodule ECBApiFineract.Resources.Offices do
  @moduledoc """
  `/v1/offices`: list, one office, and the new-office template. Reading needs `READ_OFFICE`.

  Query parameters of the list: `includeAllOffices` (true or false), `orderBy` and `sortOrder`.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBOrg.Offices
  alias ECBPlatform.Security

  @spec index(Plug.Conn.t()) :: Plug.Conn.t()
  def index(conn) do
    user = conn.assigns.current_user
    params = conn.query_params

    with :ok <- Security.validate_has_read_permission(user, "OFFICE"),
         {:ok, offices} <-
           Offices.list(user,
             include_all: params["includeAllOffices"] == "true",
             order_by: params["orderBy"],
             sort_order: params["sortOrder"]
           ) do
      Response.json(conn, 200, Enum.map(offices, &serialize/1))
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @spec show(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def show(conn, raw_id) do
    with :ok <- Security.validate_has_read_permission(conn.assigns.current_user, "OFFICE"),
         {id, ""} <- Integer.parse(raw_id),
         {:ok, office} <- Offices.get(id) do
      Response.json(conn, 200, serialize(office))
    else
      {:error, error} -> Errors.render(conn, error)
      _not_a_number -> Errors.render(conn, %ECBOrg.Errors.OfficeNotFound{office_id: raw_id})
    end
  end

  @spec template(Plug.Conn.t()) :: Plug.Conn.t()
  def template(conn) do
    user = conn.assigns.current_user

    case Security.validate_has_read_permission(user, "OFFICE") do
      :ok ->
        template = Offices.template(user)

        Response.json(conn, 200, %{
          "openingDate" => template.opening_date,
          "allowedParents" =>
            Enum.map(
              template.allowed_parents,
              &%{"id" => &1.id, "name" => &1.name, "nameDecorated" => &1.name_decorated}
            )
        })

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  defp serialize(office) do
    %{
      "id" => office.id,
      "name" => office.name,
      "nameDecorated" => office.name_decorated,
      "externalId" => office.external_id,
      "openingDate" => office.opening_date,
      "hierarchy" => office.hierarchy,
      "parentId" => office.parent_id,
      "parentName" => office.parent_name
    }
  end
end
