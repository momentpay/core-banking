defmodule ECBPlatform.Security do
  @moduledoc """
  Permission checks and loading users from the tenant database.

  Users, roles and permissions are Fineract's tables (`m_appuser`, `m_role`, `m_appuser_role`,
  `m_role_permission`, `m_permission`). A role can be disabled (`m_role.is_disabled`); a disabled role
  grants nothing.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Errors
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @doc "Returns `:ok` when the user may do `code`, otherwise `{:error, NoAuthorization}`."
  @spec validate_has_permission(User.t(), String.t()) :: :ok | {:error, Exception.t()}
  def validate_has_permission(%User{} = user, code) do
    if User.has_permission?(user, code),
      do: :ok,
      else: {:error, Errors.NoAuthorization.exception(permission: code)}
  end

  @doc "Returns `:ok` when the user is a checker for `task`, otherwise `{:error, NoAuthorization}`."
  @spec validate_has_checker_permission(User.t(), String.t()) :: :ok | {:error, Exception.t()}
  def validate_has_checker_permission(%User{} = user, task) do
    if User.checker_super_user?(user) or User.has_permission?(user, User.checker_permission(task)) do
      :ok
    else
      {:error,
       Errors.NoAuthorization.exception(
         permission: task,
         message: "User has no authority to be a checker for: #{task}"
       )}
    end
  end

  @doc """
  Loads a user and the permission codes of their enabled roles. Must run inside
  `ECBPlatform.Tenancy.with_tenant/2`. Returns `nil` for an unknown or deleted user.
  """
  @spec load_user(integer) :: User.t() | nil
  def load_user(user_id) when is_integer(user_id) do
    user =
      TenantRepo.one(
        from u in "m_appuser",
          where: u.id == ^user_id and u.is_deleted == false,
          select: %{id: u.id, username: u.username, office_id: u.office_id}
      )

    if user do
      codes =
        TenantRepo.all(
          from ur in "m_appuser_role",
            join: r in "m_role",
            on: r.id == ur.role_id and r.is_disabled == false,
            join: rp in "m_role_permission",
            on: rp.role_id == r.id,
            join: p in "m_permission",
            on: p.id == rp.permission_id,
            where: ur.appuser_id == ^user_id,
            distinct: true,
            select: p.code
        )

      User.new(user.id, user.username, codes, office_id: user.office_id)
    end
  end
end
