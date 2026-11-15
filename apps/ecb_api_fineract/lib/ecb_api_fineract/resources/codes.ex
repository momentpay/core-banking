defmodule ECBApiFineract.Resources.Codes do
  @moduledoc """
  `/v1/codes`: the code lists and their values.

  A code can be named by id (`/codes/7/codevalues`) or by name (`/codes/name/Region/codevalues`). Reading
  needs `READ_CODE` (`READ_CODEVALUE` for values); writing needs `CREATE_`, `UPDATE_` or `DELETE_` of
  `CODE` or `CODEVALUE`.
  """
  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBOrg.Codes

  # --- codes ----------------------------------------------------------------------------------

  @doc "`GET /codes`"
  def index(conn), do: Read.respond(conn, "CODE", fn -> Enum.map(Codes.list(), &code/1) end)

  @doc "`GET /codes/:id`"
  def show(conn, raw_id) do
    Read.respond(conn, "CODE", fn ->
      with {:ok, id} <- Write.path_id(raw_id),
           {:ok, code} <- Codes.get(id),
           do: code(code)
    end)
  end

  @doc "`GET /codes/name/:name`"
  def show_by_name(conn, name) do
    Read.respond(conn, "CODE", fn -> with {:ok, c} <- Codes.get_by_name(name), do: code(c) end)
  end

  @doc "`POST /codes`"
  def create(conn), do: Write.execute(conn, "CODE", "CREATE")

  @doc "`PUT /codes/:id`"
  def update(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "CODE", "UPDATE", id: &1)
      )

  @doc "`DELETE /codes/:id`"
  def delete(conn, raw_id),
    do:
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "CODE", "DELETE", id: &1)
      )

  # --- code values ----------------------------------------------------------------------------

  @doc "`GET /codes/:code_id/codevalues`"
  def values(conn, raw_code_id) do
    Read.respond(conn, "CODEVALUE", fn ->
      with {:ok, id} <- Write.path_id(raw_code_id),
           do: Enum.map(Codes.values(id), &value/1)
    end)
  end

  @doc "`GET /codes/name/:name/codevalues`"
  def values_by_name(conn, name) do
    Read.respond(conn, "CODEVALUE", fn ->
      with {:ok, code} <- Codes.get_by_name(name),
           do: Enum.map(Codes.values(code.id, by_id: true), &value/1)
    end)
  end

  @doc "`GET /codes/:code_id/codevalues/:id`"
  def show_value(conn, _raw_code_id, raw_id) do
    Read.respond(conn, "CODEVALUE", fn ->
      with {:ok, id} <- Write.path_id(raw_id),
           {:ok, v} <- Codes.get_value(id),
           do: value(v)
    end)
  end

  @doc "`GET /codes/name/:name/codevalues/:id`"
  def show_value_by_name(conn, name, raw_id) do
    Read.respond(conn, "CODEVALUE", fn ->
      with {:ok, _code} <- Codes.get_by_name(name),
           {:ok, id} <- Write.path_id(raw_id),
           {:ok, v} <- Codes.get_value(id),
           do: value(v)
    end)
  end

  @doc "`POST /codes/:code_id/codevalues`"
  def create_value(conn, raw_code_id) do
    Write.with_path_id(
      conn,
      raw_code_id,
      &Write.execute(conn, "CODEVALUE", "CREATE", id: &1)
    )
  end

  @doc "`POST /codes/name/:name/codevalues`"
  def create_value_by_name(conn, name) do
    with_code_named(conn, name, &Write.execute(conn, "CODEVALUE", "CREATE", id: &1))
  end

  @doc "`PUT /codes/:code_id/codevalues/:id`"
  def update_value(conn, _raw_code_id, raw_id) do
    Write.with_path_id(
      conn,
      raw_id,
      &Write.execute(conn, "CODEVALUE", "UPDATE", id: &1)
    )
  end

  @doc "`PUT /codes/name/:name/codevalues/:id`"
  def update_value_by_name(conn, _name, raw_id), do: update_value(conn, nil, raw_id)

  @doc "`DELETE /codes/:code_id/codevalues/:id`"
  def delete_value(conn, raw_code_id, raw_id) do
    Write.with_path_id(conn, raw_code_id, fn code_id ->
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "CODEVALUE", "DELETE", id: code_id, subentity_id: &1)
      )
    end)
  end

  @doc "`DELETE /codes/name/:name/codevalues/:id`"
  def delete_value_by_name(conn, name, raw_id) do
    with_code_named(conn, name, fn code_id ->
      Write.with_path_id(
        conn,
        raw_id,
        &Write.execute(conn, "CODEVALUE", "DELETE", id: code_id, subentity_id: &1)
      )
    end)
  end

  # --- internals ------------------------------------------------------------------------------

  defp with_code_named(conn, name, fun) do
    case Codes.get_by_name(name) do
      {:ok, code} -> fun.(code.id)
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp code(c), do: %{"id" => c.id, "name" => c.name, "systemDefined" => c.system_defined}

  defp value(v) do
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
