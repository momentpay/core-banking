defmodule ECBApiFineract.Plugs.Authenticate do
  @moduledoc """
  HTTP basic authentication, checked on every request, with no session.

  Fineract's answers, reproduced:

    * no credentials: HTTP 401, no body, and a `WWW-Authenticate` challenge;
    * wrong credentials, or a deleted, disabled, locked or expired account: HTTP 401 with the web
      container's error body.

  `/v1/authentication` is exempt: it is how a client logs in. On success the signed-in user is
  `conn.assigns.current_user`. Needs `ECBApiFineract.Plugs.Tenant` first.
  """
  @behaviour Plug

  import Plug.Conn

  alias ECBApiFineract.Errors
  alias ECBPlatform.Security

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["v1", "authentication"]} = conn, _opts), do: conn

  def call(conn, _opts) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      :error ->
        conn |> Errors.challenge() |> halt()

      {username, password} ->
        case Security.authenticate(username, password) do
          {:ok, user} -> assign(conn, :current_user, user)
          :error -> conn |> Errors.spring(401, "Unauthorized") |> halt()
        end
    end
  end
end
