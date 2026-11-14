defmodule ECBApiFineract.ApiCase do
  @moduledoc """
  Test setup and helpers for calling the Fineract-compatible API in-process.

  Uses a real tenant database of its own (`ecb_api_test`) and a registry entry for it, created per
  test inside the SQL sandbox. `call/3` sends a request through `ECBApiFineract.Router` exactly as the
  web endpoint would.
  """
  use ExUnit.CaseTemplate

  alias ECBPlatform.TenantRepo

  using do
    quote do
      use ECBPlatform.TenantCase, database: "ecb_api_test", reset: false

      import Plug.Conn
      import Plug.Test
      import ECBApiFineract.ApiCase
    end
  end

  setup do
    # the tenant registry lives in its own database, isolated per test by the SQL sandbox
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ECBPlatform.Repo)
    tenant = ECBPlatform.TenantCase.tenant("ecb_api_test")

    {:ok, _} =
      ECBPlatform.Tenancy.create_tenant(%{
        identifier: "apitest",
        name: "API test tenant",
        db_host: tenant.db_host,
        db_port: tenant.db_port,
        db_name: tenant.db_name,
        db_username: tenant.db_username,
        pool_size: 5
      })

    ECBPlatform.TenantCase.setup_tenant("ecb_api_test", false)
    clean_test_data()
    :ok
  end

  @doc "Removes the users, roles and offices tests create, leaving the seeded rows."
  def clean_test_data do
    # commands are committed on their own as they run, so they outlive a test; they refer to users
    TenantRepo.query!("DELETE FROM m_portfolio_command_source")

    TenantRepo.query!(
      "DELETE FROM m_appuser_role WHERE appuser_id IN (SELECT id FROM m_appuser WHERE username LIKE 'apitest-%')"
    )

    TenantRepo.query!("DELETE FROM m_appuser WHERE username LIKE 'apitest-%'")

    TenantRepo.query!(
      "DELETE FROM m_role_permission WHERE role_id IN (SELECT id FROM m_role WHERE name LIKE 'apitest-%')"
    )

    TenantRepo.query!("DELETE FROM m_role WHERE name LIKE 'apitest-%'")
    TenantRepo.query!("DELETE FROM m_code_value WHERE id > 22")
    TenantRepo.query!("DELETE FROM m_code WHERE is_system_defined = false")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_code', 'id'), 49)")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_code_value', 'id'), 22)")

    TenantRepo.query!(
      "UPDATE m_code_value SET code_value = 'Passport', code_description = NULL, order_position = 1, is_active = true WHERE id = 1"
    )

    TenantRepo.query!(
      "UPDATE m_working_days SET recurrence = 'FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR,SA,SU', repayment_rescheduling_enum = 2, extend_term_daily_repayments = false, extend_term_holiday_repayment = false"
    )

    TenantRepo.query!("DELETE FROM m_holiday_office")
    TenantRepo.query!("DELETE FROM m_holiday")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_holiday', 'id'), 1, false)")
    TenantRepo.query!("DELETE FROM m_staff")
    TenantRepo.query!("DELETE FROM m_fund")
    TenantRepo.query!("DELETE FROM m_payment_type WHERE id > 3")
    TenantRepo.query!("DELETE FROM m_office WHERE id > 1")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_staff', 'id'), 1, false)")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_fund', 'id'), 1, false)")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_payment_type', 'id'), 3)")

    # ids start again from 2, as they do on a freshly seeded Fineract (what the recorded scenarios assume)
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_office', 'id'), 1)")
  end

  @doc """
  Sends a request through the router. Options: `:headers` (default: the test tenant), `:body` (a map,
  sent as JSON) and `:auth` (`{username, password}` for HTTP basic).
  """
  def call(method, path, opts \\ []) do
    headers = Keyword.get(opts, :headers, [{"fineract-platform-tenantid", "apitest"}])

    conn =
      case opts[:body] do
        nil ->
          Plug.Test.conn(method, path)

        body ->
          Plug.Test.conn(method, path, Jason.encode!(body))
          |> Plug.Conn.put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    conn =
      case opts[:auth] do
        {user, pass} ->
          Plug.Conn.put_req_header(
            conn,
            "authorization",
            "Basic " <> Base.encode64(user <> ":" <> pass)
          )

        nil ->
          conn
      end

    ECBApiFineract.Router.call(conn, ECBApiFineract.Router.init([]))
  end

  @doc "Fineract's seeded administrator."
  def admin, do: {"mifos", "password"}

  @doc "The response body, decoded."
  def body(conn), do: Jason.decode!(conn.resp_body)

  @doc "A user in the test tenant with the given permissions; returns `{username, password}`."
  def make_user(name, permissions, opts \\ []) do
    username = "apitest-" <> name

    %{rows: [[role_id]]} =
      TenantRepo.query!(
        "INSERT INTO m_role (name, description, is_disabled) VALUES ($1, 'test', false) RETURNING id",
        ["apitest-" <> name]
      )

    for code <- permissions do
      TenantRepo.query!(
        "INSERT INTO m_role_permission (role_id, permission_id) SELECT $1, id FROM m_permission WHERE code = $2",
        [role_id, code]
      )
    end

    %{rows: [[user_id]]} =
      TenantRepo.query!(
        """
        INSERT INTO m_appuser (office_id, username, firstname, lastname, password, email, firsttime_login_remaining,
                               nonexpired, nonlocked, nonexpired_credentials, enabled)
        VALUES (1, $1, 'T', 'T', $2, 't@example.test', false, $3, $4, true, $5) RETURNING id
        """,
        [
          username,
          hash("secret"),
          Keyword.get(opts, :nonexpired, true),
          Keyword.get(opts, :nonlocked, true),
          Keyword.get(opts, :enabled, true)
        ]
      )

    TenantRepo.query!("INSERT INTO m_appuser_role (appuser_id, role_id) VALUES ($1, $2)", [
      user_id,
      role_id
    ])

    {username, "secret"}
  end

  @doc "A password hash in Fineract's legacy scheme."
  def hash(password, salt \\ "7"),
    do:
      "{SHA-256}{#{salt}}" <>
        (:crypto.hash(:sha256, password <> "{#{salt}}") |> Base.encode16(case: :lower))

  @doc "The first place two JSON values differ, as `{path, wanted, got}`, or `nil` when they are equal. Object key order is not compared; list order is."
  def first_difference(same, same, _path), do: nil

  def first_difference(%{} = want, %{} = got, path) do
    keys = MapSet.union(MapSet.new(Map.keys(want)), MapSet.new(Map.keys(got))) |> Enum.sort()

    Enum.find_value(keys, fn key ->
      cond do
        not Map.has_key?(got, key) -> {"#{path}.#{key}", Map.fetch!(want, key), :missing}
        not Map.has_key?(want, key) -> {"#{path}.#{key}", :missing, Map.fetch!(got, key)}
        true -> first_difference(Map.fetch!(want, key), Map.fetch!(got, key), "#{path}.#{key}")
      end
    end)
  end

  def first_difference(want, got, path) when is_list(want) and is_list(got) do
    if length(want) != length(got) do
      {path <> " (list length)", length(want), length(got)}
    else
      want
      |> Enum.zip(got)
      |> Enum.with_index()
      |> Enum.find_value(fn {{w, g}, i} -> first_difference(w, g, "#{path}[#{i}]") end)
    end
  end

  def first_difference(want, got, path), do: {path, want, got}
end
