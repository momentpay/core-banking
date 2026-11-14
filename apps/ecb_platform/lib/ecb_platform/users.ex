defmodule ECBPlatform.Users do
  @moduledoc """
  Application users (`m_appuser`), read side: the list.

  A user sees the users of the offices at or below their own in the hierarchy. Must run inside a
  tenant scope.
  """
  import Ecto.Query

  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.Roles
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo

  @doc "Users in the caller's branch of the office tree, by username, each with their selected roles."
  @spec list(User.t()) :: [map]
  def list(%User{} = caller) do
    pattern = hierarchy_of(caller) <> "%"

    users =
      from(u in "m_appuser",
        join: o in "m_office",
        on: o.id == u.office_id,
        left_join: s in "m_staff",
        on: s.id == u.staff_id,
        where: u.is_deleted == false and like(o.hierarchy, ^pattern),
        order_by: u.username,
        select: %{
          id: u.id,
          username: u.username,
          office_id: u.office_id,
          office_name: o.name,
          firstname: u.firstname,
          lastname: u.lastname,
          email: u.email,
          password_never_expires: u.password_never_expires,
          staff_id: s.id,
          staff_name: s.display_name
        }
      )
      |> TenantRepo.all()

    roles = roles_by_user(Enum.map(users, & &1.id))
    Enum.map(users, &Map.put(&1, :selected_roles, Map.get(roles, &1.id, [])))
  end

  @doc """
  One user, with their roles and the roles that could still be given to them. Not limited to the
  caller's branch, as in Fineract. `{:error, ResourceNotFound}` when there is no such user.
  """
  @spec get(integer | String.t()) :: {:ok, map} | {:error, Exception.t()}
  def get(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> get(id)
      _ -> {:error, not_found(raw)}
    end
  end

  def get(id) when is_integer(id) do
    row =
      from(u in "m_appuser",
        join: o in "m_office",
        on: o.id == u.office_id,
        left_join: s in "m_staff",
        on: s.id == u.staff_id,
        where: u.id == ^id and u.is_deleted == false,
        select: %{
          id: u.id,
          username: u.username,
          office_id: u.office_id,
          office_name: o.name,
          firstname: u.firstname,
          lastname: u.lastname,
          email: u.email,
          password_never_expires: u.password_never_expires,
          staff_id: s.id,
          staff_name: s.display_name
        }
      )
      |> TenantRepo.one()

    case row do
      nil ->
        {:error, not_found(id)}

      user ->
        selected = Map.get(roles_by_user([id]), id, [])
        selected_ids = Enum.map(selected, & &1.id)

        {:ok,
         user
         |> Map.put(:selected_roles, selected)
         |> Map.put(:available_roles, Enum.reject(Roles.list(), &(&1.id in selected_ids)))}
    end
  end

  defp not_found(id),
    do:
      ResourceNotFound.new("error.msg.user.id.invalid", "User with ID #{id} does not exist", [id])

  defp roles_by_user(user_ids) do
    from(ur in "m_appuser_role",
      join: r in "m_role",
      on: r.id == ur.role_id,
      where: ur.appuser_id in ^user_ids,
      order_by: [ur.appuser_id, r.id],
      select:
        {ur.appuser_id,
         %{id: r.id, name: r.name, description: r.description, disabled: r.is_disabled}}
    )
    |> TenantRepo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp hierarchy_of(%User{office_id: nil}), do: "."

  defp hierarchy_of(%User{office_id: office_id}),
    do:
      TenantRepo.one(from o in "m_office", where: o.id == ^office_id, select: o.hierarchy) || "."
end
