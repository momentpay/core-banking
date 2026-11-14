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
  alias ECBApiFineract.Resources.{Authentication, Offices}

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

  match _ do
    Errors.not_implemented(conn, conn.method, conn.request_path)
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason, stack: stack}) do
    Errors.render(conn, Exception.normalize(kind, reason, stack))
  end
end
