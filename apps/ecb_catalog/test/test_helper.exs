ExUnit.start()

# The catalog is tested against a real tenant database of its own (see ECBPlatform.TenantCase).
:ok = ECBPlatform.TenantCase.recreate_database("ecb_catalog_test")
