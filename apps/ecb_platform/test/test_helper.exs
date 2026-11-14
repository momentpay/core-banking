ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ECBPlatform.Repo, :manual)

# The command pipeline is tested against a real tenant database (see ECBPlatform.TenantCase).
# Recreate it and apply every tenant migration before the first test.
:ok = ECBPlatform.TenantCase.recreate_database("ecb_tenant_test")
