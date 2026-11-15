defmodule ECBApiFineract.ClientsTest do
  @moduledoc """
  Clients beyond the responses recorded from Fineract (those are in `ScenariosTest`): permissions, who
  can see whose clients, account numbers and the commands recorded for each write.
  """
  use ECBApiFineract.ApiCase

  import Ecto.Query

  alias ECBPlatform.TenantRepo

  defp send_json(method, path, body \\ nil, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp client(extra \\ %{}) do
    request =
      Map.merge(
        %{
          "officeId" => 1,
          "legalFormId" => 1,
          "firstname" => "Asha",
          "lastname" => "Rao",
          "dateFormat" => "dd MMMM yyyy",
          "locale" => "en"
        },
        extra
      )

    conn = send_json(:post, "/v1/clients", request)
    assert conn.status == 200, conn.resp_body
    body(conn)["resourceId"]
  end

  describe "permissions" do
    test "reading needs READ_CLIENT and each write its own permission" do
      id = client(%{"submittedOnDate" => "01 January 2026"})

      assert send_json(:get, "/v1/clients", nil, make_user("c-none", [])).status == 403

      assert send_json(:get, "/v1/clients", nil, make_user("c-reader", ["READ_CLIENT"])).status ==
               200

      assert send_json(:get, "/v1/clients/#{id}", nil, make_user("c-reader-2", ["READ_CLIENT"])).status ==
               200

      body = %{"firstname" => "New", "lastname" => "Name"}

      assert send_json(:put, "/v1/clients/#{id}", body, make_user("c-no-update", ["READ_CLIENT"])).status ==
               403

      assert send_json(:put, "/v1/clients/#{id}", body, make_user("c-update", ["UPDATE_CLIENT"])).status ==
               200

      activate = %{
        "activationDate" => "01 January 2026",
        "dateFormat" => "dd MMMM yyyy",
        "locale" => "en"
      }

      path = "/v1/clients/#{id}?command=activate"

      assert send_json(:post, path, activate, make_user("c-no-activate", ["UPDATE_CLIENT"])).status ==
               403

      assert send_json(:post, path, activate, make_user("c-activate", ["ACTIVATE_CLIENT"])).status ==
               200

      assert send_json(
               :delete,
               "/v1/clients/#{id}",
               nil,
               make_user("c-no-delete", ["UPDATE_CLIENT"])
             ).status == 403
    end
  end

  describe "who can see which clients" do
    test "a user sees the clients of their own office and the offices below, not those above" do
      TenantRepo.query!("""
      INSERT INTO m_office (id, parent_id, name, hierarchy, opening_date)
      OVERRIDING SYSTEM VALUE VALUES (50, 1, 'Branch', '.1.50.', '2020-01-01')
      """)

      head = client()
      branch = client(%{"officeId" => 50, "firstname" => "Branch", "lastname" => "Client"})

      {name, password} = make_user("c-branch", ["READ_CLIENT"])
      TenantRepo.query!("UPDATE m_appuser SET office_id = 50 WHERE username = $1", [name])
      branch_user = {name, password}

      seen = send_json(:get, "/v1/clients", nil, branch_user)
      assert [%{"id" => ^branch}] = body(seen)["pageItems"]
      assert send_json(:get, "/v1/clients/#{head}", nil, branch_user).status == 404
      assert send_json(:get, "/v1/clients/#{branch}", nil, branch_user).status == 200

      assert length(body(send_json(:get, "/v1/clients"))["pageItems"]) == 2
    end
  end

  describe "account numbers" do
    test "a client gets nine digits from its id unless it brings its own" do
      id = client()

      assert body(send_json(:get, "/v1/clients/#{id}"))["accountNo"] ==
               String.pad_leading("#{id}", 9, "0")

      own = client(%{"accountNo" => "MY-1", "firstname" => "Own"})
      assert body(send_json(:get, "/v1/clients/#{own}"))["accountNo"] == "MY-1"
    end

    test "the tenant's client format adds a prefix" do
      TenantRepo.query!(
        "INSERT INTO c_account_number_format (account_type_enum, prefix_type_enum) VALUES (1, 1)"
      )

      id = client()

      assert body(send_json(:get, "/v1/clients/#{id}"))["accountNo"] ==
               "Head Offic" <> String.pad_leading("#{id}", 9, "0")
    after
      TenantRepo.query!("DELETE FROM c_account_number_format")
    end
  end

  describe "what is stored" do
    test "isStaff is accepted and never stored, as in Fineract" do
      id = client(%{"isStaff" => true})
      assert body(send_json(:get, "/v1/clients/#{id}"))["isStaff"] == false
    end

    test "a client is pending until activated, and active clients cannot be deleted" do
      pending = client()
      assert body(send_json(:get, "/v1/clients/#{pending}"))["status"]["value"] == "Pending"

      active =
        client(%{"active" => true, "activationDate" => "01 January 2026", "firstname" => "Act"})

      refused = send_json(:delete, "/v1/clients/#{active}")
      assert refused.status == 403

      assert hd(body(refused)["errors"])["userMessageGlobalisationCode"] ==
               "error.msg.clients.cannot.be.deleted"

      assert send_json(:delete, "/v1/clients/#{pending}").status == 200
      assert TenantRepo.aggregate("m_client", :count) == 1
    end

    test "every write is recorded as a command" do
      id = client()
      send_json(:put, "/v1/clients/#{id}", %{"firstname" => "Changed"})

      actions =
        TenantRepo.all(
          from(c in "m_portfolio_command_source",
            where: c.entity_name == "CLIENT",
            order_by: c.id,
            select: c.action_name
          )
        )

      assert actions == ["CREATE", "UPDATE"]
    end
  end

  describe "identifiers" do
    test "reading needs READ_CLIENTIDENTIFIER and each write its own permission" do
      id = client()
      path = "/v1/clients/#{id}/identifiers"

      request = %{
        "documentTypeId" => 1,
        "documentKey" => "P1",
        "status" => "Active",
        "locale" => "en"
      }

      assert send_json(:get, path, nil, make_user("i-none", [])).status == 403

      assert send_json(:get, path, nil, make_user("i-read", ["READ_CLIENTIDENTIFIER"])).status ==
               200

      assert send_json(:post, path, request, make_user("i-no-create", ["READ_CLIENTIDENTIFIER"])).status ==
               403

      creator = make_user("i-create", ["CREATE_CLIENTIDENTIFIER"])
      created = send_json(:post, path, request, creator)
      assert created.status == 200
      identifier = body(created)["resourceId"]

      assert send_json(:delete, path <> "/#{identifier}", nil, creator).status == 403
      deleter = make_user("i-delete", ["DELETE_CLIENTIDENTIFIER"])
      assert send_json(:delete, path <> "/#{identifier}", nil, deleter).status == 200
    end

    test "a status is needed to create an identifier, as Fineract fails without one" do
      id = client()
      request = %{"documentTypeId" => 1, "documentKey" => "P2", "locale" => "en"}
      assert send_json(:post, "/v1/clients/#{id}/identifiers", request).status == 500
    end
  end

  describe "family members" do
    test "reading needs READ_FAMILYMEMBERS and each write its own permission" do
      id = client()

      TenantRepo.query!(
        "INSERT INTO m_code_value (code_id, code_value, order_position) VALUES (31, 'Mother', 1)"
      )

      relationship =
        TenantRepo.one(from(v in "m_code_value", where: v.code_value == "Mother", select: v.id))

      path = "/v1/clients/#{id}/familymembers"
      request = %{"firstName" => "Mum", "relationshipId" => relationship, "locale" => "en"}

      assert send_json(:get, path, nil, make_user("f-none", [])).status == 403
      assert send_json(:get, path, nil, make_user("f-read", ["READ_FAMILYMEMBERS"])).status == 200

      assert send_json(:post, path, request, make_user("f-no-create", ["READ_FAMILYMEMBERS"])).status ==
               403

      assert send_json(:post, path, request, make_user("f-create", ["CREATE_FAMILYMEMBERS"])).status ==
               200
    end
  end
end
