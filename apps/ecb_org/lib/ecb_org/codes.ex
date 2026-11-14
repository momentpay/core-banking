defmodule ECBOrg.Codes do
  @moduledoc "Code lists (`m_code`), read side: the list of codes. Must run inside a tenant scope."
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "Every code, in the order of its name (byte order, as Fineract's database sorts it)."
  @spec list() :: [map]
  def list do
    from(c in "m_code",
      order_by: [asc: fragment("? COLLATE \"C\"", c.code_name)],
      select: %{id: c.id, name: c.code_name, system_defined: c.is_system_defined}
    )
    |> TenantRepo.all()
  end
end
