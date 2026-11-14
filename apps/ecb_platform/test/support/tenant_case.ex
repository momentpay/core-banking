defmodule ECBPlatform.TenantCase do
  @moduledoc """
  Test setup for code that works on a tenant database.

      use ECBPlatform.TenantCase                                  # database ecb_tenant_test, reset before each test
      use ECBPlatform.TenantCase, database: "ecb_org_test", reset: false   # another app's own database, left as migrated

  Each app that uses it gives itself its own database and migrates it once in `test_helper.exs`
  (`Tenancy.migrate(ECBPlatform.TenantCase.tenant("ecb_org_test"))`).

  Uses a real tenant database (`ecb_tenant_test`) with real commits and rollbacks rather than the
  SQL sandbox, because the command pipeline depends on exactly that: the command row is committed
  before the handler runs, and a failed or unapproved command rolls the handler's work back while
  the row stays. Tests using this case must not be `async`.

  `reset!/0` clears what tests create (stored commands, users, test permissions) and restores the
  settings tests flip (maker-checker flags), leaving the seeded permissions and configuration alone.
  """
  use ExUnit.CaseTemplate

  alias ECBPlatform.Security
  alias ECBPlatform.Tenancy.{Pools, Tenant}
  alias ECBPlatform.TenantRepo

  using opts do
    database = Keyword.get(opts, :database, "ecb_tenant_test")
    reset? = Keyword.get(opts, :reset, true)

    quote do
      import ECBPlatform.TenantCase
      alias ECBPlatform.TenantRepo

      setup do
        ECBPlatform.TenantCase.setup_tenant(unquote(database), unquote(reset?))
      end
    end
  end

  @doc """
  Drops and recreates a test database and applies every tenant migration. Called once from each app's
  `test_helper.exs`, so a run never inherits a half-migrated database from an earlier one.
  """
  def recreate_database(database) do
    tenant = tenant(database)
    _ = TenantRepo.__adapter__().storage_down(Tenant.repo_opts(tenant))
    ECBPlatform.Tenancy.migrate(tenant)
  end

  @doc false
  def setup_tenant(database, reset?) do
    {:ok, pool} = Pools.ensure_started(tenant(database))
    TenantRepo.put_dynamic_repo(pool)
    if reset?, do: reset!()
    :ok
  end

  @doc "The test tenant (not stored in the registry): the registry's server and a database of its own."
  def tenant(database \\ "ecb_tenant_test") do
    config = ECBPlatform.Repo.config()

    %Tenant{
      # one pool per database: the identifier names the pool, so apps sharing a test run must not share it
      identifier: database,
      name: "Test tenant",
      timezone_id: "UTC",
      db_host: config[:hostname],
      db_port: config[:port],
      db_name: database <> (System.get_env("MIX_TEST_PARTITION") || ""),
      db_username: config[:username],
      pool_size: 5
    }
  end

  @doc "Removes everything tests create and restores the settings they change."
  def reset! do
    TenantRepo.query!(
      "TRUNCATE m_portfolio_command_source, m_appuser_role, m_appuser, m_role_permission RESTART IDENTITY CASCADE"
    )

    TenantRepo.query!("DELETE FROM m_role WHERE name LIKE 'test-%'")
    TenantRepo.query!("DELETE FROM m_permission WHERE \"grouping\" = 'test'")

    TenantRepo.query!(
      "DELETE FROM m_role_permission WHERE role_id = 1 AND permission_id NOT IN (SELECT id FROM m_permission)"
    )

    TenantRepo.query!(
      "UPDATE c_configuration SET enabled = false WHERE name IN ('maker-checker', 'enable-same-maker-checker')"
    )

    TenantRepo.query!(
      "INSERT INTO m_role_permission (role_id, permission_id) SELECT 1, id FROM m_permission WHERE code = 'ALL_FUNCTIONS' ON CONFLICT DO NOTHING"
    )

    TenantRepo.query!(
      "INSERT INTO m_role_permission (role_id, permission_id) SELECT 1, id FROM m_permission WHERE code IN ('CHECKER_SUPER_USER') ON CONFLICT DO NOTHING"
    )

    :ok
  end

  @doc "Turns on global maker-checker (and optionally lets a maker check their own command)."
  def enable_maker_checker(opts \\ []) do
    TenantRepo.query!("UPDATE c_configuration SET enabled = true WHERE name = 'maker-checker'")

    if Keyword.get(opts, :same_maker_checker, false),
      do:
        TenantRepo.query!(
          "UPDATE c_configuration SET enabled = true WHERE name = 'enable-same-maker-checker'"
        )

    :ok
  end

  @doc "Creates a permission row for tests (grouping 'test'). Returns its id."
  def put_permission(code, opts \\ []) do
    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_permission",
        [
          %{
            grouping: "test",
            code: code,
            can_maker_checker: Keyword.get(opts, :maker_checker, true)
          }
        ],
        returning: [:id],
        on_conflict: {:replace, [:can_maker_checker]},
        conflict_target: [:code]
      )

    id
  end

  @doc """
  Creates a user whose role grants `permission_codes`. Each code gets a permission row if it has none
  yet. Returns the loaded `ECBPlatform.Security.User`.
  """
  def create_user(username, permission_codes) do
    {1, [%{id: role_id}]} =
      TenantRepo.insert_all(
        "m_role",
        [%{name: "test-" <> username, description: "test role", is_disabled: false}],
        returning: [:id]
      )

    for code <- permission_codes do
      permission_id = permission_id(code) || put_permission(code)

      TenantRepo.insert_all("m_role_permission", [
        %{role_id: role_id, permission_id: permission_id}
      ])
    end

    {1, [%{id: user_id}]} =
      TenantRepo.insert_all(
        "m_appuser",
        [
          %{
            username: username,
            firstname: username,
            lastname: "Test",
            password: "x",
            email: username <> "@example.test",
            firsttime_login_remaining: false,
            nonexpired: true,
            nonlocked: true,
            nonexpired_credentials: true,
            enabled: true
          }
        ],
        returning: [:id]
      )

    TenantRepo.insert_all("m_appuser_role", [%{appuser_id: user_id, role_id: role_id}])
    Security.load_user(user_id)
  end

  defp permission_id(code) do
    TenantRepo.query!("SELECT id FROM m_permission WHERE code = $1", [code]).rows
    |> List.first()
    |> then(&(&1 && hd(&1)))
  end
end
