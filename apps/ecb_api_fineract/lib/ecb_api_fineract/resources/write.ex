defmodule ECBApiFineract.Resources.Write do
  @moduledoc """
  The shape every write endpoint shares: turn the request into a command, run it through the command
  pipeline as the signed-in user, and answer with the command's result or Fineract's error.

  The body is passed on exactly as received (`conn.assigns.raw_body`), because commands keep it as text.
  A client may send an `Idempotency-Key` header; a repeat of the same request with the same key gets
  the first outcome back. `?command=<name>` selects the action for operations that share a path.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBPlatform.Commands
  alias ECBPlatform.Commands.{Command, Result}

  @doc """
  Runs `action` on `entity` and sends the outcome. Options: `:id` (the entity the path names),
  `:subentity_id` (a second id in the path), `:client_id`, `:office_id` and `:transaction_id` (a journal transaction's
  text id).
  """
  @spec execute(Plug.Conn.t(), String.t(), String.t(), keyword) :: Plug.Conn.t()
  def execute(conn, entity, action, opts \\ []) do
    command =
      Command.new(action, entity,
        json: Keyword.get(opts, :json, conn.assigns[:raw_body]),
        entity_id: opts[:id],
        subentity_id: opts[:subentity_id],
        client_id: opts[:client_id],
        office_id: opts[:office_id],
        transaction_id: opts[:transaction_id],
        idempotency_key: idempotency_key(conn),
        client_ip: client_ip(conn)
      )

    case Commands.execute(command, conn.assigns.current_user) do
      {:ok, result} -> Response.json(conn, 200, Result.to_api_map(result))
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc """
  The id in a path as `{:ok, id}`; text that is not a number is the web container's plain 404, as
  Fineract answers `/glaccounts/abc`.
  """
  @spec path_id(String.t()) :: {:ok, integer} | {:error, Exception.t()}
  def path_id(raw) do
    case parse_id(raw) do
      nil -> {:error, %Errors.PathNotFound{}}
      id -> {:ok, id}
    end
  end

  @doc "Runs `fun` with the id in the path, or answers the plain 404 when it is not a number."
  @spec with_path_id(Plug.Conn.t(), String.t(), (integer -> Plug.Conn.t())) :: Plug.Conn.t()
  def with_path_id(conn, raw, fun) do
    case path_id(raw) do
      {:ok, id} -> fun.(id)
      {:error, error} -> Errors.render(conn, error)
    end
  end

  @doc "Parses an id taken from the path, or returns `nil`."
  @spec parse_id(String.t()) :: integer | nil
  def parse_id(raw) do
    case Integer.parse(raw) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp idempotency_key(conn) do
    case Plug.Conn.get_req_header(conn, "idempotency-key") do
      [key | _] when key != "" -> key
      _ -> nil
    end
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
