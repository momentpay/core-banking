# Seeds the registry with the "default" tenant (the tenant name Apache Fineract's own tests
# use) and creates and migrates its database. Safe to run more than once.
#
#     mix run priv/repo/seeds.exs       (run for you by `mix ecto.setup`)

alias ECBPlatform.Repo
alias ECBPlatform.Tenancy

defaults = Application.fetch_env!(:ecb_platform, :default_tenant)
repo_config = Repo.config()

tenant =
  case Tenancy.get_by_identifier(defaults[:identifier]) do
    nil ->
      {:ok, tenant} =
        Tenancy.create_tenant(%{
          identifier: defaults[:identifier],
          name: defaults[:name],
          db_name: defaults[:db_name],
          db_host: repo_config[:hostname] || "localhost",
          db_port: repo_config[:port] || 5432,
          db_username: repo_config[:username] || "postgres"
        })

      tenant

    existing ->
      existing
  end

:ok = Tenancy.migrate(tenant)
IO.puts("Tenant #{tenant.identifier} ready (database #{tenant.db_name}).")
