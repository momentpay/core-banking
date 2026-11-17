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
      "SELECT setval(pg_get_serial_sequence('m_portfolio_command_source', 'id'), 1, false)"
    )

    # configuration, password policy and maker-checker flags that tests change
    for sql <- [
          "UPDATE c_configuration SET enabled = false, value = NULL, string_value = NULL, date_value = NULL WHERE id = 1",
          "UPDATE c_configuration SET enabled = true, value = 2 WHERE id = 10",
          "UPDATE c_configuration SET enabled = false, value = 0 WHERE id = 11",
          "UPDATE c_configuration SET enabled = true, value = 6 WHERE id = 23",
          "UPDATE c_configuration SET enabled = true, string_value = 'Asset' WHERE id = 35",
          "UPDATE c_configuration SET enabled = false, value = 3 WHERE id = 62",
          "UPDATE c_configuration SET enabled = false WHERE id = 44",
          "UPDATE c_configuration SET enabled = true WHERE id = 45",
          "DELETE FROM m_business_date",
          "DELETE FROM job_run_history",
          "UPDATE job SET previous_run_start_time = NULL, currently_running = false",
          "UPDATE m_password_validation_policy SET active = (id = 3)",
          "UPDATE m_permission SET can_maker_checker = false WHERE code IN ('CREATE_OFFICE', 'UPDATE_OFFICE', 'CREATE_CLIENT', 'DELETE_FUND', 'CREATE_FUND')"
        ] do
      TenantRepo.query!(sql)
    end

    # loans refer to clients, products and users
    for sql <- [
          "DELETE FROM acc_gl_journal_entry",
          "DELETE FROM m_note WHERE loan_id IS NOT NULL",
          "DELETE FROM m_loan_transaction_repayment_schedule_mapping",
          "DELETE FROM m_loan_charge_paid_by",
          "DELETE FROM m_loan_transaction_relation",
          "DELETE FROM m_loan_transaction",
          "DELETE FROM m_loan_installment_charge",
          "DELETE FROM m_loan_charge",
          "DELETE FROM m_loan_repayment_schedule",
          "DELETE FROM m_loan_status_change_history",
          "DELETE FROM m_loan_officer_assignment_history",
          "DELETE FROM m_loan_arrears_aging",
          "DELETE FROM m_loan_disbursement_detail",
          "DELETE FROM m_loan_term_variations",
          "DELETE FROM m_loan_account_locks",
          "DELETE FROM m_loan",
          "SELECT setval(pg_get_serial_sequence('m_loan', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_loan_repayment_schedule', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_loan_transaction', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_loan_charge', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_loan_charge_paid_by', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_loan_installment_charge', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_note', 'id'), 1, false)"
        ] do
      TenantRepo.query!(sql)
    end

    # the books refer to users, offices and code values, so they go first
    for sql <- [
          "DELETE FROM m_client_charge_paid_by",
          "DELETE FROM m_client_charge",
          "DELETE FROM m_client_transaction",
          "DELETE FROM m_client_transfer_details",
          "DELETE FROM m_family_members",
          "DELETE FROM m_client_address",
          "DELETE FROM m_address",
          "DELETE FROM m_client_identifier",
          "DELETE FROM m_client_non_person",
          "DELETE FROM m_client",
          "SELECT setval(pg_get_serial_sequence('m_client_charge_paid_by', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_client_charge', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_client_transaction', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_client_transfer_details', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_family_members', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_address', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_client_identifier', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_client_non_person', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_client', 'id'), 1, false)",
          "DELETE FROM acc_product_mapping",
          "DELETE FROM m_product_loan_charge",
          "DELETE FROM m_product_loan",
          "SELECT setval(pg_get_serial_sequence('m_product_loan', 'id'), 1, false)",
          "DELETE FROM m_savings_product_charge",
          "DELETE FROM m_savings_product",
          "SELECT setval(pg_get_serial_sequence('m_savings_product', 'id'), 1, false)",
          "DELETE FROM m_rate",
          "SELECT setval(pg_get_serial_sequence('m_rate', 'id'), 1, false)",
          "DELETE FROM m_floating_rates_periods",
          "DELETE FROM m_floating_rates",
          "SELECT setval(pg_get_serial_sequence('m_floating_rates', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_floating_rates_periods', 'id'), 1, false)",
          "DELETE FROM m_charge",
          "SELECT setval(pg_get_serial_sequence('m_charge', 'id'), 1, false)",
          "DELETE FROM m_tax_group_mappings",
          "DELETE FROM m_tax_group",
          "DELETE FROM m_tax_component_history",
          "DELETE FROM m_tax_component",
          "SELECT setval(pg_get_serial_sequence('m_tax_component', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_tax_component_history', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_tax_group', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_tax_group_mappings', 'id'), 1, false)"
        ] do
      TenantRepo.query!(sql)
    end

    for sql <- [
          "DELETE FROM acc_gl_journal_entry",
          "DELETE FROM m_payment_detail",
          "SELECT setval(pg_get_serial_sequence('acc_gl_journal_entry', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('m_payment_detail', 'id'), 1, false)",
          "DELETE FROM acc_product_mapping",
          "DELETE FROM acc_gl_financial_activity_account",
          "DELETE FROM acc_rule_tags",
          "DELETE FROM acc_accounting_rule",
          "DELETE FROM acc_gl_closure",
          "DELETE FROM acc_gl_account",
          "SELECT setval(pg_get_serial_sequence('acc_gl_account', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('acc_gl_closure', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('acc_gl_financial_activity_account', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('acc_accounting_rule', 'id'), 1, false)",
          "SELECT setval(pg_get_serial_sequence('acc_rule_tags', 'id'), 1, false)"
        ] do
      TenantRepo.query!(sql)
    end

    for sql <- [
          "DELETE FROM m_provisioning_criteria_definition",
          "DELETE FROM m_provisioning_criteria",
          "DELETE FROM m_provision_category WHERE id > 4",
          "INSERT INTO m_provision_category (id, category_name, description) OVERRIDING SYSTEM VALUE VALUES (1, 'STANDARD', 'Punctual Payment without any dues') ON CONFLICT (id) DO UPDATE SET category_name = EXCLUDED.category_name, description = EXCLUDED.description",
          "INSERT INTO m_provision_category (id, category_name, description) OVERRIDING SYSTEM VALUE VALUES (2, 'SUB-STANDARD', 'Principal and/or Interest overdue by x days') ON CONFLICT (id) DO UPDATE SET category_name = EXCLUDED.category_name, description = EXCLUDED.description",
          "INSERT INTO m_provision_category (id, category_name, description) OVERRIDING SYSTEM VALUE VALUES (3, 'DOUBTFUL', 'Principal and/or Interest overdue by x days and less than y') ON CONFLICT (id) DO UPDATE SET category_name = EXCLUDED.category_name, description = EXCLUDED.description",
          "INSERT INTO m_provision_category (id, category_name, description) OVERRIDING SYSTEM VALUE VALUES (4, 'LOSS', 'Principal and/or Interest overdue by y days') ON CONFLICT (id) DO UPDATE SET category_name = EXCLUDED.category_name, description = EXCLUDED.description",
          "SELECT setval(pg_get_serial_sequence('m_provision_category', 'id'), 4)"
        ] do
      TenantRepo.query!(sql)
    end

    # users beyond the three seeded ones, and what hangs on them
    TenantRepo.query!("DELETE FROM m_appuser_previous_password")
    TenantRepo.query!("DELETE FROM m_appuser_role WHERE appuser_id > 3")
    TenantRepo.query!("DELETE FROM m_appuser WHERE id > 3")
    TenantRepo.query!("UPDATE m_appuser SET username = 'system' WHERE id = 2")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_appuser', 'id'), 3)")

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

    TenantRepo.query!("DELETE FROM m_role_permission WHERE role_id > 2")
    TenantRepo.query!("DELETE FROM m_role WHERE id > 2")
    TenantRepo.query!("SELECT setval(pg_get_serial_sequence('m_role', 'id'), 2)")

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
  def body(%{resp_body: ""}), do: nil
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
