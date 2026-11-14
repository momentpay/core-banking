defmodule ECBApiFineract.Resources.Authentication do
  @moduledoc """
  `POST /v1/authentication`: how a client logs in.

  Takes `{"username": ..., "password": ...}` and, when they are right, tells the client who the user
  is: office, roles and permission codes, and the `base64EncodedAuthenticationKey` to send as the
  HTTP basic credentials on later requests. Wrong credentials give HTTP 401.
  """
  alias ECBApiFineract.{Errors, Response}
  alias ECBPlatform.Security

  @spec login(Plug.Conn.t()) :: Plug.Conn.t()
  def login(conn) do
    with %{"username" => username, "password" => password}
         when is_binary(username) and is_binary(password) <- conn.body_params,
         {:ok, user} <- Security.authenticate(username, password) do
      details = Security.authentication_details(user)

      Response.json(conn, 200, %{
        "username" => details.username,
        "userId" => details.user_id,
        "base64EncodedAuthenticationKey" => Base.encode64(username <> ":" <> password),
        "authenticated" => true,
        "officeId" => details.office_id,
        "officeName" => details.office_name,
        "roles" =>
          Enum.map(
            details.roles,
            &%{
              "id" => &1.id,
              "name" => &1.name,
              "description" => &1.description,
              "disabled" => &1.disabled
            }
          ),
        "permissions" => details.permissions,
        # Password expiry and two-factor authentication arrive with user administration.
        "shouldRenewPassword" => false,
        "isTwoFactorAuthenticationRequired" => false
      })
    else
      _ -> Errors.unauthenticated(conn)
    end
  end
end
