defmodule ECBWeb.PageControllerTest do
  use ECBWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "E-CoreBank"
  end
end
