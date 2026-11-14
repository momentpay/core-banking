ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ECBPlatform.Repo, :manual)

# The command pipeline is tested against a real tenant database (see ECBPlatform.TenantCase).
# Create it and apply every tenant migration before the first test.
:ok = ECBPlatform.Tenancy.migrate(ECBPlatform.TenantCase.tenant())
