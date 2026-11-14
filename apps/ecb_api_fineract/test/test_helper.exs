ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ECBPlatform.Repo, :manual)

# The API is tested against a real tenant database of its own (see ECBPlatform.TenantCase).
:ok = ECBPlatform.TenantCase.recreate_database("ecb_api_test")
