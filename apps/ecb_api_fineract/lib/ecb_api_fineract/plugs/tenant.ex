defmodule ECBApiFineract.Plugs.Tenant do
  @moduledoc """
  Resolves the tenant of a request and points the request process at the tenant's database.

  The tenant comes from the `Fineract-Platform-TenantId` header, or the `tenantIdentifier` query
  parameter. Without one, or with one that is not registered, Fineract answers HTTP 400 and so do we.
  The tenant is then available as `conn.assigns.tenant`.
  """
  @behaviour Plug

  import Plug.Conn

  alias ECBApiFineract.Errors
  alias ECBPlatform.Tenancy

  @header "fineract-platform-tenantid"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    with identifier when is_binary(identifier) <- identifier(conn),
         %{} = tenant <- Tenancy.get_by_identifier(identifier),
         :ok <- Tenancy.activate(tenant) do
      assign(conn, :tenant, tenant)
    else
      _ -> conn |> Errors.spring(400, "Bad Request") |> halt()
    end
  end

  defp identifier(conn) do
    case get_req_header(conn, @header) do
      [value | _] when value != "" -> value
      _ -> conn.query_params["tenantIdentifier"]
    end
  end
end
