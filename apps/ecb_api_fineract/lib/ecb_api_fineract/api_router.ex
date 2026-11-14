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

  alias ECBApiFineract.Resources.{
    Administration,
    Authentication,
    Codes,
    Funds,
    Offices,
    Organisation,
    PaymentTypes,
    Staff
  }

  plug :match

  @parser_options Plug.Parsers.init(
                    parsers: [:json],
                    pass: ["*/*"],
                    json_decoder: Jason,
                    body_reader: {ECBApiFineract.BodyReader, :read_body, []}
                  )

  plug :parse_body

  plug ECBApiFineract.Plugs.Tenant
  plug ECBApiFineract.Plugs.Authenticate
  plug :dispatch

  post "/v1/authentication", do: Authentication.login(conn)

  get "/v1/offices/template", do: Offices.template(conn)
  get "/v1/offices", do: Offices.index(conn)
  get "/v1/offices/:id", do: Offices.show(conn, id)
  post "/v1/offices", do: Offices.create(conn)
  put "/v1/offices/:id", do: Offices.update(conn, id)

  get "/v1/currencies", do: Organisation.currencies(conn)
  get "/v1/codes", do: Codes.index(conn)
  post "/v1/codes", do: Codes.create(conn)
  get "/v1/codes/name/:name", do: Codes.show_by_name(conn, name)
  get "/v1/codes/name/:name/codevalues", do: Codes.values_by_name(conn, name)
  post "/v1/codes/name/:name/codevalues", do: Codes.create_value_by_name(conn, name)
  get "/v1/codes/name/:name/codevalues/:id", do: Codes.show_value_by_name(conn, name, id)
  put "/v1/codes/name/:name/codevalues/:id", do: Codes.update_value_by_name(conn, name, id)
  delete "/v1/codes/name/:name/codevalues/:id", do: Codes.delete_value_by_name(conn, name, id)
  get "/v1/codes/:id", do: Codes.show(conn, id)
  put "/v1/codes/:id", do: Codes.update(conn, id)
  delete "/v1/codes/:id", do: Codes.delete(conn, id)
  get "/v1/codes/:id/codevalues", do: Codes.values(conn, id)
  post "/v1/codes/:id/codevalues", do: Codes.create_value(conn, id)
  get "/v1/codes/:id/codevalues/:value_id", do: Codes.show_value(conn, id, value_id)
  put "/v1/codes/:id/codevalues/:value_id", do: Codes.update_value(conn, id, value_id)
  delete "/v1/codes/:id/codevalues/:value_id", do: Codes.delete_value(conn, id, value_id)
  get "/v1/paymenttypes", do: PaymentTypes.index(conn)
  get "/v1/paymenttypes/:id", do: PaymentTypes.show(conn, id)
  post "/v1/paymenttypes", do: PaymentTypes.create(conn)
  put "/v1/paymenttypes/:id", do: PaymentTypes.update(conn, id)
  delete "/v1/paymenttypes/:id", do: PaymentTypes.delete(conn, id)
  get "/v1/workingdays/template", do: Organisation.working_days_template(conn)
  get "/v1/workingdays", do: Organisation.working_days(conn)
  put "/v1/workingdays", do: Organisation.update_working_days(conn)
  get "/v1/funds", do: Funds.index(conn)
  get "/v1/funds/:id", do: Funds.show(conn, id)
  post "/v1/funds", do: Funds.create(conn)
  put "/v1/funds/:id", do: Funds.update(conn, id)
  get "/v1/holidays/template", do: Organisation.holidays_template(conn)
  get "/v1/holidays", do: Organisation.holidays(conn)
  get "/v1/staff", do: Staff.index(conn)
  get "/v1/staff/:id", do: Staff.show(conn, id)
  post "/v1/staff", do: Staff.create(conn)
  put "/v1/staff/:id", do: Staff.update(conn, id)
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

  # Reads the JSON body. A body that is not JSON is answered here, as Fineract does, rather than
  # crashing the request.
  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, @parser_options)
  rescue
    error in Plug.Parsers.ParseError ->
      conn |> Errors.render(error) |> halt()
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    Errors.render(conn, Exception.normalize(kind, reason, stack))
  end
end
