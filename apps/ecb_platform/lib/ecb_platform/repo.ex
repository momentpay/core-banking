defmodule ECBPlatform.Repo do
  @moduledoc """
  The tenant **registry** repository (PostgreSQL).

  It stores which tenants exist and where each tenant's own database lives. It holds
  no banking data. Business data is read and written through
  `ECBPlatform.TenantRepo`, scoped with `ECBPlatform.Tenancy.with_tenant/2`.
  """
  use Ecto.Repo,
    otp_app: :ecb_platform,
    adapter: Ecto.Adapters.Postgres
end
