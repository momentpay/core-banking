defmodule ECBApiFineract.Resources.Administration do
  @moduledoc """
  Read endpoints for the platform's own administration data: global configuration, permissions, roles,
  users and password preferences. Each needs `READ_<RESOURCE>`.
  """
  alias ECBApiFineract.Resources.{Read, Write}
  alias ECBOrg.Offices
  alias ECBPlatform.{Configuration, PasswordPolicies, Permissions, Roles, Users}

  @doc "`GET /configurations`"
  def configurations(conn) do
    Read.respond(conn, "CONFIGURATION", fn ->
      %{"globalConfiguration" => for(c <- Configuration.list(), do: configuration(c, true))}
    end)
  end

  @doc "`GET /configurations/name/:name`"
  def configuration_by_name(conn, name) do
    Read.respond(conn, "CONFIGURATION", fn ->
      with {:ok, c} <- Configuration.get_by_name(name), do: configuration(c, false)
    end)
  end

  @doc "`GET /configurations/:id`"
  def configuration_by_id(conn, raw_id) do
    Read.respond(conn, "CONFIGURATION", fn ->
      with {:ok, id} <- Write.id(raw_id, &configuration_id_not_found/1),
           {:ok, c} <- Configuration.get_by_id(id),
           do: configuration(c, false)
    end)
  end

  @doc "`PUT /configurations/:id`"
  def update_configuration(conn, raw_id) do
    Write.with_id(
      conn,
      raw_id,
      &configuration_id_not_found/1,
      &Write.execute(conn, "CONFIGURATION", "UPDATE", id: &1)
    )
  end

  @doc "`PUT /configurations/name/:name`"
  def update_configuration_by_name(conn, name) do
    case ECBPlatform.Configuration.get_by_name(name) do
      {:ok, %{id: id}} -> Write.execute(conn, "CONFIGURATION", "UPDATE", id: id)
      {:error, error} -> ECBApiFineract.Errors.render(conn, error)
    end
  end

  @doc "`PUT /passwordpreferences`"
  def update_password_preferences(conn), do: Write.execute(conn, "PASSWORD_PREFERENCES", "UPDATE")

  @doc "`PUT /permissions`"
  def update_permissions(conn), do: Write.execute(conn, "PERMISSION", "UPDATE")

  defp configuration_id_not_found(raw),
    do:
      ECBPlatform.Errors.ResourceNotFound.new(
        "error.msg.configuration.id.invalid",
        "Configuration identifier `#{raw}` does not exist",
        [raw]
      )

  @doc "`GET /permissions` (`?makerCheckerable=true` for the maker-checker view)"
  def permissions(conn) do
    Read.respond(conn, "PERMISSION", fn ->
      Permissions.list(maker_checkerable: conn.query_params["makerCheckerable"] == "true")
      |> Enum.map(&permission/1)
    end)
  end

  @doc "`GET /roles`"
  def roles(conn), do: Read.respond(conn, "ROLE", fn -> Enum.map(Roles.list(), &role/1) end)

  @doc "`GET /roles/:id`"
  def role_by_id(conn, raw_id) do
    Read.respond(conn, "ROLE", fn -> with {:ok, r} <- Roles.get(raw_id), do: role(r) end)
  end

  @doc "`GET /roles/:id/permissions`"
  def role_permissions(conn, raw_id) do
    Read.respond(conn, "ROLE", fn ->
      with {:ok, role} <- Roles.get(raw_id) do
        role(role)
        |> Map.put("permissionUsageData", Enum.map(Roles.permissions(role.id), &permission/1))
      end
    end)
  end

  @doc "`POST /roles`"
  def create_role(conn), do: Write.execute(conn, "ROLE", "CREATE")

  @doc "`PUT /roles/:id`"
  def update_role(conn, raw_id),
    do:
      Write.with_id(
        conn,
        raw_id,
        &Roles.not_found/1,
        &Write.execute(conn, "ROLE", "UPDATE", id: &1)
      )

  @doc "`PUT /roles/:id/permissions`"
  def update_role_permissions(conn, raw_id) do
    Write.with_id(
      conn,
      raw_id,
      &Roles.not_found/1,
      &Write.execute(conn, "ROLE", "PERMISSIONS", id: &1)
    )
  end

  @doc "`DELETE /roles/:id`"
  def delete_role(conn, raw_id),
    do:
      Write.with_id(
        conn,
        raw_id,
        &Roles.not_found/1,
        &Write.execute(conn, "ROLE", "DELETE", id: &1)
      )

  @doc "`POST /roles/:id?command=enable|disable`; any other command is answered with no content, as Fineract does."
  def role_command(conn, raw_id) do
    case conn.query_params["command"] do
      "enable" ->
        Write.with_id(
          conn,
          raw_id,
          &Roles.not_found/1,
          &Write.execute(conn, "ROLE", "ENABLE", id: &1)
        )

      "disable" ->
        Write.with_id(
          conn,
          raw_id,
          &Roles.not_found/1,
          &Write.execute(conn, "ROLE", "DISABLE", id: &1)
        )

      _ ->
        Plug.Conn.send_resp(conn, 204, "")
    end
  end

  @doc "`GET /users`"
  def users(conn) do
    Read.respond(conn, "USER", fn ->
      Enum.map(Users.list(conn.assigns.current_user), &user/1)
    end)
  end

  @doc "`GET /users/:id`"
  def user_by_id(conn, raw_id) do
    Read.respond(conn, "USER", fn ->
      with {:ok, u} <- Users.get(raw_id) do
        Map.put(user(u), "availableRoles", Enum.map(u.available_roles, &role/1))
      end
    end)
  end

  @doc "`POST /users`"
  def create_user(conn), do: Write.execute(conn, "USER", "CREATE")

  @doc "`PUT /users/:id`"
  def update_user(conn, raw_id),
    do:
      Write.with_id(
        conn,
        raw_id,
        &user_not_found/1,
        &Write.execute(conn, "USER", "UPDATE", id: &1)
      )

  @doc "`DELETE /users/:id`"
  def delete_user(conn, raw_id),
    do:
      Write.with_id(
        conn,
        raw_id,
        &user_not_found/1,
        &Write.execute(conn, "USER", "DELETE", id: &1)
      )

  @doc "`POST /users/:id/pwd`"
  def change_user_password(conn, raw_id),
    do:
      Write.with_id(
        conn,
        raw_id,
        &user_not_found/1,
        &Write.execute(conn, "USER", "CHANGEPWD", id: &1)
      )

  defp user_not_found(raw),
    do:
      ECBPlatform.Errors.ResourceNotFound.new(
        "error.msg.user.id.invalid",
        "User with ID #{raw} does not exist",
        [raw]
      )

  @doc "`GET /users/template`"
  def users_template(conn) do
    Read.respond(conn, "USER", fn ->
      {:ok, offices} = Offices.list(conn.assigns.current_user, [])

      %{
        "allowedOffices" =>
          for(
            o <- offices,
            do: %{"id" => o.id, "name" => o.name, "nameDecorated" => o.name_decorated}
          ),
        "availableRoles" => for(r <- Roles.list(), not r.disabled, do: role(r))
      }
    end)
  end

  @doc "`GET /passwordpreferences`: the active policy"
  def password_preferences(conn) do
    Read.respond(conn, "PASSWORD_PREFERENCES", fn ->
      case PasswordPolicies.active() do
        nil -> %{}
        policy -> password_policy(policy)
      end
    end)
  end

  @doc "`GET /passwordpreferences/template`: every policy"
  def password_preferences_template(conn) do
    Read.respond(conn, "PASSWORD_PREFERENCES", fn ->
      Enum.map(PasswordPolicies.list(), &password_policy/1)
    end)
  end

  # The list shows `value` always (0 when unset); a single property leaves it out when unset, as Fineract does.
  defp configuration(c, in_list?) do
    %{
      "id" => c.id,
      "name" => c.name,
      "enabled" => c.enabled,
      "value" => if(in_list?, do: c.value || 0, else: c.value),
      "stringValue" => c.string_value,
      "dateValue" => c.date_value,
      "description" => c.description,
      "trapDoor" => c.trap_door,
      "allowedValues" => Map.get(c, :allowed_values),
      "multipleValuesAllowed" => Map.get(c, :multiple_values_allowed)
    }
  end

  defp user(u) do
    %{
      "id" => u.id,
      "username" => u.username,
      "officeId" => u.office_id,
      "officeName" => u.office_name,
      "firstname" => u.firstname,
      "lastname" => u.lastname,
      "email" => u.email,
      "passwordNeverExpires" => u.password_never_expires,
      "staff" => u.staff_id && %{"id" => u.staff_id, "displayName" => u.staff_name},
      "selectedRoles" => Enum.map(u.selected_roles, &role/1)
    }
  end

  defp permission(p) do
    %{
      "grouping" => p.grouping,
      "code" => p.code,
      "entityName" => blank_to_nil(p.entity_name),
      "actionName" => blank_to_nil(p.action_name),
      "selected" => p.selected
    }
  end

  defp role(r),
    do: %{
      "id" => r.id,
      "name" => r.name,
      "description" => r.description,
      "disabled" => r.disabled
    }

  defp password_policy(p),
    do: %{"id" => p.id, "description" => p.description, "active" => p.active, "key" => p.key}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
