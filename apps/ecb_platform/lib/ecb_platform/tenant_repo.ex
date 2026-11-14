defmodule ECBPlatform.TenantRepo do
  @moduledoc """
  The repository for business data. One database per tenant, as in Apache Fineract.

  This is a **dynamic repo**: there is no single database behind it. Each tenant gets its
  own connection pool, started on demand by `ECBPlatform.Tenancy.Pools`. A request or job
  selects its tenant with `ECBPlatform.Tenancy.with_tenant/2`, which points this module at
  the right pool for the duration of the call.

  Calling `TenantRepo` functions outside `with_tenant/2` is a bug: no pool is selected.
  """
  use Ecto.Repo,
    otp_app: :ecb_platform,
    adapter: Ecto.Adapters.Postgres
end
