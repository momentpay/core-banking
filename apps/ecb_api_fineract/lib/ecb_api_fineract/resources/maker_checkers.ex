defmodule ECBApiFineract.Resources.MakerCheckers do
  @moduledoc """
  `/v1/makercheckers`: the inbox of commands waiting for approval, and approving, rejecting or deleting
  one. Anyone signed in may look at the inbox; they see only the commands they may check. Approving needs
  the `*_CHECKER` permission of the command, which the command pipeline checks.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBApiFineract.Resources.{AuditData, Audits, Write}
  alias ECBPlatform.{Audit, Commands}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.UnrecognizedQueryParameter

  @doc "`GET /makercheckers`"
  def index(conn) do
    query = conn.query_params
    entries = Audit.to_be_checked(conn.assigns.current_user, Audits.criteria(query))
    with_json? = query["includeJson"] == "true"
    Response.json(conn, 200, Enum.map(entries, &AuditData.entry(&1, :seconds, with_json?)))
  end

  @doc "`GET /makercheckers/searchtemplate`"
  def search_template(conn) do
    t = Audit.search_template(conn.assigns.current_user, :makerchecker)

    Response.json(conn, 200, %{
      "appUsers" => for(u <- t.users, do: %{"id" => u.id, "username" => u.username}),
      "actionNames" => t.action_names,
      "entityNames" => t.entity_names
    })
  end

  @doc "`POST /makercheckers/:id?command=approve|reject`"
  def command(conn, raw_id) do
    user = conn.assigns.current_user

    case Write.id(raw_id, &Audit.not_found/1) do
      {:ok, id} ->
        case String.downcase(String.trim(conn.query_params["command"] || "")) do
          "approve" -> approve(conn, id, user)
          "reject" -> only_id(conn, Commands.reject(id, user), id)
          _ -> Errors.render(conn, unsupported(conn.query_params["command"]))
        end

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  @doc "`DELETE /makercheckers/:id`"
  def delete(conn, raw_id) do
    case Write.id(raw_id, &Audit.not_found/1) do
      {:ok, id} -> only_id(conn, Commands.delete(id, conn.assigns.current_user), id)
      {:error, error} -> Errors.render(conn, error)
    end
  end

  defp approve(conn, id, user) do
    case Commands.approve(id, user) do
      {:ok, result} ->
        Response.json(conn, 200, Map.put(Result.to_api_map(result), "commandId", id))

      {:error, error} ->
        Errors.render(conn, error)
    end
  end

  defp only_id(conn, {:ok, _}, id), do: Response.json(conn, 200, %{"commandId" => id})
  defp only_id(conn, {:error, error}, _id), do: Errors.render(conn, error)

  defp unsupported(value),
    do: %UnrecognizedQueryParameter{name: "command", value: value, allowed: []}
end
