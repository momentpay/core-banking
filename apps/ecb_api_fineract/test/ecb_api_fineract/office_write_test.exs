defmodule ECBApiFineract.OfficeWriteTest do
  @moduledoc """
  What creating and updating offices does beyond the responses recorded from Fineract (those are in
  `ScenariosTest`): the command that is stored, idempotent replays, who may write, and the places where
  E-CoreBank is deliberately stricter or more helpful than the Fineract release it follows.
  """
  use ECBApiFineract.ApiCase

  alias ECBPlatform.TenantRepo

  @date %{"openingDate" => "01 March 2020", "dateFormat" => "dd MMMM yyyy", "locale" => "en"}

  defp create(name, parent_id, extra \\ %{}) do
    call(:post, "/api/v1/offices",
      auth: admin(),
      body: Map.merge(%{"name" => name, "parentId" => parent_id}, Map.merge(@date, extra))
    )
  end

  defp office(id), do: call(:get, "/api/v1/offices/#{id}", auth: admin()) |> body()

  describe "storing the command" do
    test "a created office leaves a processed command behind" do
      assert create("Nairobi", 1).status == 200

      assert %{rows: [["CREATE", "OFFICE", status, 200]]} =
               TenantRepo.query!(
                 "SELECT action_name, entity_name, status, result_status_code FROM m_portfolio_command_source WHERE entity_name = 'OFFICE' ORDER BY id DESC LIMIT 1"
               )

      assert status == 1
    end

    test "a failed command is recorded as an error" do
      assert create("", 1).status == 400

      error = ECBPlatform.Commands.ResultType.to_int(:error)

      assert %{rows: [[^error, 400]]} =
               TenantRepo.query!(
                 "SELECT status, result_status_code FROM m_portfolio_command_source WHERE entity_name = 'OFFICE' ORDER BY id DESC LIMIT 1"
               )
    end
  end

  describe "idempotency" do
    test "the same key gives the first answer again and creates nothing twice" do
      headers = [{"fineract-platform-tenantid", "apitest"}, {"idempotency-key", "office-key-1"}]

      request = fn ->
        call(:post, "/api/v1/offices",
          auth: admin(),
          headers: headers,
          body: Map.merge(%{"name" => "Once", "parentId" => 1}, @date)
        )
      end

      first = request.()
      second = request.()

      assert first.status == 200
      assert second.status == 200
      assert body(second) == body(first)
      assert get_resp_header(second, "x-served-from-cache") == ["true"]

      assert %{rows: [[1]]} =
               TenantRepo.query!("SELECT count(*) FROM m_office WHERE name = 'Once'")
    end
  end

  describe "who may write" do
    test "a user who can only read offices is refused" do
      user = make_user("reader", ["READ_OFFICE"])

      conn =
        call(:post, "/api/v1/offices",
          auth: user,
          body: Map.merge(%{"name" => "No", "parentId" => 1}, @date)
        )

      assert conn.status == 403
      assert body(conn)["userMessageGlobalisationCode"] == "error.msg.not.authorized"
      assert %{rows: [[0]]} = TenantRepo.query!("SELECT count(*) FROM m_office WHERE name = 'No'")
    end

    test "a user may only act on offices at or below their own" do
      assert create("Nairobi", 1).status == 200
      assert create("Mombasa", 1).status == 200
      user = make_user("branch", ["CREATE_OFFICE", "UPDATE_OFFICE"])
      TenantRepo.query!("UPDATE m_appuser SET office_id = 2 WHERE username = 'apitest-branch'")

      under_own =
        call(:post, "/api/v1/offices",
          auth: user,
          body: Map.merge(%{"name" => "Westlands", "parentId" => 2}, @date)
        )

      beside =
        call(:post, "/api/v1/offices",
          auth: user,
          body: Map.merge(%{"name" => "Other", "parentId" => 3}, @date)
        )

      head = call(:put, "/api/v1/offices/1", auth: user, body: %{"name" => "Hijack"})

      assert under_own.status == 200
      assert beside.status == 403
      assert head.status == 403
      assert office(1)["name"] == "Head Office"
    end
  end

  describe "duplicates" do
    test "a name already in use is refused with its own message" do
      assert create("Nairobi", 1).status == 200
      conn = create("Nairobi", 1)

      assert conn.status == 403

      assert %{
               "userMessageGlobalisationCode" => "error.msg.office.duplicate.name",
               "defaultUserMessage" => "Office with name `Nairobi` already exists",
               "errors" => [%{"parameterName" => "name", "args" => [%{"value" => "Nairobi"}]}]
             } = body(conn)
    end

    test "an external id already in use is refused with its own message" do
      assert create("Nairobi", 1, %{"externalId" => "NBO"}).status == 200
      conn = create("Mombasa", 1, %{"externalId" => "NBO"})

      assert conn.status == 403
      assert body(conn)["userMessageGlobalisationCode"] == "error.msg.office.duplicate.externalId"
    end
  end

  describe "moving an office" do
    setup do
      # 1 > 2 (Nairobi) > 3 (Westlands) > 4 (Parklands);  1 > 5 (Mombasa)
      assert create("Nairobi", 1).status == 200
      assert create("Westlands", 2).status == 200
      assert create("Parklands", 3).status == 200
      assert create("Mombasa", 1).status == 200
      :ok
    end

    test "everything beneath it moves too" do
      assert office(4)["hierarchy"] == ".2.3.4."

      conn = call(:put, "/api/v1/offices/3", auth: admin(), body: %{"parentId" => 5})

      assert conn.status == 200
      assert body(conn)["changes"] == %{"parentId" => 5}
      assert office(3)["hierarchy"] == ".5.3."
      assert office(4)["hierarchy"] == ".5.3.4."
      assert office(2)["hierarchy"] == ".2."
    end

    test "an office cannot be moved under one of its own sub-offices" do
      conn = call(:put, "/api/v1/offices/2", auth: admin(), body: %{"parentId" => 4})

      assert conn.status == 403

      assert body(conn)["errors"] |> hd() |> Map.fetch!("userMessageGlobalisationCode") ==
               "error.msg.office.parentId.is.descendant"

      assert office(2)["hierarchy"] == ".2."
      assert office(4)["hierarchy"] == ".2.3.4."
    end
  end

  describe "malformed requests" do
    test "a body that is not JSON is a 400 about the body" do
      {user, password} = admin()

      conn =
        Plug.Test.conn(:post, "/api/v1/offices", "{bad json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("fineract-platform-tenantid", "apitest")
        |> put_req_header("authorization", "Basic " <> Base.encode64(user <> ":" <> password))
        |> then(&ECBApiFineract.Router.call(&1, ECBApiFineract.Router.init([])))

      assert conn.status == 400
      assert body(conn)["userMessageGlobalisationCode"] == "error.msg.invalid.request.body"
    end

    test "an id that is not a number is not an office" do
      conn = call(:put, "/api/v1/offices/abc", auth: admin(), body: %{"name" => "x"})
      assert conn.status == 404
    end
  end
end
