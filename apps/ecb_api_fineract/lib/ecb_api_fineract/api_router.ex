defmodule ECBApiFineract.ApiRouter do
  @moduledoc """
  The routes under `/fineract-provider/api`. Every request is resolved to a tenant and authenticated
  before it reaches a resource, except `/v1/authentication`, which is how a client logs in.

  An operation that exists in Fineract's API but is not built yet answers HTTP 501 with a clear
  message, so a client can tell "not implemented" from "not found". The inventory in
  `parity/inventory/endpoints.csv` says which operations are planned and which are deferred.
  """
  use Plug.Router
  use Plug.ErrorHandler

  alias ECBApiFineract.Errors
  alias ECBApiFineract.Resources.{Administration, Authentication, Offices, Organisation}

  plug :match

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason,
    body_reader: {ECBApiFineract.BodyReader, :read_body, []}
  )

  plug ECBApiFineract.Plugs.Tenant
  plug ECBApiFineract.Plugs.Authenticate
  plug :dispatch

  post "/v1/authentication", do: Authentication.login(conn)

  get "/v1/offices/template", do: Offices.template(conn)
  get "/v1/offices", do: Offices.index(conn)
  get "/v1/offices/:id", do: Offices.show(conn, id)

  get "/v1/currencies", do: Organisation.currencies(conn)
  get "/v1/codes", do: Organisation.codes(conn)
  get "/v1/paymenttypes", do: Organisation.payment_types(conn)
  get "/v1/workingdays/template", do: Organisation.working_days_template(conn)
  get "/v1/workingdays", do: Organisation.working_days(conn)
  get "/v1/funds", do: Organisation.funds(conn)
  get "/v1/holidays/template", do: Organisation.holidays_template(conn)
  get "/v1/holidays", do: Organisation.holidays(conn)
  get "/v1/staff", do: Organisation.staff(conn)
  get "/v1/accountnumberformats/template", do: Organisation.account_number_formats_template(conn)
  get "/v1/accountnumberformats", do: Organisation.account_number_formats(conn)

  get "/v1/configurations/name/:name", do: Administration.configuration_by_name(conn, name)
  get "/v1/configurations", do: Administration.configurations(conn)
  get "/v1/permissions", do: Administration.permissions(conn)
  get "/v1/roles/:id", do: Administration.role_by_id(conn, id)
  get "/v1/roles", do: Administration.roles(conn)
  get "/v1/users/template", do: Administration.users_template(conn)
  get "/v1/users", do: Administration.users(conn)
  get "/v1/users/:id", do: Administration.user_by_id(conn, id)
  get "/v1/passwordpreferences/template", do: Administration.password_preferences_template(conn)
  get "/v1/passwordpreferences", do: Administration.password_preferences(conn)

  match _ do
    Errors.not_implemented(conn, conn.method, conn.request_path)
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    Errors.render(conn, Exception.normalize(kind, reason, stack))
  end
end
