defmodule ECBOrg.Offices.Write do
  @moduledoc """
  Creating and changing offices, following Fineract's `OfficeWritePlatformServiceJpaRepositoryImpl`
  and `Office` entity.

  A user may only act on offices at or below their own in the hierarchy. A new office needs a parent
  (every office but the head office has one); its `hierarchy` is the parent's followed by its own id
  (`.` then `.2.` then `.2.7.`).

  Both functions run inside a command's transaction, take the parsed request and raise Fineract's
  errors, which the command pipeline reports.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Errors.NoAuthorization
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DataIntegrity, DomainRuleViolation}
  alias ECBPlatform.Params
  alias ECBPlatform.Security.User
  alias ECBPlatform.TenantRepo
  alias ECBPlatform.Validation

  @supported ~w(name parentId openingDate externalId locale dateFormat)

  @not_permitted "User does not have sufficient priviledges to act on the provided office."

  @doc "Creates the office described by `params`. Returns the command result."
  @spec create!(User.t(), Params.t()) :: Result.t()
  def create!(%User{} = user, %Params{} = params) do
    params = Params.check_supported!(params, @supported)

    name = Params.string(params, "name")
    opening_date = Params.date(params, "openingDate")
    external_id = Params.string(params, "externalId")
    parent_id = if Params.exists?(params, "parentId"), do: Params.long(params, "parentId")

    validation =
      Validation.new("office")
      |> Validation.param("name", name)
      |> Validation.not_blank()
      |> Validation.max_length(100)
      |> Validation.param("openingDate", opening_date)
      |> Validation.not_null()

    validation =
      if Params.exists?(params, "externalId"),
        do:
          validation |> Validation.param("externalId", external_id) |> Validation.max_length(100),
        else: validation

    validation =
      if Params.exists?(params, "parentId"),
        do:
          validation
          |> Validation.param("parentId", parent_id)
          |> Validation.not_null()
          |> Validation.greater_than_zero(),
        else: validation

    Validation.raise_if_errors!(validation)

    parent = authorize!(user, parent_id)
    id = next_id()

    with_integrity_errors(name, external_id, fn ->
      TenantRepo.insert_all("m_office", [
        %{
          id: id,
          parent_id: parent.id,
          hierarchy: parent.hierarchy <> "#{id}.",
          name: String.trim(name),
          external_id: external_id,
          opening_date: opening_date
        }
      ])
    end)

    Result.new(resource_id: id, office_id: id)
  end

  @doc "Changes office `id` as `params` say. The result lists what actually changed."
  @spec update!(User.t(), integer, Params.t()) :: Result.t()
  def update!(%User{} = user, id, %Params{} = params) do
    params = Params.check_supported!(params, @supported)
    validate_for_update!(params)

    office = authorize!(user, id)
    changes = apply_changes!(user, office, params)

    unless changes == %{} do
      with_integrity_errors(
        Params.string(params, "name"),
        Params.string(params, "externalId"),
        fn ->
          save_changes!(office, changes)
        end
      )
    end

    Result.new(resource_id: id, office_id: id, changes: public_changes(changes))
  end

  # --- validation -----------------------------------------------------------------------------

  defp validate_for_update!(params) do
    validation = Validation.new("office")

    validation =
      if Params.exists?(params, "name"),
        do:
          validation
          |> Validation.param("name", Params.string(params, "name"))
          |> Validation.not_blank()
          |> Validation.max_length(100),
        else: validation

    validation =
      if Params.exists?(params, "openingDate"),
        do:
          validation
          |> Validation.param("openingDate", Params.date(params, "openingDate"))
          |> Validation.not_null(),
        else: validation

    validation =
      if Params.exists?(params, "externalId"),
        do:
          validation
          |> Validation.param("externalId", Params.string(params, "externalId"))
          |> Validation.max_length(100),
        else: validation

    validation =
      if Params.exists?(params, "parentId") do
        parent_id = Params.long(params, "parentId")

        validation
        |> Validation.param("parentId", parent_id)
        |> Validation.not_null()
        |> Validation.greater_than_zero()
      else
        validation
      end

    Validation.raise_if_errors!(validation)
  end

  # --- changes --------------------------------------------------------------------------------

  # What would change, with the new values. `:new_parent` and `:set` carry what to store; the rest is
  # what the response shows.
  defp apply_changes!(user, office, params) do
    if Params.exists?(params, "parentId") and is_nil(office.parent_id),
      do:
        raise(DomainRuleViolation,
          code: "error.msg.office.cannot.update.parent.office.of.root.office",
          message: "The root office must not be set with a parent office."
        )

    %{}
    |> change_parent(user, office, params)
    |> change_opening_date(office, params)
    |> change_text(office, params, "name", :name)
    |> change_text(office, params, "externalId", :external_id)
  end

  defp change_parent(changes, user, office, params) do
    if office.parent_id && Params.changed_long?(params, "parentId", office.parent_id) do
      new_parent_id = Params.long(params, "parentId")
      parent = authorize!(user, new_parent_id)

      if office.id == parent.id,
        do:
          raise(DomainRuleViolation,
            code: "error.msg.office.parentId.same.as.id",
            message: "Cannot update office with parent same as self.",
            args: [office.id, parent.id]
          )

      if String.starts_with?(parent.hierarchy, office.hierarchy),
        do:
          raise(DomainRuleViolation,
            code: "error.msg.office.parentId.is.descendant",
            message: "Cannot move an office under one of its own sub-offices.",
            args: [office.id, parent.id]
          )

      changes |> Map.put("parentId", new_parent_id) |> Map.put(:new_parent, parent)
    else
      changes
    end
  end

  defp change_opening_date(changes, office, params) do
    if Params.changed_date?(params, "openingDate", office.opening_date) do
      changes
      |> Map.put("openingDate", Params.string(params, "openingDate"))
      |> Map.put("dateFormat", Params.date_format(params))
      |> Map.put("locale", Params.locale(params))
      |> Map.put(:opening_date, Params.date(params, "openingDate"))
    else
      changes
    end
  end

  defp change_text(changes, office, params, key, field) do
    if Params.changed_string?(params, key, Map.fetch!(office, field)) do
      value = Params.command_string(params, key)

      changes
      |> Map.put(key, value)
      |> Map.put({:set, field}, if(value == "", do: nil, else: String.trim(value)))
    else
      changes
    end
  end

  defp public_changes(changes) do
    for {key, value} <- changes, is_binary(key), into: %{}, do: {key, value}
  end

  defp save_changes!(office, changes) do
    set =
      for {{:set, field}, value} <- changes, do: {field, value}

    set = if date = changes[:opening_date], do: [{:opening_date, date} | set], else: set

    set =
      if parent = changes[:new_parent],
        do: [{:parent_id, parent.id}, {:hierarchy, parent.hierarchy <> "#{office.id}."} | set],
        else: set

    TenantRepo.update_all(from(o in "m_office", where: o.id == ^office.id), set: set)

    if parent = changes[:new_parent], do: rewrite_descendants!(office, parent)
  end

  # Moving an office moves everything beneath it: their hierarchy paths start with the old path.
  defp rewrite_descendants!(office, new_parent) do
    new_prefix = new_parent.hierarchy <> "#{office.id}."

    TenantRepo.query!(
      """
      UPDATE m_office SET hierarchy = $1 || substr(hierarchy, $2)
      WHERE hierarchy LIKE $3 AND id <> $4
      """,
      [new_prefix, String.length(office.hierarchy) + 1, office.hierarchy <> "%", office.id]
    )
  end

  # --- offices and access ---------------------------------------------------------------------

  # The office, if it exists and is the user's own or below it; otherwise Fineract's refusal.
  defp authorize!(%User{} = user, office_id) do
    office = office_id && find(office_id)
    user_hierarchy = user_hierarchy(user)

    if office && String.starts_with?(office.hierarchy, user_hierarchy),
      do: office,
      else: raise(NoAuthorization, permission: nil, message: @not_permitted)
  end

  defp find(id) do
    TenantRepo.one(
      from o in "m_office",
        where: o.id == ^id,
        select: %{
          id: o.id,
          parent_id: o.parent_id,
          hierarchy: o.hierarchy,
          name: o.name,
          external_id: o.external_id,
          opening_date: o.opening_date
        }
    )
  end

  defp user_hierarchy(%User{office_id: nil}), do: "."

  defp user_hierarchy(%User{office_id: office_id}),
    do:
      TenantRepo.one(from o in "m_office", where: o.id == ^office_id, select: o.hierarchy) || "."

  defp next_id do
    %{rows: [[id]]} =
      TenantRepo.query!("SELECT nextval(pg_get_serial_sequence('m_office', 'id'))")

    id
  end

  # A duplicate name or external id is reported with its own message, not as a raw database error.
  defp with_integrity_errors(name, external_id, fun) do
    fun.()
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :unique_violation, constraint: "m_office_name_key"} ->
          reraise DataIntegrity.exception(
                    code: "error.msg.office.duplicate.name",
                    message: "Office with name `#{name}` already exists",
                    parameter: "name",
                    args: [name]
                  ),
                  __STACKTRACE__

        %{code: :unique_violation, constraint: "m_office_external_id_key"} ->
          reraise DataIntegrity.exception(
                    code: "error.msg.office.duplicate.externalId",
                    message: "Office with externalId `#{external_id}` already exists",
                    parameter: "externalId",
                    args: [external_id]
                  ),
                  __STACKTRACE__

        _ ->
          reraise error, __STACKTRACE__
      end
  end
end
