defmodule ECBPlatform.Permissions do
  @moduledoc """
  The permission catalogue (`m_permission`) as `GET /permissions` lists it.

  Follows Fineract's `PermissionsReadPlatformServiceImpl`: the `*_CHECKER` permissions are not listed
  (they are derived from the maker permissions), the order is grouping, entity name, then code, and
  with `maker_checkerable` only permissions that can be put under maker-checker are listed, with
  `selected` showing whether each one is currently under it.

  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "Lists permissions. Pass `maker_checkerable: true` for the maker-checker view."
  @spec list(keyword) :: [map]
  def list(opts \\ []) do
    query =
      from p in "m_permission",
        where: not like(p.code, "%\\_CHECKER"),
        order_by: [
          asc: fragment("? COLLATE \"C\"", p.grouping),
          asc: fragment("? COLLATE \"C\"", coalesce(p.entity_name, "")),
          asc: fragment("? COLLATE \"C\"", p.code)
        ],
        select: %{
          grouping: p.grouping,
          code: p.code,
          entity_name: p.entity_name,
          action_name: p.action_name,
          can_maker_checker: p.can_maker_checker
        }

    if opts[:maker_checkerable] do
      query
      |> where([p], p.grouping != "special" and not like(p.code, "READ%"))
      |> TenantRepo.all()
      |> Enum.map(&Map.put(&1, :selected, &1.can_maker_checker))
    else
      query |> TenantRepo.all() |> Enum.map(&Map.put(&1, :selected, true))
    end
  end
end
