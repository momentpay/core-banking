ExUnit.start()

# The ledger is tested against a real tenant database of their own (see ECBPlatform.TenantCase).
:ok = ECBPlatform.TenantCase.recreate_database("ecb_ledger_test")
