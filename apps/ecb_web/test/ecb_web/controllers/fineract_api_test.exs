defmodule ECBWeb.FineractApiTest do
  @moduledoc """
  The compatible API as mounted in the web endpoint (the API's own tests call its router directly, so
  these cover what only the endpoint does: reading request bodies).
  """
  use ECBWeb.ConnCase

  test "a request body that is not JSON is answered the way Fineract answers it", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/fineract-provider/api/v1/offices", "{bad json")

    assert %{"userMessageGlobalisationCode" => "error.msg.invalid.request.body"} =
             json_response(conn, 400)
  end

  test "the health check answers", %{conn: conn} do
    assert conn |> get("/fineract-provider/actuator/health") |> json_response(200)
  end
end
