defmodule ECBApiFineract.Router do
  @moduledoc """
  The entry point, mounted at `/fineract-provider` by the web endpoint.

  The health check answers without a tenant or credentials, as Fineract's does; everything under
  `/api` goes to `ECBApiFineract.ApiRouter`.
  """
  use Plug.Router

  alias ECBApiFineract.Response

  plug :match
  plug :dispatch

  get "/actuator/health" do
    Response.json(conn, 200, %{"groups" => ["liveness", "readiness"], "status" => "UP"})
  end

  forward "/api", to: ECBApiFineract.ApiRouter

  match _ do
    send_resp(conn, 404, "")
  end
end
