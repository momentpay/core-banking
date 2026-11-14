defmodule ECBPlatform.Roles.Write do
  @moduledoc """
  Creating, changing, enabling, disabling and deleting roles, and changing the permissions a role holds,
  following Fineract's role service.

  A role that users hold cannot be disabled or deleted. Permissions are granted and withdrawn by code; the
  answer lists only the permissions whose state really changed.
  """
  import Ecto.Query

  alias ECBPlatform.Changes
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, InvalidJson, ResourceNotFound}
  alias ECBPlatform.{Integrity, Params, Roles, TenantRepo, Validation}

  @doc "Creates the role `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    params = Params.check_supported!(params, ~w(id name description))
    name = Params.string(params, "name")
    description = Params.string(params, "description")

    Validation.new("role")
    |> Validation.param("name", name)
    |> Validation.not_blank()
    |> Validation.max_length(100)
    |> Validation.param("description", description)
    |> Validation.not_blank()
    |> Validation.max_length(500)
    |> Validation.raise_if_errors!()

    {1, [%{id: id}]} =
      guard(name, fn ->
        TenantRepo.insert_all(
          "m_role",
          [%{name: name, description: description, is_disabled: false}],
          returning: [:id]
        )
      end)

    Result.new(resource_id: id)
  end

  @doc "Changes role `id`."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    params = Params.check_supported!(params, ~w(id name description))
    validate_for_update!(params)

    role = Roles.fetch!(id)

    changes =
      Changes.new()
      |> Changes.text(params, "name", :name, role.name)
      |> Changes.text(params, "description", :description, role.description)

    unless Changes.empty?(changes) do
      guard(Params.string(params, "name"), fn ->
        TenantRepo.update_all(from(r in "m_role", where: r.id == ^id), set: Changes.set(changes))
      end)
    end

    Result.new(resource_id: id, changes: Changes.public(changes))
  end

  @doc """
  Grants and withdraws permissions. The request is `{"permissions": {"READ_OFFICE": true}}`: `true`
  grants, `false` withdraws.
  """
  @spec update_permissions!(integer, Params.t()) :: Result.t()
  def update_permissions!(id, %Params{} = params) do
    params = Params.check_supported!(params, ["permissions"])
    _role = Roles.fetch!(id)

    wanted =
      case Params.value(params, "permissions") do
        %{} = map -> map
        _ -> raise InvalidJson, detail: nil
      end

    held = MapSet.new(for p <- Roles.permissions(id), p.selected, do: p.code)

    changed =
      Enum.flat_map(wanted, fn {code, flag} ->
        permission_id = permission_id!(code)
        selected? = flag == true

        if selected? != MapSet.member?(held, code),
          do: [{code, selected?, permission_id}],
          else: []
      end)

    for {_code, selected?, permission_id} <- changed,
        do: apply_permission!(id, permission_id, selected?)

    shown = for {code, selected?, _id} <- changed, into: %{}, do: {code, selected?}

    Result.new(
      resource_id: id,
      changes: if(shown == %{}, do: %{}, else: %{"permissions" => shown})
    )
  end

  @doc "Enables role `id`."
  @spec enable!(integer) :: Result.t()
  def enable!(id) do
    _role = Roles.fetch!(id)
    set_disabled!(id, false)
    Result.new(resource_id: id)
  end

  @doc "Disables role `id`; refused while users hold it."
  @spec disable!(integer) :: Result.t()
  def disable!(id) do
    _role = Roles.fetch!(id)
    refuse_if_in_use!(id, "error.msg.role.associated.with.users.disabled")
    set_disabled!(id, true)
    Result.new(resource_id: id)
  end

  @doc "Deletes role `id`; refused while users hold it."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    _role = Roles.fetch!(id)
    refuse_if_in_use!(id, "error.msg.role.associated.with.users.deleted")

    Integrity.translate(
      fn ->
        TenantRepo.delete_all(from(rp in "m_role_permission", where: rp.role_id == ^id))
        TenantRepo.delete_all(from(r in "m_role", where: r.id == ^id))
      end,
      %{},
      {"error.msg.unknown.data.integrity.issue", "Unknown data integrity issue with resource."}
    )

    Result.new(resource_id: id)
  end

  # --- internals ------------------------------------------------------------------------------

  defp validate_for_update!(params) do
    validation = Validation.new("role")

    validation =
      if Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_blank()
          |> Validation.max_length(100),
        else: validation

    validation =
      if Params.exists?(params, "description"),
        do:
          validation
          |> Validation.param("description", Params.string(params, "description"))
          |> Validation.not_blank()
          |> Validation.max_length(500),
        else: validation

    Validation.raise_if_errors!(validation)
  end

  defp refuse_if_in_use!(id, code) do
    if Roles.user_count(id) > 0,
      do:
        raise(DomainRuleViolation,
          code: code,
          message: "Role with identifier #{id} associated with users",
          args: [id]
        )
  end

  defp set_disabled!(id, disabled?),
    do:
      TenantRepo.update_all(from(r in "m_role", where: r.id == ^id),
        set: [is_disabled: disabled?]
      )

  defp permission_id!(code) do
    case TenantRepo.one(from p in "m_permission", where: p.code == ^code, select: p.id) do
      nil ->
        raise ResourceNotFound,
          code: "error.msg.permission.code.invalid",
          message: "Permission with Code #{code} does not exist",
          args: [code]

      id ->
        id
    end
  end

  defp apply_permission!(role_id, permission_id, true),
    do:
      TenantRepo.insert_all(
        "m_role_permission",
        [%{role_id: role_id, permission_id: permission_id}],
        on_conflict: :nothing
      )

  defp apply_permission!(role_id, permission_id, false),
    do:
      TenantRepo.delete_all(
        from rp in "m_role_permission",
          where: rp.role_id == ^role_id and rp.permission_id == ^permission_id
      )

  defp guard(name, fun) do
    Integrity.translate(
      fun,
      %{
        "m_role_name_key" =>
          {"error.msg.role.duplicate.name", "Role with name `#{name}` already exists", "name",
           [name]}
      },
      {"error.msg.role.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end
end
