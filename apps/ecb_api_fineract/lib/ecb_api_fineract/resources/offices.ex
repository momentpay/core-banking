defmodule ECBApiFineract.Resources.Offices do
  @moduledoc """
  `/v1/offices`: list, one office, the new-office template, and create and update. Reading needs
  `READ_OFFICE`; writing goes through the command pipeline (`CREATE_OFFICE`, `UPDATE_OFFICE`).

  Query parameters of the list: `includeAllOffices` (true or false), `orderBy` and `sortOrder`.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBApiFineract.Resources.Write
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
    with {:ok, id} <- Write.path_id(raw_id),
         :ok <- Security.validate_has_read_permission(conn.assigns.current_user, "OFFICE"),
         {:ok, office} <- Offices.get(id) do
      Response.json(conn, 200, serialize(office))
    else
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "`POST /offices`"
  @spec create(Plug.Conn.t()) :: Plug.Conn.t()
  def create(conn), do: Write.execute(conn, "OFFICE", "CREATE")

  @doc "`PUT /offices/:id`"
  @spec update(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def update(conn, raw_id) do
    Write.with_path_id(
      conn,
      raw_id,
      &Write.execute(conn, "OFFICE", "UPDATE", id: &1, office_id: &1)
    )
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
