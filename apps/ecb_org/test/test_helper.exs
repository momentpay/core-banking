ExUnit.start()

# Offices are tested against a real tenant database of their own (see ECBPlatform.TenantCase).
:ok = ECBPlatform.TenantCase.recreate_database("ecb_org_test")
