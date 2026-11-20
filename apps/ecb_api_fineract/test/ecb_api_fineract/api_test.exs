defmodule ECBApiFineract.ApiTest do
  @moduledoc """
  The expected responses below were captured from a running Apache Fineract 1.16.1 (the oracle), so
  these tests pin E-CoreBank to what Fineract actually sends, including its failure cases.
  """
  use ECBApiFineract.ApiCase

  alias ECBApiFineract.Router

  @head_office %{
    "id" => 1,
    "name" => "Head Office",
    "nameDecorated" => "Head Office",
    "externalId" => "1",
    "openingDate" => [2009, 1, 1],
    "hierarchy" => "."
  }

  # --- health ---------------------------------------------------------------------------------

  test "health answers without a tenant or credentials" do
    conn = call(:get, "/actuator/health", headers: [])
    assert conn.status == 200
    assert body(conn) == %{"groups" => ["liveness", "readiness"], "status" => "UP"}
  end

  # --- tenant and authentication (what Fineract answers, including the failures) ----------------

  describe "tenant resolution" do
    test "a missing tenant is HTTP 400 in the web container's error shape" do
      conn = call(:get, "/api/v1/offices", headers: [], auth: admin())
      assert conn.status == 400

      assert %{
               "status" => 400,
               "error" => "Bad Request",
               "path" => "/api/v1/offices",
               "timestamp" => _
             } = body(conn)

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Basic realm="Fineract Platform API")
             ]
    end

    test "an unknown tenant is the same HTTP 400" do
      conn =
        call(:get, "/api/v1/offices",
          headers: [{"fineract-platform-tenantid", "nope"}],
          auth: admin()
        )

      assert conn.status == 400
      assert body(conn)["error"] == "Bad Request"
    end

    test "the tenantIdentifier query parameter works too" do
      conn = call(:get, "/api/v1/offices?tenantIdentifier=apitest", headers: [], auth: admin())
      assert conn.status == 200
    end
  end

  describe "basic authentication" do
    test "no credentials: 401, no body, and a challenge" do
      conn = call(:get, "/api/v1/offices")
      assert conn.status == 401
      assert conn.resp_body == ""

      assert get_resp_header(conn, "www-authenticate") == [
               ~s(Basic realm="Fineract Platform API", charset="UTF-8")
             ]
    end

    test "wrong password: 401 with the web container's error body" do
      conn = call(:get, "/api/v1/offices", auth: {"mifos", "wrong"})
      assert conn.status == 401

      assert %{"status" => 401, "error" => "Unauthorized", "path" => "/api/v1/offices"} =
               body(conn)
    end

    test "an unknown user is refused the same way" do
      assert call(:get, "/api/v1/offices", auth: {"ghost", "password"}).status == 401
    end

    test "a locked, expired or disabled account is refused" do
      for {name, opts} <- [
            {"locked", [nonlocked: false]},
            {"expired", [nonexpired: false]},
            {"disabled", [enabled: false]}
          ] do
        {user, pass} = make_user(name, ["ALL_FUNCTIONS"], opts)
        assert call(:get, "/api/v1/offices", auth: {user, pass}).status == 401, "#{name} account"
      end
    end

    test "a deleted user is refused" do
      {user, pass} = make_user("gone", ["ALL_FUNCTIONS"])
      TenantRepo.query!("UPDATE m_appuser SET is_deleted = true WHERE username = $1", [user])
      assert call(:get, "/api/v1/offices", auth: {user, pass}).status == 401
    end
  end

  describe "POST /v1/authentication" do
    test "tells a signed-in user who they are, as Fineract does" do
      conn =
        call(:post, "/api/v1/authentication",
          body: %{"username" => "mifos", "password" => "password"}
        )

      assert conn.status == 200

      assert %{
               "username" => "mifos",
               "userId" => 1,
               "base64EncodedAuthenticationKey" => "bWlmb3M6cGFzc3dvcmQ=",
               "authenticated" => true,
               "officeId" => 1,
               "officeName" => "Head Office",
               "roles" => [
                 %{
                   "id" => 1,
                   "name" => "Super user",
                   "description" => "This role provides all application permissions.",
                   "disabled" => false
                 }
               ],
               "permissions" => [
                 "ALL_FUNCTIONS",
                 "FORCE_WITHDRAWAL_SAVINGSACCOUNT",
                 "FORCE_WITHDRAWAL_SAVINGSACCOUNT_CHECKER"
               ],
               "shouldRenewPassword" => false,
               "isTwoFactorAuthenticationRequired" => false
             } = body(conn)
    end

    test "the key it returns works as the basic credentials" do
      key =
        call(:post, "/api/v1/authentication",
          body: %{"username" => "mifos", "password" => "password"}
        )
        |> body()
        |> Map.fetch!("base64EncodedAuthenticationKey")

      conn = call(:get, "/api/v1/offices") |> recycle_with_key(key)
      assert conn.status == 200
    end

    test "wrong credentials: 401 in Fineract's platform error shape" do
      conn =
        call(:post, "/api/v1/authentication",
          body: %{"username" => "mifos", "password" => "nope"}
        )

      assert conn.status == 401

      assert body(conn) == %{
               "developerMessage" => "Invalid authentication details were passed in api request.",
               "httpStatusCode" => "401",
               "defaultUserMessage" => "Unauthenticated. Please login.",
               "userMessageGlobalisationCode" => "error.msg.not.authenticated"
             }
    end

    test "a missing username or password is 401 as well" do
      assert call(:post, "/api/v1/authentication", body: %{"username" => "mifos"}).status == 401
      assert call(:post, "/api/v1/authentication", body: %{}).status == 401
    end
  end

  defp recycle_with_key(_first, key) do
    conn(:get, "/api/v1/offices")
    |> put_req_header("fineract-platform-tenantid", "apitest")
    |> put_req_header("authorization", "Basic " <> key)
    |> then(&Router.call(&1, Router.init([])))
  end

  # --- offices --------------------------------------------------------------------------------

  describe "GET /v1/offices" do
    test "lists the head office exactly as Fineract does" do
      conn = call(:get, "/api/v1/offices", auth: admin())
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      assert body(conn) == [@head_office]
    end

    test "leaves out null fields and writes dates as arrays" do
      TenantRepo.query!(
        "INSERT INTO m_office (id, parent_id, hierarchy, name, opening_date) VALUES (2, 1, '.2.', 'Nairobi', '2020-01-15')"
      )

      [_, nairobi] = call(:get, "/api/v1/offices", auth: admin()) |> body()

      assert nairobi == %{
               "id" => 2,
               "name" => "Nairobi",
               "nameDecorated" => "....Nairobi",
               "openingDate" => [2020, 1, 15],
               "hierarchy" => ".2.",
               "parentId" => 1,
               "parentName" => "Head Office"
             }

      refute Map.has_key?(nairobi, "externalId")
    end

    test "honours orderBy and sortOrder" do
      TenantRepo.query!(
        "INSERT INTO m_office (parent_id, hierarchy, name, opening_date) VALUES (1, '.2.', 'Zeta', '2020-01-15')"
      )

      names = fn conn -> conn |> body() |> Enum.map(& &1["name"]) end

      assert call(:get, "/api/v1/offices?orderBy=name&sortOrder=desc", auth: admin()) |> names.() ==
               ["Zeta", "Head Office"]

      assert call(:get, "/api/v1/offices?orderBy=name", auth: admin()) |> names.() == [
               "Head Office",
               "Zeta"
             ]
    end

    test "refuses an order field that is not allowed, with HTTP 403" do
      conn = call(:get, "/api/v1/offices?orderBy=name;DROP", auth: admin())
      assert conn.status == 403

      assert %{
               "userMessageGlobalisationCode" => "validation.msg.domain.rule.violation",
               "httpStatusCode" => "403"
             } = body(conn)
    end

    test "needs READ_OFFICE" do
      {user, pass} = make_user("noread", ["READ_CLIENT"])
      conn = call(:get, "/api/v1/offices", auth: {user, pass})
      assert conn.status == 403

      assert %{
               "httpStatusCode" => "403",
               "userMessageGlobalisationCode" => "error.msg.not.authorized",
               "defaultUserMessage" => "Insufficient privileges to perform this action.",
               "errors" => [%{"defaultUserMessage" => "User has no authority to READ offices"}]
             } = body(conn)
    end

    test "READ_OFFICE, ALL_FUNCTIONS_READ and ALL_FUNCTIONS are each enough" do
      for {name, codes} <- [
            {"a", ["READ_OFFICE"]},
            {"b", ["ALL_FUNCTIONS_READ"]},
            {"c", ["ALL_FUNCTIONS"]}
          ] do
        TenantRepo.query!(
          "INSERT INTO m_permission (\"grouping\", code, can_maker_checker) VALUES ('test', 'ALL_FUNCTIONS_READ', false) ON CONFLICT DO NOTHING"
        )

        {user, pass} = make_user(name, codes)

        assert call(:get, "/api/v1/offices", auth: {user, pass}).status == 200,
               "permissions #{inspect(codes)}"
      end
    end
  end

  describe "GET /v1/offices/{id}" do
    test "returns one office" do
      conn = call(:get, "/api/v1/offices/1", auth: admin())
      assert conn.status == 200
      assert body(conn) == @head_office
    end

    test "an unknown id is Fineract's 404 body" do
      conn = call(:get, "/api/v1/offices/999", auth: admin())
      assert conn.status == 404

      assert body(conn) == %{
               "developerMessage" => "The requested resource is not available.",
               "httpStatusCode" => "404",
               "defaultUserMessage" => "The requested resource is not available.",
               "userMessageGlobalisationCode" => "error.msg.resource.not.found",
               "errors" => [
                 %{
                   "developerMessage" => "Office with identifier 999 does not exist",
                   "defaultUserMessage" => "Office with identifier 999 does not exist",
                   "userMessageGlobalisationCode" => "error.msg.office.id.invalid",
                   "parameterName" => "id",
                   "args" => [%{"value" => 999}]
                 }
               ]
             }
    end

    test "an id that is not a number is also not found" do
      assert call(:get, "/api/v1/offices/abc", auth: admin()).status == 404
    end
  end

  describe "GET /v1/offices/template" do
    test "offers today and the possible parents" do
      conn = call(:get, "/api/v1/offices/template", auth: admin())
      assert conn.status == 200
      today = Date.utc_today()

      assert body(conn) == %{
               "openingDate" => [today.year, today.month, today.day],
               "allowedParents" => [
                 %{"id" => 1, "name" => "Head Office", "nameDecorated" => "Head Office"}
               ]
             }
    end
  end

  # --- everything else ------------------------------------------------------------------------

  test "an operation that is in Fineract's API but not built yet is HTTP 501, not 404" do
    conn = call(:get, "/api/v1/fixeddepositaccounts", auth: admin())
    assert conn.status == 501

    assert %{
             "httpStatusCode" => "501",
             "userMessageGlobalisationCode" => "validation.msg.not.implemented",
             "errors" => [
               %{
                 "developerMessage" =>
                   "GET /api/v1/fixeddepositaccounts is not implemented in E-CoreBank yet"
               }
             ]
           } = body(conn)
  end

  test "an unauthenticated request for something not built yet is still refused first" do
    assert call(:get, "/api/v1/loans").status == 401
  end

  test "the raw request body is kept next to the parsed one, for commands that store it as text" do
    raw = ~s({"username":  "mifos",  "password":"password"})

    conn =
      conn(:post, "/api/v1/authentication", raw)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("fineract-platform-tenantid", "apitest")
      |> then(&Router.call(&1, Router.init([])))

    assert conn.status == 200
    assert conn.assigns.raw_body == raw
  end
end
