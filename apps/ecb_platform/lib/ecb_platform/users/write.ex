defmodule ECBPlatform.Users.Write do
  @moduledoc """
  Creating, changing and deleting application users (`m_appuser`), and changing a password, following
  Fineract's user service.

  A user belongs to an office, may be linked to a staff member of that office, and holds one or more
  roles. Passwords are checked against the active password policy and stored as `{bcrypt}` hashes. When
  the configuration `password-reuse-check-history-count` is enabled, a password already used (within
  that many changes, or ever when it is 0) is refused. Deleting a user is a soft delete: the row stays,
  the account is disabled, the username is prefixed with the id so it can be used again, and the roles
  are removed.

  Sending a generated password by e-mail (`sendPasswordToEmail: true`) needs a mailer, which is not
  configured: that request is refused as Fineract refuses one it cannot send.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Errors.NoAuthorization
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Configuration
  alias ECBPlatform.Errors.{PlatformApiDataValidation, ResourceNotFound}
  alias ECBPlatform.Integrity
  alias ECBPlatform.Params
  alias ECBPlatform.PasswordPolicies
  alias ECBPlatform.Security.Password
  alias ECBPlatform.TenantRepo
  alias ECBPlatform.Validation

  @system_user "system"

  @create_params ~w(username firstname lastname password repeatPassword email officeId notSelectedRoles roles sendPasswordToEmail staffId passwordNeverExpires isLoginRetriesEnabled isPasswordResetAllowed)

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the user `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    params = Params.check_supported!(params, @create_params)

    username = Params.string(params, "username")
    send_to_email? = Params.boolean(params, "sendPasswordToEmail") == true
    office_id = Params.long(params, "officeId")
    staff_id = Params.long(params, "staffId")
    role_ids = role_ids(params)

    validation =
      Validation.new("user")
      |> Validation.param("username", username)
      |> Validation.not_blank()
      |> Validation.max_length(100)
      |> Validation.param("firstname", Params.string(params, "firstname"))
      |> Validation.not_blank()
      |> Validation.max_length(100)
      |> Validation.param("lastname", Params.string(params, "lastname"))
      |> Validation.not_blank()
      |> Validation.max_length(100)

    validation =
      if send_to_email?,
        do:
          validation
          |> Validation.param("email", Params.string(params, "email"))
          |> Validation.not_blank()
          |> Validation.max_length(254),
        else: validate_password(validation, params, false)

    validation =
      validation
      |> Validation.param("officeId", office_id)
      |> Validation.not_null()
      |> Validation.greater_than_zero()

    validation =
      if Params.exists?(params, "staffId"),
        do:
          validation
          |> Validation.param("staffId", staff_id)
          |> Validation.not_null()
          |> Validation.greater_than_zero(),
        else: validation

    validation
    |> Validation.param("roles", role_ids)
    |> Validation.array_not_empty()
    |> Validation.raise_if_errors!()

    office = office!(office_id)
    roles = roles!(role_ids)
    staff_id = staff_in_office!(staff_id, office)

    if send_to_email?, do: refuse_email!(Params.string(params, "email"))

    password = Params.string(params, "password")
    ensure_password!(password, username)

    {1, [%{id: id}]} =
      guard(username, fn ->
        TenantRepo.insert_all(
          "m_appuser",
          [
            %{
              office_id: office,
              staff_id: staff_id,
              username: String.trim(username),
              firstname: String.trim(Params.string(params, "firstname")),
              lastname: String.trim(Params.string(params, "lastname")),
              password: Password.encode(password),
              email: String.trim(Params.command_string(params, "email")),
              firsttime_login_remaining: true,
              nonexpired: true,
              nonlocked: true,
              nonexpired_credentials: true,
              enabled: true,
              last_time_password_updated: Date.utc_today(),
              password_never_expires: Params.boolean(params, "passwordNeverExpires") == true,
              cannot_change_password: false,
              password_reset_required:
                Configuration.enabled?("force-password-reset-on-first-login"),
              is_login_retries_enabled:
                resolve_retries(username, Params.boolean(params, "isLoginRetriesEnabled") == true),
              is_password_reset_enabled: Params.boolean(params, "isPasswordResetAllowed") == true
            }
          ],
          returning: [:id]
        )
      end)

    set_roles!(id, roles)
    Result.new(resource_id: id, office_id: office)
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes user `id`. The result lists what changed; a changed password shows as `password: true`."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    params = Params.check_supported!(params, @create_params)
    validate_for_update!(params)

    user = fetch!(id)
    check_password_reuse!(user, params)

    changes =
      []
      |> change_password(user, params)
      |> change_long(params, "officeId", :office_id, user.office_id)
      |> change_staff(params, user)
      |> change_roles(params, user)
      |> change_text(params, "username", :username, user.username)
      |> change_text(params, "firstname", :firstname, user.firstname)
      |> change_text(params, "lastname", :lastname, user.lastname)
      |> change_text(params, "email", :email, user.email)
      |> change_boolean(
        params,
        "passwordNeverExpires",
        :password_never_expires,
        user.password_never_expires
      )
      |> change_retries(params, user)
      |> change_boolean(
        params,
        "isPasswordResetAllowed",
        :is_password_reset_enabled,
        user.is_password_reset_enabled
      )

    if Keyword.has_key?(changes, :username) and user.username == @system_user,
      do:
        raise(NoAuthorization,
          permission: nil,
          message: "User name of current system user may not be modified"
        )

    office_id = Keyword.get(changes, :office_id)
    if office_id, do: office!(office_id)
    final_office = office_id || user.office_id

    staff_id = apply_staff!(changes, user, final_office, office_id)

    roles =
      if Keyword.has_key?(changes, :roles), do: roles!(Keyword.fetch!(changes, :roles)), else: nil

    unless changes == [] do
      save_user!(id, changes, staff_id)
      if roles, do: set_roles!(id, roles)
      remember_old_password!(user, changes)
    end

    Result.new(resource_id: id, office_id: final_office, changes: shown(changes))
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes user `id` (a soft delete)."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    user = fetch!(id)

    if user.username == @system_user,
      do:
        raise(NoAuthorization,
          permission: nil,
          message: "User configured as the system user cannot be deleted"
        )

    TenantRepo.update_all(
      from(u in "m_appuser", where: u.id == ^id),
      set: [
        is_deleted: true,
        enabled: false,
        nonexpired: false,
        firsttime_login_remaining: true,
        username: "#{id}_DELETED_#{user.username}"
      ]
    )

    TenantRepo.delete_all(from(ur in "m_appuser_role", where: ur.appuser_id == ^id))
    Result.new(resource_id: id, office_id: user.office_id)
  end

  # --- change password ------------------------------------------------------------------------

  @doc "Sets a new password for user `id`."
  @spec change_password!(integer, Params.t()) :: Result.t()
  def change_password!(id, %Params{} = params) do
    params = Params.check_supported!(params, ~w(password repeatPassword))

    Validation.new("user")
    |> validate_password(params, false)
    |> Validation.raise_if_errors!()

    user = fetch!(id)
    check_password_reuse!(user, params)
    changes = change_password([], user, params)

    unless changes == [] do
      save_user!(id, changes, :unchanged)
      remember_old_password!(user, changes)
    end

    Result.new(resource_id: id, office_id: user.office_id, changes: shown(changes))
  end

  # --- reading --------------------------------------------------------------------------------

  @doc "The stored row of user `id` (not deleted), or `{:error, ResourceNotFound}`."
  @spec get(integer) :: {:ok, map} | {:error, Exception.t()}
  def get(id) do
    row =
      TenantRepo.one(
        from u in "m_appuser",
          where: u.id == ^id and u.is_deleted == false,
          select: %{
            id: u.id,
            office_id: u.office_id,
            staff_id: u.staff_id,
            username: u.username,
            firstname: u.firstname,
            lastname: u.lastname,
            email: u.email,
            password: u.password,
            password_never_expires: u.password_never_expires,
            is_login_retries_enabled: u.is_login_retries_enabled,
            is_password_reset_enabled: u.is_password_reset_enabled
          }
      )

    if row, do: {:ok, row}, else: {:error, not_found(id)}
  end

  # --- internals ------------------------------------------------------------------------------

  defp fetch!(id) do
    case get(id) do
      {:ok, user} -> user
      {:error, error} -> raise error
    end
  end

  defp not_found(id),
    do:
      ResourceNotFound.new("error.msg.user.id.invalid", "User with ID #{id} does not exist", [id])

  defp validate_for_update!(params) do
    validation = Validation.new("user")

    validation =
      validation
      |> maybe(params, "officeId", fn v, p ->
        v
        |> Validation.param("officeId", Params.long(p, "officeId"))
        |> Validation.not_null()
        |> Validation.greater_than_zero()
      end)
      |> maybe(params, "staffId", fn v, p ->
        v
        |> Validation.param("staffId", Params.long(p, "staffId"))
        |> Validation.ignore_if_null()
        |> Validation.greater_than_zero()
      end)
      |> maybe(params, "username", &text_not_blank(&1, &2, "username", 100))
      |> maybe(params, "firstname", &text_not_blank(&1, &2, "firstname", 100))
      |> maybe(params, "lastname", &text_not_blank(&1, &2, "lastname", 100))
      |> maybe(params, "email", &text_not_blank(&1, &2, "email", 254))
      |> maybe(params, "roles", fn v, p ->
        v |> Validation.param("roles", role_ids(p)) |> Validation.array_not_empty()
      end)
      |> maybe(params, "password", &validate_password(&1, &2, false))

    Validation.raise_if_errors!(validation)
  end

  defp maybe(validation, params, key, fun),
    do: if(Params.exists?(params, key), do: fun.(validation, params), else: validation)

  defp text_not_blank(validation, params, key, max) do
    validation
    |> Validation.param(key, Params.string(params, key))
    |> Validation.not_blank()
    |> Validation.max_length(max)
  end

  defp validate_password(validation, params, required?) do
    password = Params.string(params, "password")
    repeat = Params.string(params, "repeatPassword")

    validation = Validation.param(validation, "password", password)
    validation = if required?, do: Validation.not_blank(validation), else: validation

    validation =
      case PasswordPolicies.active() do
        %{regex: regex, description: description} ->
          Validation.matches(validation, regex, description)

        nil ->
          validation
      end

    if password,
      do: Validation.equal_to_parameter(validation, "repeatPassword", repeat),
      else: validation
  end

  defp role_ids(params) do
    case Params.value(params, "roles") do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> nil
    end
  end

  defp office!(office_id) do
    if TenantRepo.exists?(from(o in "m_office", where: o.id == ^office_id)),
      do: office_id,
      else:
        raise(ResourceNotFound,
          code: "error.msg.office.id.invalid",
          message: "Office with identifier #{office_id} does not exist",
          args: [office_id]
        )
  end

  defp roles!(role_ids) do
    for raw <- role_ids do
      id = raw |> Integer.parse() |> elem(0)

      if TenantRepo.exists?(from(r in "m_role", where: r.id == ^id)),
        do: id,
        else:
          raise(ResourceNotFound,
            code: "error.msg.role.id.invalid",
            message: "Role with identifier #{id} does not exist",
            args: [id]
          )
    end
  end

  # A linked staff member must belong to the user's office.
  defp staff_in_office!(nil, _office_id), do: nil

  defp staff_in_office!(staff_id, office_id) do
    if TenantRepo.exists?(
         from s in "m_staff", where: s.id == ^staff_id and s.office_id == ^office_id
       ),
       do: staff_id,
       else:
         raise(ResourceNotFound,
           code: "error.msg.staff.id.invalid",
           message: "Staff with identifier #{staff_id} does not exist",
           args: [staff_id]
         )
  end

  defp set_roles!(user_id, role_ids) do
    TenantRepo.delete_all(from(ur in "m_appuser_role", where: ur.appuser_id == ^user_id))

    TenantRepo.insert_all(
      "m_appuser_role",
      for(role_id <- Enum.uniq(role_ids), do: %{appuser_id: user_id, role_id: role_id})
    )
  end

  defp refuse_email!(email) do
    message =
      "Sending email failed; is parameter email is invalid? More details available in server log: no mail server is configured"

    raise PlatformApiDataValidation,
      errors: [
        ECBPlatform.Errors.parameter_error("error.msg.user.email.invalid", message, "email", [
          email
        ])
      ]
  end

  # The validation lets a missing password through (as Fineract's does) and a request that gets that far
  # has none to store. A username that is taken is reported first, as Fineract reports it.
  defp ensure_password!(password, _username) when is_binary(password), do: :ok

  defp ensure_password!(nil, username) do
    if TenantRepo.exists?(from(u in "m_appuser", where: u.username == ^String.trim(username))) do
      raise ECBPlatform.Errors.DataIntegrity,
        code: "error.msg.user.duplicate.username",
        message: "User with username #{username} already exists.",
        parameter: "username",
        args: [username]
    end

    raise PlatformApiDataValidation,
      errors: [
        ECBPlatform.Errors.parameter_error(
          "validation.msg.user.password.cannot.be.blank",
          "The parameter `password` is mandatory.",
          "password",
          [nil]
        )
      ]
  end

  defp resolve_retries(@system_user, _requested), do: false

  defp resolve_retries(username, requested),
    do: String.downcase(username) != @system_user and requested

  # --- changes (the order Fineract reports them is not significant) -----------------------------

  defp change_password(changes, user, params) do
    if Params.exists?(params, "password") and password_differs?(params, user),
      do: [{:password, Params.string(params, "password")} | changes],
      else: changes
  end

  # As in Fineract, any password sent counts as a change: the stored hash is salted, so "the same
  # password" is never recognised, and a repeat of the current one is simply stored again.
  defp password_differs?(params, _user), do: Params.string(params, "password") != nil

  defp change_long(changes, params, key, column, existing) do
    if Params.changed_long?(params, key, existing),
      do: [{column, Params.long(params, key)} | changes],
      else: changes
  end

  defp change_text(changes, params, key, column, existing) do
    if Params.changed_string?(params, key, existing),
      do: [{column, Params.command_string(params, key)} | changes],
      else: changes
  end

  defp change_boolean(changes, params, key, column, existing) do
    if Params.exists?(params, key) and Params.changed_boolean?(params, key, existing),
      do: [{column, Params.boolean(params, key)} | changes],
      else: changes
  end

  defp change_staff(changes, params, user) do
    if Params.exists?(params, "staffId") and
         (is_nil(user.staff_id) or Params.changed_long?(params, "staffId", user.staff_id)),
       do: [{:staff_id, Params.long(params, "staffId")} | changes],
       else: changes
  end

  defp change_roles(changes, params, user) do
    wanted = role_ids(params)

    current =
      TenantRepo.all(
        from ur in "m_appuser_role", where: ur.appuser_id == ^user.id, select: ur.role_id
      )

    if Params.exists?(params, "roles") and wanted != nil and
         Enum.sort(wanted) != Enum.sort(Enum.map(current, &Integer.to_string/1)),
       do: [{:roles, wanted} | changes],
       else: changes
  end

  defp change_retries(changes, params, user) do
    if Params.exists?(params, "isLoginRetriesEnabled") do
      effective =
        resolve_retries(user.username, Params.boolean(params, "isLoginRetriesEnabled") == true)

      if effective != user.is_login_retries_enabled,
        do: [{:is_login_retries_enabled, effective} | changes],
        else: changes
    else
      changes
    end
  end

  defp apply_staff!(changes, user, final_office, moved_to) do
    cond do
      Keyword.has_key?(changes, :staff_id) ->
        staff_in_office!(Keyword.fetch!(changes, :staff_id), final_office)

      moved_to && user.staff_id ->
        staff_in_office!(user.staff_id, final_office)

      true ->
        :unchanged
    end
  end

  defp save_user!(id, changes, staff_id) do
    columns =
      for {column, value} <- changes,
          column not in [:roles, :password, :staff_id],
          do: {column, value}

    columns = if staff_id == :unchanged, do: columns, else: [{:staff_id, staff_id} | columns]
    columns = password_columns(columns, changes)

    unless columns == [] do
      guard(Keyword.get(columns, :username), fn ->
        TenantRepo.update_all(from(u in "m_appuser", where: u.id == ^id), set: columns)
      end)
    end
  end

  # A new password is stored as a fresh bcrypt hash; the account no longer has to reset it.
  defp password_columns(columns, changes) do
    case Keyword.fetch(changes, :password) do
      {:ok, raw} ->
        [
          {:password, Password.encode(raw)},
          {:last_time_password_updated, Date.utc_today()},
          {:password_reset_required, false}
          | columns
        ]

      :error ->
        columns
    end
  end

  defp shown(changes) do
    for {column, value} <- changes, into: %{} do
      if column == :password, do: {"password", true}, else: {shown_key(column), value}
    end
  end

  defp shown_key(:office_id), do: "officeId"
  defp shown_key(:staff_id), do: "staffId"
  defp shown_key(:password), do: "password"
  defp shown_key(:roles), do: "roles"
  defp shown_key(:password_never_expires), do: "passwordNeverExpires"
  defp shown_key(:is_login_retries_enabled), do: "isLoginRetriesEnabled"
  defp shown_key(:is_password_reset_enabled), do: "isPasswordResetAllowed"
  defp shown_key(other), do: Atom.to_string(other)

  defp check_password_reuse!(user, params) do
    raw = Params.string(params, "password")

    with true <- raw != nil and password_differs?(params, user),
         %{enabled: true, value: count} <- Configuration.get("password-reuse-check-history-count") do
      if previously_used?(user.id, raw, count) do
        raise PlatformApiDataValidation,
          errors: [
            ECBPlatform.Errors.parameter_error(
              "error.msg.password.already.used",
              "The submitted password has already been used in the past",
              nil
            )
          ]
      end
    end

    :ok
  end

  defp previously_used?(user_id, raw, count) do
    query =
      from p in "m_appuser_previous_password",
        where: p.user_id == ^user_id,
        order_by: [desc: p.removal_date, desc: p.id],
        select: p.password

    query = if count in [nil, 0], do: query, else: limit(query, ^count)
    Enum.any?(TenantRepo.all(query), &Password.matches?(raw, &1))
  end

  # The password being replaced is kept so it cannot be chosen again.
  defp remember_old_password!(user, changes) do
    if Keyword.has_key?(changes, :password) do
      TenantRepo.insert_all("m_appuser_previous_password", [
        %{user_id: user.id, password: user.password, removal_date: Date.utc_today()}
      ])
    end
  end

  defp guard(username, fun) do
    Integrity.translate(
      fun,
      %{
        "username_org" =>
          {"error.msg.user.duplicate.username", "User with username #{username} already exists.",
           "username", [username]}
      },
      {"error.msg.unknown.data.integrity.issue", "Unknown data integrity issue with resource."}
    )
  end
end
