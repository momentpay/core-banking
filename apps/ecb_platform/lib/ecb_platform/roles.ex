defmodule ECBPlatform.Roles do
  @moduledoc """
  Roles (`m_role`), read side: the list, one role, and the permissions a role holds. Must run inside a
  tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.{Permissions, TenantRepo}

  @doc "All roles, by id."
  @spec list() :: [map]
  def list, do: TenantRepo.all(base() |> order_by([r], r.id))

  @doc "One role, or `{:error, ResourceNotFound}`."
  @spec get(integer | String.t()) :: {:ok, map} | {:error, Exception.t()}
  def get(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> get(id)
      _ -> {:error, not_found(raw)}
    end
  end

  def get(id) when is_integer(id) do
    case TenantRepo.one(base() |> where([r], r.id == ^id)) do
      nil ->
        {:error, not_found(id)}

      role ->
        {:ok, role}
    end
  end

  @doc "Like `get/1` but raises the not-found error."
  @spec fetch!(integer) :: map
  def fetch!(id) do
    case get(id) do
      {:ok, role} -> role
      {:error, error} -> raise error
    end
  end

  @doc """
  The whole permission catalogue as `Permissions.list/1` gives it, each marked `selected` when the role
  holds it.
  """
  @spec permissions(integer) :: [map]
  def permissions(role_id) do
    held =
      MapSet.new(
        TenantRepo.all(
          from rp in "m_role_permission",
            join: p in "m_permission",
            on: p.id == rp.permission_id,
            where: rp.role_id == ^role_id,
            select: p.code
        )
      )

    for permission <- Permissions.list(with_checkers: true),
        do: %{permission | selected: permission.code in held}
  end

  @doc "How many users hold the role."
  @spec user_count(integer) :: non_neg_integer
  def user_count(role_id),
    do:
      TenantRepo.one(from ur in "m_appuser_role", where: ur.role_id == ^role_id, select: count())

  @doc false
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.role.id.invalid",
        "Role with identifier #{id} does not exist",
        [id]
      )

  defp base do
    from r in "m_role",
      select: %{id: r.id, name: r.name, description: r.description, disabled: r.is_disabled}
  end
end
