defmodule ECBParty.Clients.Write do
  @moduledoc """
  Creating, changing and deleting clients, and moving them through their life (activate, close, reject,
  withdraw, reactivate, undo a rejection or withdrawal, assign or unassign staff), following Fineract's
  `ClientWritePlatformServiceJpaRepositoryImpl` and the `Client` entity.

  A client starts pending, or active when created with `active: true`. Only a pending client may be
  deleted, rejected or withdrawn; only a closed one reactivated (which makes it pending again).
  """
  import Ecto.Query

  alias ECBOrg.Offices
  alias ECBParty.Clients
  alias ECBParty.Clients.{Domain, Validate}
  alias ECBParty.Lookups
  alias ECBPlatform.{BusinessDate, Configuration, Integrity, Params, TenantRepo}
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.Security.User

  @gender "Gender"
  @client_type "ClientType"
  @classification "ClientClassification"
  @closure_reason "ClientClosureReason"
  @reject_reason "ClientRejectReason"
  @withdraw_reason "ClientWithdrawReason"

  @date_params ["locale", "dateFormat"]

  # --- create ---------------------------------------------------------------------------------

  @doc "Creates the client `params` describe, with its entity details, addresses and family members."
  @spec create!(User.t(), Params.t()) :: Result.t()
  def create!(%User{} = user, %Params{} = p) do
    Params.check_supported!(p, Validate.create_supported())
    np = non_person(p, Validate.non_person_create_supported())
    address_on? = Configuration.enabled?("enable-address")

    Validate.create!(p, np, address_on?)

    office = Lookups.office!(ECBPlatform.Json.long(p, "officeId"))
    refs = references(p, office)
    legal_form = Params.integer(p, "legalFormId") || 1
    client = new_client(p, office, legal_form)
    Domain.validate_activation!(client, BusinessDate.current())

    external_id = Params.string(p, "externalId")
    account_no = Params.string(p, "accountNo")

    id =
      insert!(user, p, %{
        names: names(p),
        client: client,
        account_no: account_no,
        external_id: external_id,
        refs: refs,
        legal_form: legal_form,
        active?: client.status == Clients.status(:active)
      })

    if account_no == nil do
      number = generate_account_no(id, office.name, refs.client_type && refs.client_type.name)
      guard(p, fn -> set!(id, account_no: number) end)
    end

    if legal_form == 2, do: Domain.create_non_person!(id, np, Params.date(p, "dateOfBirth"))
    guard(p, fn -> Domain.after_create!(id, p, address_on?) end)

    Result.new(
      office_id: office.id,
      client_id: id,
      resource_id: id,
      resource_external_id: external_id
    )
  end

  # What a new client points to, each looked up as Fineract does (and refused when it is not there).
  defp references(p, office) do
    if group_id = ECBPlatform.Json.long(p, "groupId"), do: Lookups.group!(group_id)
    staff_id = resolve_staff(ECBPlatform.Json.long(p, "staffId"), office.hierarchy)
    gender = code_value(p, "genderId", @gender)
    client_type = code_value(p, "clientTypeId", @client_type)
    classification = code_value(p, "clientClassificationId", @classification)
    savings_product = ECBPlatform.Json.long(p, "savingsProductId")
    if savings_product, do: Lookups.savings_product!(savings_product)

    %{
      staff_id: staff_id,
      gender: gender,
      client_type: client_type,
      classification: classification,
      savings_product: savings_product
    }
  end

  # The state and dates a new client starts with: pending, or active from the activation date, submitted
  # today unless it says otherwise (and never after it was activated).
  defp new_client(p, office, legal_form) do
    active? = Params.boolean(p, "active") == true
    activation = if active?, do: Params.date(p, "activationDate")

    submitted =
      if Params.exists?(p, "submittedOnDate"),
        do: Params.date(p, "submittedOnDate"),
        else: BusinessDate.current()

    %{
      status: if(active?, do: Clients.status(:active), else: Clients.status(:pending)),
      office: office,
      activation_date: activation,
      submitted_on:
        if(active? and later?(submitted, activation), do: activation, else: submitted),
      reopened_on: nil,
      legal_form: legal_form
    }
  end

  defp insert!(user, p, c) do
    now = DateTime.utc_now()
    names = c.names

    row = %{
      account_no: c.account_no || temporary_account_no(),
      external_id: c.external_id,
      status_enum: c.client.status,
      activation_date: c.client.activation_date,
      office_joining_date: c.client.activation_date,
      office_id: c.client.office.id,
      staff_id: c.refs.staff_id,
      firstname: names.firstname,
      middlename: names.middlename,
      lastname: names.lastname,
      fullname: names.fullname,
      display_name: display_name(names, c.legal_form),
      mobile_no: trimmed(Params.string(p, "mobileNo")),
      # Fineract takes `isStaff` in but never stores it, so every client is not staff
      is_staff: false,
      gender_cv_id: c.refs.gender && c.refs.gender.id,
      date_of_birth: Params.date(p, "dateOfBirth"),
      submittedon_date: c.client.submitted_on,
      activatedon_userid: if(c.active?, do: user.id),
      default_savings_product: c.refs.savings_product,
      client_type_cv_id: c.refs.client_type && c.refs.client_type.id,
      client_classification_cv_id: c.refs.classification && c.refs.classification.id,
      legal_form_enum: c.legal_form,
      email_address: trimmed(Params.string(p, "emailAddress")),
      created_on_utc: now,
      created_by: user.id,
      last_modified_by: user.id,
      last_modified_on_utc: now
    }

    {1, [%{id: id}]} =
      guard(p, fn -> TenantRepo.insert_all("m_client", [row], returning: [:id]) end)

    id
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes client `id`; the result lists what changed."
  @spec update!(User.t(), integer, Params.t()) :: Result.t()
  def update!(%User{} = user, id, %Params{} = p) do
    Params.check_supported!(p, Validate.update_supported())
    np = non_person(p, Validate.non_person_update_supported())
    Validate.update!(p, np)

    client = Clients.fetch!(id)
    office = Lookups.office!(client.office_id)
    check_access!(user, office)

    {changes, set} = Domain.changes(p, client)
    updated = Domain.apply_changes(client, set)

    Domain.validate_activation!(
      %{
        status: updated.status_enum,
        office: office,
        activation_date: updated.activation_date,
        submitted_on: updated.submitted_on,
        reopened_on: reopened_on(id),
        legal_form: updated.legal_form_enum
      },
      BusinessDate.current()
    )

    set = set ++ [display_name: Domain.display_name(updated)]

    {changes, set} = Domain.resolve_references(p, client, office, changes, set)

    unless changes == %{} do
      guard(p, fn -> set!(id, set ++ audit(user)) end)
    end

    changes = Domain.change_non_person!(id, p, np, updated, changes)

    Result.new(
      office_id: office.id,
      client_id: id,
      resource_id: id,
      resource_external_id: Domain.external_id_after(client, set),
      changes: changes
    )
  end

  defp reopened_on(id),
    do: TenantRepo.one(from(c in "m_client", where: c.id == ^id, select: c.reopened_on_date))

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes client `id`, which must still be pending."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    client = Clients.fetch!(id)

    if client.status_enum != Clients.status(:pending) do
      raise DomainRuleViolation,
        code: "error.msg.clients.cannot.be.deleted",
        message: "Client with identifier #{id} cannot be deleted as it is not in Pending state.",
        args: [id]
    end

    Integrity.translate(
      fn ->
        Domain.delete_dependents!(id)
        TenantRepo.delete_all(from(c in "m_client", where: c.id == ^id))
      end,
      %{},
      {"error.msg.client.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )

    Result.new(
      office_id: client.office_id,
      client_id: id,
      resource_id: id,
      resource_external_id: blank_to_nil(client.external_id)
    )
  end

  # --- life cycle -----------------------------------------------------------------------------

  @doc "Activates a pending client on the date given."
  @spec activate!(User.t(), integer, Params.t()) :: Result.t()
  def activate!(%User{} = user, id, %Params{} = p) do
    %{date: date} =
      Validate.command!(p, ["activationDate" | @date_params], date: "activationDate")

    client = Clients.fetch!(id)
    office = Lookups.office!(client.office_id)

    if client.status_enum == Clients.status(:active) do
      # Fineract builds this error with its arguments in the wrong places: the parameter name shows as the
      # text for people and the date as the parameter name
      Validate.raise_errors!([
        %{
          code: "error.msg.clients.already.active",
          developer_message: "Cannot activate client. Client is already active.",
          default_message: "activationDate",
          parameter: Domain.format_date(p, date),
          args: []
        }
      ])
    end

    Domain.validate_activation!(
      %{
        status: Clients.status(:active),
        office: office,
        activation_date: date,
        submitted_on: client.submitted_on,
        reopened_on: reopened_on(id),
        legal_form: client.legal_form_enum
      },
      BusinessDate.current()
    )

    set!(
      id,
      [
        activation_date: date,
        activatedon_userid: user.id,
        office_joining_date: date,
        status_enum: Clients.status(:active),
        closedon_date: nil,
        closure_reason_cv_id: nil,
        closedon_userid: nil
      ] ++ audit(user)
    )

    Result.new(
      office_id: client.office_id,
      client_id: id,
      resource_id: id,
      resource_external_id: blank_to_nil(client.external_id)
    )
  end

  @doc "Closes a client; it must not hold open loans or savings accounts."
  @spec close!(User.t(), integer, Params.t()) :: Result.t()
  def close!(%User{} = user, id, %Params{} = p) do
    %{date: date, id: reason_id} =
      Validate.command!(p, ["closureDate", "closureReasonId" | @date_params],
        date: "closureDate",
        id: "closureReasonId"
      )

    client = Clients.fetch!(id)
    reason = Lookups.code_value!(@closure_reason, reason_id)

    cond do
      client.status_enum == Clients.status(:closed) ->
        transition_error("close", "is.already.closed", "Client is already closed.", [])

      client.status_enum in [
        Clients.status(:transfer_in_progress),
        Clients.status(:transfer_on_hold)
      ] ->
        transition_error("close", "is.under.transfer", "Cannot Close a Client under Transfer", [])

      client.status_enum != Clients.status(:pending) and
          later?(client.activation_date, date) ->
        transition_error(
          "close",
          "date.cannot.before.client.actvation.date",
          "The client closureDate cannot be before the client ActivationDate.",
          [date, client.activation_date]
        )

      true ->
        Domain.ensure_no_open_accounts!(id, date)
    end

    set!(
      id,
      [
        closure_reason_cv_id: reason.id,
        closedon_date: date,
        closedon_userid: user.id,
        status_enum: Clients.status(:closed)
      ] ++ audit(user)
    )

    plain_result(client)
  end

  @doc "Rejects a pending client."
  @spec reject!(User.t(), integer, Params.t()) :: Result.t()
  def reject!(%User{} = user, id, %Params{} = p) do
    pending_exit!(user, id, p, %{
      action: "rejection",
      date_key: "rejectionDate",
      reason_key: "rejectionReasonId",
      code_name: @reject_reason,
      status: Clients.status(:rejected),
      columns: [:reject_reason_cv_id, :rejectedon_date, :rejectedon_userid]
    })
  end

  @doc "Withdraws the application of a pending client."
  @spec withdraw!(User.t(), integer, Params.t()) :: Result.t()
  def withdraw!(%User{} = user, id, %Params{} = p) do
    pending_exit!(user, id, p, %{
      action: "withdrawal",
      date_key: "withdrawalDate",
      reason_key: "withdrawalReasonId",
      code_name: @withdraw_reason,
      status: Clients.status(:withdrawn),
      columns: [:withdraw_reason_cv_id, :withdrawn_on_date, :withdraw_on_userid]
    })
  end

  # A pending client leaves with a date and a reason (rejection or withdrawal).
  defp pending_exit!(user, id, p, spec) do
    %{date: date, id: reason_id} =
      Validate.command!(p, [spec.date_key, spec.reason_key | @date_params],
        date: spec.date_key,
        id: spec.reason_key
      )

    client = Clients.fetch!(id)
    reason = Lookups.code_value!(spec.code_name, reason_id)
    check_pending_exit!(client, spec.action, date)

    [reason_column, date_column, user_column] = spec.columns

    set!(
      id,
      [
        {reason_column, reason.id},
        {date_column, date},
        {user_column, user.id},
        status_enum: spec.status
      ] ++ audit(user)
    )

    plain_result(client)
  end

  defp check_pending_exit!(client, action, date) do
    cond do
      client.status_enum != Clients.status(:pending) ->
        transition_error(
          action,
          "on.account.not.in.pending.activation.status",
          "Only clients pending activation may be withdrawn.",
          [date, client.submitted_on]
        )

      later?(client.submitted_on, date) ->
        transition_error(
          action,
          "date.cannot.before.client.submitted.date",
          "The client #{action} date cannot be before the client submitted date.",
          [date, client.submitted_on]
        )

      true ->
        :ok
    end
  end

  @doc "Makes a closed client pending again."
  @spec reactivate!(User.t(), integer, Params.t()) :: Result.t()
  def reactivate!(%User{} = user, id, %Params{} = p) do
    %{date: date} =
      Validate.command!(p, ["reactivationDate" | @date_params], date: "reactivationDate")

    client = Clients.fetch!(id)

    cond do
      client.status_enum != Clients.status(:closed) ->
        transition_error(
          "reactivation",
          "on.nonclosed.account",
          "only closed clients may be reactivated.",
          []
        )

      later?(client.closed_on, date) ->
        transition_error(
          "reactivation",
          "date.cannot.before.client.closed.date",
          "The client reactivation date cannot be before the client closed date.",
          [date, client.closed_on]
        )

      true ->
        :ok
    end

    set!(
      id,
      [
        closedon_date: nil,
        closure_reason_cv_id: nil,
        reactivated_on_date: date,
        reactivated_on_userid: user.id,
        status_enum: Clients.status(:pending)
      ] ++ audit(user)
    )

    plain_result(client)
  end

  @doc "Makes a rejected client pending again."
  @spec undo_rejection!(User.t(), integer, Params.t()) :: Result.t()
  def undo_rejection!(%User{} = user, id, %Params{} = p) do
    reopen!(user, id, p, %{
      from_status: :rejected,
      action: "undorejection",
      code: "on.nonrejected.account",
      message: "only rejected clients may be reactivated.",
      noun: "rejected",
      date_column: :rejectedon_date
    })
  end

  @doc "Makes a withdrawn client pending again."
  @spec undo_withdrawal!(User.t(), integer, Params.t()) :: Result.t()
  def undo_withdrawal!(%User{} = user, id, %Params{} = p) do
    reopen!(user, id, p, %{
      from_status: :withdrawn,
      action: "undoWithdrawal",
      code: "on.nonwithdrawal.account",
      message: "only withdrawal clients may be reactivated.",
      noun: "withdrawal",
      date_column: :withdrawn_on_date
    })
  end

  defp reopen!(user, id, p, spec) do
    %{date: date} =
      Validate.command!(p, ["reopenedDate" | @date_params],
        date: "reopenedDate",
        limit_today: true
      )

    client = Clients.fetch!(id)
    since = Map.fetch!(client_dates(id), spec.date_column)

    cond do
      client.status_enum != Clients.status(spec.from_status) ->
        transition_error(spec.action, spec.code, spec.message, [])

      later?(since, date) ->
        transition_error(
          "reopened",
          "date.cannot.before.client.#{spec.noun}.date",
          "The client reactivation date cannot be before the client #{spec.noun} date.",
          [date, since]
        )

      true ->
        :ok
    end

    set!(
      id,
      [reopened_on_date: date, reopened_by_userid: user.id, status_enum: Clients.status(:pending)] ++
        audit(user)
    )

    plain_result(client)
  end

  defp client_dates(id) do
    TenantRepo.one(
      from(c in "m_client",
        where: c.id == ^id,
        select: %{rejectedon_date: c.rejectedon_date, withdrawn_on_date: c.withdrawn_on_date}
      )
    )
  end

  @doc "Puts a staff member in charge of a client."
  @spec assign_staff!(User.t(), integer, Params.t()) :: Result.t()
  def assign_staff!(%User{} = user, id, %Params{} = p) do
    staff_id = Validate.staff_command!(p, "client")
    client = Clients.fetch!(id)
    office = Lookups.office!(client.office_id)
    Lookups.staff!(staff_id, office.hierarchy)
    set!(id, [staff_id: staff_id] ++ audit(user))
    staff_result(client, %{"staffId" => staff_id})
  end

  @doc "Takes the staff member off a client (when the id named is the one in charge)."
  @spec unassign_staff!(User.t(), integer, Params.t()) :: Result.t()
  def unassign_staff!(%User{} = user, id, %Params{} = p) do
    staff_id = Validate.staff_command!(p, "client")
    client = Clients.fetch!(id)

    if client.staff_id == nil do
      raise ResourceNotFound,
        code: "error.msg.client.has.no.staff",
        message: "Client with identifier #{id} does not have staff",
        args: [id]
    end

    if staff_id == client.staff_id, do: set!(id, [staff_id: nil] ++ audit(user))
    staff_result(client, %{"staffId" => client.staff_id})
  end

  defp staff_result(client, changes),
    do:
      Result.new(
        office_id: client.office_id,
        client_id: client.id,
        resource_id: client.id,
        resource_external_id: blank_to_nil(client.external_id),
        changes: changes
      )

  # --- entity details -------------------------------------------------------------------------

  # The details of an entity client, sent as an object of their own with their own date format.
  defp non_person(p, supported) do
    case Params.value(p, "clientNonPersonDetails") do
      %{} = map ->
        np = %Params{map: map}
        Params.check_supported!(np, supported)
        np

      _ ->
        nil
    end
  end

  # --- shared ---------------------------------------------------------------------------------

  defp resolve_staff(nil, _hierarchy), do: nil
  defp resolve_staff(id, hierarchy), do: Lookups.staff!(id, hierarchy).id

  defp code_value(p, key, code_name) do
    case ECBPlatform.Json.long(p, key) do
      nil -> nil
      id -> Lookups.code_value!(code_name, id)
    end
  end

  defp names(p) do
    %{
      firstname: trimmed(Params.string(p, "firstname")),
      middlename: trimmed(Params.string(p, "middlename")),
      lastname: trimmed(Params.string(p, "lastname")),
      fullname: trimmed(Params.string(p, "fullname"))
    }
  end

  defp display_name(%{fullname: full} = names, legal_form),
    do:
      Domain.display_name(
        Map.put(names, :legal_form_enum, legal_form)
        |> Map.put(:fullname, full)
      )

  defp trimmed(nil), do: nil
  defp trimmed(text), do: String.trim(text)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp later?(nil, _date), do: false
  defp later?(a, b), do: Date.compare(a, b) == :gt

  defp plain_result(client),
    do:
      Result.new(
        client_id: client.id,
        resource_id: client.id,
        resource_external_id: blank_to_nil(client.external_id)
      )

  defp transition_error(action, postfix, message, args),
    do:
      raise(DomainRuleViolation,
        code: "error.msg.client.#{action}.#{postfix}",
        message: message,
        args: Enum.map(args, &if(is_struct(&1, Date), do: Date.to_iso8601(&1), else: &1))
      )

  defp check_access!(%User{} = user, office) do
    if String.starts_with?(office.hierarchy, user_hierarchy(user)) do
      :ok
    else
      raise ECBPlatform.Commands.Errors.NoAuthorization,
        permission: nil,
        message: "User does not have sufficient priviledges to act on the provided office."
    end
  end

  defp user_hierarchy(%User{office_id: nil}), do: "."

  defp user_hierarchy(%User{office_id: office_id}) do
    case Offices.get(office_id) do
      {:ok, office} -> office.hierarchy
      _ -> "."
    end
  end

  # a column named twice takes the last value
  defp set!(id, set) do
    set = set |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0)) |> Enum.reverse()
    TenantRepo.update_all(from(c in "m_client", where: c.id == ^id), set: set)
  end

  defp audit(user), do: [last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]

  defp temporary_account_no,
    do: 10 |> :crypto.strong_rand_bytes() |> Base.encode16() |> binary_part(0, 19)

  # What a data-integrity error is called for each unique key a client has.
  defp guard(p, fun) do
    Integrity.translate(
      fun,
      %{
        "m_client_external_id_key" => duplicate("externalId", p),
        "m_client_mobile_no_key" => duplicate("mobileNo", p)
      },
      {"error.msg.client.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end

  defp duplicate(name, p) do
    value = Params.string(p, name)

    {"error.msg.client.duplicate.#{name}", "Client with #{name} `#{value}` already exists", name,
     [value]}
  end

  # --- account numbers ------------------------------------------------------------------------

  # The number a new client gets from its id: nine digits, with the prefix the tenant's client format asks
  # for (the office name, the client type or a fixed one).
  defp generate_account_no(id, office_name, client_type_name) do
    format =
      TenantRepo.one(
        from(f in "c_account_number_format",
          where: f.account_type_enum == 1,
          select: %{prefix: f.prefix_type_enum, character: f.prefix_character}
        )
      )

    padded = String.pad_leading(Integer.to_string(id), 9, "0")

    case format do
      %{prefix: 1} -> prefixed(office_name, padded)
      %{prefix: 101} -> prefixed(client_type_name, padded)
      %{prefix: 401, character: char} -> fixed_prefix(char, id)
      _ -> padded
    end
  end

  defp prefixed(nil, padded), do: padded
  defp prefixed(prefix, padded), do: String.slice(prefix, 0, 10) <> padded

  defp fixed_prefix(char, id) do
    prefix = String.slice(char || "", 0, 10)
    prefix <> String.pad_leading(Integer.to_string(id), max(9 - String.length(prefix), 0), "0")
  end
end
