defmodule ECBApiFineract.Resources.ClientIdentifiers do
  @moduledoc """
  `/v1/clients/:client_id/identifiers`: the identity documents of a client. List, one (with
  `?template=true` for the document types), template, create, update and delete. Reading needs
  `READ_CLIENTIDENTIFIER`; each write needs `<ACTION>_CLIENTIDENTIFIER`.

  The list writes dates as text (`2020-01-01`) and the single read as arrays, as Fineract does.
  """
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBParty.Clients.Options
  alias ECBParty.Identifiers

  @resource "CLIENTIDENTIFIER"

  @choosable ~w(id clientId documentType documentKey description issuanceDate expiryDate
                allowedDocumentTypes)

  @doc "`GET /clients/:client_id/identifiers`"
  def index(conn, raw_client_id) do
    user = conn.assigns.current_user

    Write.with_path_id(conn, raw_client_id, fn client_id ->
      Read.respond(conn, @resource, fn ->
        user |> Identifiers.list(client_id) |> Enum.map(&json(&1, :list))
      end)
    end)
  end

  @doc "`GET /clients/:client_id/identifiers/template`"
  def template(conn, raw_client_id) do
    Write.with_path_id(conn, raw_client_id, fn _client_id ->
      Read.respond(conn, @resource, fn -> %{"allowedDocumentTypes" => document_types()} end)
    end)
  end

  @doc "`GET /clients/:client_id/identifiers/:id`"
  def show(conn, raw_client_id, raw_id) do
    user = conn.assigns.current_user
    q = conn.query_params

    with_ids(conn, raw_client_id, raw_id, fn client_id, id ->
      Read.respond(conn, @resource, fn -> one(user, client_id, id, q) end)
    end)
  end

  defp one(user, client_id, id, q) do
    with {:ok, row} <- Identifiers.get(user, client_id, id) do
      row |> json(:single) |> with_template(q) |> only_fields(q)
    end
  end

  # both ids in the path must be numbers, or the answer is the web container's plain 404
  defp with_ids(conn, raw_client_id, raw_id, fun) do
    Write.with_path_id(conn, raw_client_id, fn client_id ->
      Write.with_path_id(conn, raw_id, &fun.(client_id, &1))
    end)
  end

  @doc "`POST /clients/:client_id/identifiers`"
  def create(conn, raw_client_id),
    do:
      Write.with_path_id(
        conn,
        raw_client_id,
        &Write.execute(conn, @resource, "CREATE", client_id: &1)
      )

  @doc "`PUT /clients/:client_id/identifiers/:id`"
  def update(conn, raw_client_id, raw_id), do: write(conn, "UPDATE", raw_client_id, raw_id)

  @doc "`DELETE /clients/:client_id/identifiers/:id`"
  def delete(conn, raw_client_id, raw_id), do: write(conn, "DELETE", raw_client_id, raw_id)

  defp write(conn, action, raw_client_id, raw_id) do
    with_ids(conn, raw_client_id, raw_id, fn client_id, id ->
      Write.execute(conn, @resource, action, client_id: client_id, id: id)
    end)
  end

  defp with_template(body, %{"template" => "true"}),
    do: Map.put(body, "allowedDocumentTypes", document_types())

  defp with_template(body, _query), do: body

  defp document_types do
    Enum.map(Options.code_values("Customer Identifier"), fn v ->
      %{
        "id" => v.id,
        "name" => v.name,
        "position" => v.position,
        "description" => v.description,
        "active" => v.active,
        "mandatory" => v.mandatory
      }
    end)
  end

  defp json(r, mode) do
    date = if mode == :list, do: &iso/1, else: & &1

    %{
      "id" => r.id,
      "clientId" => r.client_id,
      "documentType" => %{"id" => r.document_type_id, "name" => r.document_type},
      "documentKey" => r.document_key,
      "description" => r.description,
      "status" => r.status_code,
      "issuanceDate" => date.(r.issuance_date),
      "expiryDate" => date.(r.expiry_date)
    }
  end

  defp iso(nil), do: nil
  defp iso(date), do: Date.to_iso8601(date)

  # Only the fields named in `fields`: a name Fineract lets `fields` choose that was not asked for is left
  # out wherever it appears.
  defp only_fields({:error, _} = error, _q), do: error

  defp only_fields(body, q) do
    case q["fields"] do
      fields when is_binary(fields) and fields != "" ->
        wanted = fields |> String.split(",") |> Enum.map(&String.trim/1)
        filter(body, MapSet.new(@choosable -- wanted))

      _ ->
        body
    end
  end

  defp filter(map, drop) when is_map(map),
    do: for({k, v} <- map, not MapSet.member?(drop, k), into: %{}, do: {k, filter(v, drop)})

  defp filter(list, drop) when is_list(list), do: Enum.map(list, &filter(&1, drop))
  defp filter(other, _drop), do: other
end
