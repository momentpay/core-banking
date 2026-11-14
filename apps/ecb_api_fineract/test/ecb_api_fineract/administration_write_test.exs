defmodule ECBApiFineract.AdministrationWriteTest do
  @moduledoc """
  Users, roles, configuration and the rest of administration beyond the responses recorded from Fineract
  (those are in `ScenariosTest`): that a new user can really sign in, that a changed password takes effect,
  what a deleted user can no longer do, and the places where E-CoreBank is stricter.
  """
  use ECBApiFineract.ApiCase

  alias ECBPlatform.TenantRepo

  @password "Zebra7-Mango#Quilt"
  @other_password "Quartz9-Lemon!Brin"

  defp send_json(method, path, body, auth \\ admin()),
    do: call(method, "/api" <> path, auth: auth, body: body)

  defp new_user(name, roles, extra \\ %{}) do
    send_json(
      :post,
      "/v1/users",
      Map.merge(
        %{
          "username" => name,
          "firstname" => "T",
          "lastname" => "T",
          "email" => "#{name}@example.test",
          "officeId" => 1,
          "roles" => roles,
          "sendPasswordToEmail" => false,
          "password" => @password,
          "repeatPassword" => @password
        },
        extra
      )
    )
  end

  defp role_with(permissions) do
    %{"resourceId" => id} =
      send_json(:post, "/v1/roles", %{
        "name" => "r#{System.unique_integer([:positive])}",
        "description" => "d"
      })
      |> body()

    send_json(:put, "/v1/roles/#{id}/permissions", %{
      "permissions" => Map.new(permissions, &{&1, true})
    })

    id
  end

  describe "a new user" do
    test "is stored with a bcrypt hash and can sign in" do
      role = role_with(["READ_OFFICE"])
      assert new_user("ada", [role]).status == 200

      assert %{rows: [["{bcrypt}$2" <> _]]} =
               TenantRepo.query!("SELECT password FROM m_appuser WHERE username = 'ada'")

      assert call(:get, "/api/v1/offices", auth: {"ada", @password}).status == 200
      assert call(:get, "/api/v1/offices", auth: {"ada", "wrong"}).status == 401
    end

    test "has only the permissions of their roles" do
      reader = role_with(["READ_OFFICE"])
      new_user("reader", [reader])

      assert call(:get, "/api/v1/offices", auth: {"reader", @password}).status == 200
      assert call(:get, "/api/v1/funds", auth: {"reader", @password}).status == 403

      send_json(:put, "/v1/roles/#{reader}/permissions", %{
        "permissions" => %{"READ_FUND" => true}
      })

      assert call(:get, "/api/v1/funds", auth: {"reader", @password}).status == 200
    end

    test "cannot be given the generated-password-by-email option without a mail server" do
      role = role_with([])

      conn =
        new_user("mailed", [role], %{
          "sendPasswordToEmail" => true,
          "password" => nil,
          "repeatPassword" => nil
        })

      assert conn.status == 400

      assert [%{"userMessageGlobalisationCode" => "error.msg.user.email.invalid"}] =
               body(conn)["errors"]
    end

    test "a request without a password is refused (where Fineract's own code fails with HTTP 500)" do
      role = role_with([])
      conn = new_user("nopass", [role], %{"password" => nil, "repeatPassword" => nil})

      assert conn.status == 400
      assert [%{"parameterName" => "password"}] = body(conn)["errors"]
    end
  end

  describe "the stored command" do
    test "holds no password, and is marked sanitized" do
      role = role_with([])
      %{"resourceId" => id} = new_user("ada", [role]) |> body()

      send_json(:post, "/v1/users/#{id}/pwd", %{
        "password" => @other_password,
        "repeatPassword" => @other_password
      })

      %{rows: rows} =
        TenantRepo.query!(
          "SELECT command_as_json, is_sanitized FROM m_portfolio_command_source WHERE entity_name = 'USER' ORDER BY id"
        )

      assert length(rows) == 2

      for [json, sanitized?] <- rows do
        refute json =~ @password
        refute json =~ @other_password
        assert json =~ ~s("password":"***")
        assert sanitized?
      end
    end
  end

  describe "changing a password" do
    test "takes effect at once: the old one stops working" do
      role = role_with(["READ_OFFICE"])
      %{"resourceId" => id} = new_user("ada", [role]) |> body()

      conn =
        send_json(:post, "/v1/users/#{id}/pwd", %{
          "password" => @other_password,
          "repeatPassword" => @other_password
        })

      assert conn.status == 200
      assert body(conn)["changes"] == %{"password" => true}

      assert call(:get, "/api/v1/offices", auth: {"ada", @other_password}).status == 200
      assert call(:get, "/api/v1/offices", auth: {"ada", @password}).status == 401
    end

    test "a password already used is refused when reuse checking is on, however the hash is salted" do
      role = role_with([])
      %{"resourceId" => id} = new_user("ada", [role]) |> body()
      send_json(:put, "/v1/configurations/62", %{"enabled" => true, "value" => 3})

      assert send_json(:post, "/v1/users/#{id}/pwd", %{
               "password" => @other_password,
               "repeatPassword" => @other_password
             }).status == 200

      conn =
        send_json(:post, "/v1/users/#{id}/pwd", %{
          "password" => @password,
          "repeatPassword" => @password
        })

      assert conn.status == 400

      assert [%{"userMessageGlobalisationCode" => "error.msg.password.already.used"}] =
               body(conn)["errors"]
    end

    test "can be done through the user update too" do
      role = role_with(["READ_OFFICE"])
      %{"resourceId" => id} = new_user("ada", [role]) |> body()

      assert send_json(:put, "/v1/users/#{id}", %{
               "password" => @other_password,
               "repeatPassword" => @other_password
             }).status == 200

      assert call(:get, "/api/v1/offices", auth: {"ada", @other_password}).status == 200
    end
  end

  describe "deleting a user" do
    test "ends their access, frees the username and removes their roles" do
      role = role_with(["READ_OFFICE"])
      %{"resourceId" => id} = new_user("ada", [role]) |> body()
      assert call(:get, "/api/v1/offices", auth: {"ada", @password}).status == 200

      assert call(:delete, "/api/v1/users/#{id}", auth: admin()).status == 200

      assert call(:get, "/api/v1/offices", auth: {"ada", @password}).status == 401

      assert %{rows: [[0]]} =
               TenantRepo.query!("SELECT count(*) FROM m_appuser_role WHERE appuser_id = $1", [id])

      assert %{rows: [[name]]} =
               TenantRepo.query!("SELECT username FROM m_appuser WHERE id = $1", [id])

      assert name == "#{id}_DELETED_ada"

      assert new_user("ada", [role]).status == 200
    end

    test "the role can then be deleted" do
      role = role_with([])
      %{"resourceId" => id} = new_user("ada", [role]) |> body()
      assert call(:delete, "/api/v1/roles/#{role}", auth: admin()).status == 403

      call(:delete, "/api/v1/users/#{id}", auth: admin())
      assert call(:delete, "/api/v1/roles/#{role}", auth: admin()).status == 200
    end
  end

  describe "roles" do
    test "a name in use is refused with its own message (where Fineract on PostgreSQL gives a generic error)" do
      send_json(:post, "/v1/roles", %{"name" => "Teller", "description" => "d"})
      conn = send_json(:post, "/v1/roles", %{"name" => "Teller", "description" => "d"})

      assert conn.status == 403
      assert body(conn)["userMessageGlobalisationCode"] == "error.msg.role.duplicate.name"
    end

    test "a role users hold cannot be disabled" do
      role = role_with([])
      new_user("ada", [role])

      conn = call(:post, "/api/v1/roles/#{role}?command=disable", auth: admin())
      assert conn.status == 403

      assert body(conn)["errors"] |> hd() |> Map.fetch!("userMessageGlobalisationCode") ==
               "error.msg.role.associated.with.users.disabled"
    end

    test "a disabled role gives its users nothing" do
      role = role_with(["READ_OFFICE"])
      new_user("ada", [role])
      assert call(:get, "/api/v1/offices", auth: {"ada", @password}).status == 200

      TenantRepo.query!("UPDATE m_role SET is_disabled = true WHERE id = $1", [role])
      assert call(:get, "/api/v1/offices", auth: {"ada", @password}).status == 403
    end

    test "a command other than enable or disable answers with no content, as Fineract does" do
      role = role_with([])
      conn = call(:post, "/api/v1/roles/#{role}?command=bogus", auth: admin())
      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "an empty permissions request is refused (where Fineract answers HTTP 500)" do
      role = role_with([])
      assert send_json(:put, "/v1/roles/#{role}/permissions", %{}).status == 400
    end
  end

  describe "configuration" do
    test "a restricted text property is stored in its canonical spelling" do
      conn =
        send_json(:put, "/v1/configurations/35", %{"stringValue" => "liability,ASSET, liability"})

      assert body(conn)["changes"] == %{"stringValue" => "Liability,Asset"}
    end

    test "the maker-checker switch can be turned on and off" do
      assert send_json(:put, "/v1/configurations/name/maker-checker", %{"enabled" => true}).status ==
               200

      assert call(:get, "/api/v1/configurations/name/maker-checker", auth: admin())
             |> body()
             |> Map.fetch!("enabled") == true

      assert send_json(:put, "/v1/configurations/name/maker-checker", %{"enabled" => false}).status ==
               200
    end

    test "a trap-door property cannot change once accounts exist" do
      TenantRepo.query!("CREATE TABLE m_loan (id bigint)")

      try do
        assert send_json(:put, "/v1/configurations/23", %{"value" => 3}).status == 200

        TenantRepo.query!("INSERT INTO m_loan VALUES (1)")
        conn = send_json(:put, "/v1/configurations/23", %{"value" => 2})
        assert conn.status == 403

        assert body(conn)["errors"] |> hd() |> Map.fetch!("userMessageGlobalisationCode") ==
                 "error.msg.configuration.id.not.modifiable"
      after
        TenantRepo.query!("DROP TABLE m_loan")
      end
    end
  end

  describe "password policy" do
    test "the active policy decides what a new password may be" do
      send_json(:put, "/v1/passwordpreferences", %{"validationPolicyId" => 1})
      role = role_with([])

      assert new_user("ada", [role], %{"password" => "a", "repeatPassword" => "a"}).status == 200
    end
  end
end
