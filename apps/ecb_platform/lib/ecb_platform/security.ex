defmodule ECBPlatform.Security do
  @moduledoc """
  Permission checks and loading users from the tenant database.

  Users, roles and permissions are Fineract's tables (`m_appuser`, `m_role`, `m_appuser_role`,
  `m_role_permission`, `m_permission`). A role can be disabled (`m_role.is_disabled`); a disabled role
  grants nothing.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Errors
  alias ECBPlatform.Security.{Password, User}
  alias ECBPlatform.TenantRepo

  @doc "Returns `:ok` when the user may do `code`, otherwise `{:error, NoAuthorization}`."
  @spec validate_has_permission(User.t(), String.t()) :: :ok | {:error, Exception.t()}
  def validate_has_permission(%User{} = user, code) do
    if User.has_permission?(user, code),
      do: :ok,
      else: {:error, Errors.NoAuthorization.exception(permission: code)}
  end

  @doc """
  Returns `:ok` when the user may read `resource` (for example `"OFFICE"`): they hold `READ_<RESOURCE>`,
  `ALL_FUNCTIONS_READ` or `ALL_FUNCTIONS`. The error message is Fineract's.
  """
  @spec validate_has_read_permission(User.t(), String.t()) :: :ok | {:error, Exception.t()}
  def validate_has_read_permission(%User{} = user, resource) do
    code = "READ_" <> String.upcase(resource)

    if User.has_permission?(user, "ALL_FUNCTIONS_READ") or User.has_permission?(user, code) do
      :ok
    else
      {:error,
       Errors.NoAuthorization.exception(
         permission: code,
         message: "User has no authority to READ #{String.downcase(resource)}s"
       )}
    end
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
  Checks a username and password. Returns the loaded user, or `:error` for an unknown user, a wrong
  password, or an account that is deleted, disabled, locked or expired. The caller is not told which.

  Must run inside `ECBPlatform.Tenancy.with_tenant/2` (or after `ECBPlatform.Tenancy.activate/1`).
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, User.t()} | :error
  def authenticate(username, password) when is_binary(username) and is_binary(password) do
    row =
      TenantRepo.one(
        from u in "m_appuser",
          where: u.username == ^username and u.is_deleted == false,
          select: %{
            id: u.id,
            password: u.password,
            enabled: u.enabled,
            nonlocked: u.nonlocked,
            nonexpired: u.nonexpired,
            nonexpired_credentials: u.nonexpired_credentials
          }
      )

    cond do
      is_nil(row) ->
        # Hash anyway so an unknown user takes as long as a known one.
        Password.matches?(password, "{SHA-256}{0}" <> String.duplicate("0", 64))
        :error

      not account_usable?(row) ->
        :error

      not Password.matches?(password, row.password) ->
        :error

      true ->
        {:ok, load_user(row.id)}
    end
  end

  def authenticate(_username, _password), do: :error

  defp account_usable?(row),
    do: row.enabled and row.nonlocked and row.nonexpired and row.nonexpired_credentials

  @doc """
  What `/authentication` tells a client about a signed-in user: office, roles and permission codes.
  Must run inside a tenant scope.
  """
  @spec authentication_details(User.t()) :: map
  def authentication_details(%User{} = user) do
    office_name =
      user.office_id &&
        TenantRepo.one(from o in "m_office", where: o.id == ^user.office_id, select: o.name)

    roles =
      TenantRepo.all(
        from ur in "m_appuser_role",
          join: r in "m_role",
          on: r.id == ur.role_id,
          where: ur.appuser_id == ^user.id,
          order_by: r.id,
          select: %{id: r.id, name: r.name, description: r.description, disabled: r.is_disabled}
      )

    %{
      user_id: user.id,
      username: user.username,
      office_id: user.office_id,
      office_name: office_name,
      roles: roles,
      permissions: permission_codes_in_id_order(user.id)
    }
  end

  # Fineract lists a user's permissions in the order of the permission ids, not alphabetically.
  defp permission_codes_in_id_order(user_id) do
    TenantRepo.all(
      from ur in "m_appuser_role",
        join: r in "m_role",
        on: r.id == ur.role_id and r.is_disabled == false,
        join: rp in "m_role_permission",
        on: rp.role_id == r.id,
        join: p in "m_permission",
        on: p.id == rp.permission_id,
        where: ur.appuser_id == ^user_id,
        group_by: [p.id, p.code],
        order_by: p.id,
        select: p.code
    )
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
