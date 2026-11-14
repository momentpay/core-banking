defmodule ECBPlatform.PasswordPolicies do
  @moduledoc """
  Password validation policies (`m_password_validation_policy`), read side. Exactly one is active.
  """
  import Ecto.Query

  alias ECBPlatform.TenantRepo

  @doc "Every policy, by id."
  @spec list() :: [map]
  def list, do: TenantRepo.all(base() |> order_by([p], p.id))

  @doc "The active policy, or `nil`."
  @spec active() :: map | nil
  def active, do: TenantRepo.one(base() |> where([p], p.active == true) |> limit(1))

  defp base do
    from p in "m_password_validation_policy",
      select: %{id: p.id, description: p.description, active: p.active, key: p.key}
  end
end
