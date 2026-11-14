defmodule ECBOrg.Funds do
  @moduledoc "Funds (`m_fund`), read side. Must run inside a tenant scope."
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "Every fund, by name."
  @spec list() :: [map]
  def list do
    from(f in "m_fund",
      order_by: [asc: fragment("? COLLATE \"C\"", f.name)],
      select: %{id: f.id, name: f.name, external_id: f.external_id}
    )
    |> TenantRepo.all()
  end
end
