defmodule ECBParty.Identifiers do
  @moduledoc """
  The identity documents of a client (`m_client_identifier`): a passport number, a national id. Read
  and write sides, following Fineract's `ClientIdentifierReadPlatformServiceImpl`,
  `ClientIdentifierWritePlatformServiceJpaRepositoryImpl` and the `ClientIdentifier` entity.

  A document has a type (any code value), a key and a status. The same key may not be held twice for one
  type, whoever holds it. Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBParty.Clients
  alias ECBParty.Json
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.{DomainRuleViolation, ResourceNotFound}
  alias ECBPlatform.{Params, TenantRepo, Validation}
  alias ECBPlatform.Security.User

  @supported ~w(documentTypeId documentKey status description issuanceDate expiryDate locale dateFormat)

  @inactive 100
  @active 200
  @invalid 0

  @statuses %{"INACTIVE" => @inactive, "ACTIVE" => @active, "INVALID" => @invalid}

  # --- read -----------------------------------------------------------------------------------

  @doc "The identifiers of client `client_id` visible to the user, by id (none for a client out of reach)."
  @spec list(User.t(), integer) :: [map]
  def list(%User{} = user, client_id) do
    base(user, client_id) |> order_by([i], i.id) |> TenantRepo.all() |> Enum.map(&finish/1)
  end

  @doc "One identifier of a client, or `{:error, ResourceNotFound}`."
  @spec get(User.t(), integer, integer) :: {:ok, map} | {:error, Exception.t()}
  def get(%User{} = user, client_id, id) do
    case base(user, client_id) |> where([i], i.id == ^id) |> TenantRepo.one() do
      nil -> {:error, not_found(id)}
      row -> {:ok, finish(row)}
    end
  end

  @doc "The status as the text a read shows."
  @spec status_code(integer) :: String.t()
  def status_code(@inactive), do: "clientIdentifierStatusType.inactive"
  def status_code(@active), do: "clientIdentifierStatusType.active"
  def status_code(_), do: "clientIdentifierStatusType.invalid"

  defp base(user, client_id) do
    pattern = ECBOrg.Offices.user_hierarchy_pattern(user)

    from(i in "m_client_identifier",
      join: c in "m_client",
      on: c.id == i.client_id,
      join: o in "m_office",
      on: o.id == c.office_id,
      join: cv in "m_code_value",
      on: cv.id == i.document_type_id,
      where: i.client_id == ^client_id and like(o.hierarchy, ^pattern),
      select: %{
        id: i.id,
        client_id: i.client_id,
        document_type_id: i.document_type_id,
        document_type: cv.code_value,
        document_key: i.document_key,
        description: i.description,
        status: i.status,
        issuance_date: i.issuance_date,
        expiry_date: i.expiry_date
      }
    )
  end

  defp finish(row), do: Map.put(row, :status_code, status_code(row.status))

  @doc "The not-found error."
  @spec not_found(integer) :: Exception.t()
  def not_found(id),
    do:
      ResourceNotFound.new(
        "error.msg.clientIdentifier.id.invalid",
        "Client Identifier with the primary key #{id} does not exist",
        [id]
      )

  # --- create ---------------------------------------------------------------------------------

  @doc "Adds an identifier to client `client_id`."
  @spec create!(User.t(), integer, Params.t()) :: Result.t()
  def create!(%User{} = user, client_id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    type_id = Json.long(p, "documentTypeId")
    key = Params.string(p, "documentKey")
    issuance = Params.date(p, "issuanceDate")
    expiry = Params.date(p, "expiryDate")

    Validation.new("clientIdentifier")
    |> Validation.param("documentTypeId", type_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.param("documentKey", key)
    |> Validation.not_blank()
    |> Validation.raise_if_errors!()

    client = Clients.fetch!(client_id)
    type = code_value!(type_id)
    status = status_value!(Params.string(p, "status"))

    check_lengths!(key, Params.string(p, "description"))
    ensure_unique!(client_id, type, key, status == @active, nil)

    {1, [%{id: id}]} =
      TenantRepo.insert_all(
        "m_client_identifier",
        [
          Map.merge(
            %{
              client_id: client_id,
              document_type_id: type.id,
              document_key: key,
              status: status,
              description: blank_to_nil(Params.string(p, "description")),
              issuance_date: issuance,
              expiry_date: expiry,
              active: if(status == @active, do: @active)
            },
            audit(user)
          )
        ],
        returning: [:id]
      )

    Result.new(office_id: client.office_id, client_id: client_id, resource_id: id)
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Changes identifier `id` of client `client_id`."
  @spec update!(User.t(), integer, integer, Params.t()) :: Result.t()
  def update!(%User{} = user, client_id, id, %Params{} = p) do
    Params.check_supported!(p, @supported)
    type_id = Json.long(p, "documentTypeId")
    key = Params.string(p, "documentKey")
    issuance = if Params.exists?(p, "issuanceDate"), do: Params.date(p, "issuanceDate")
    expiry = if Params.exists?(p, "expiryDate"), do: Params.date(p, "expiryDate")

    v =
      Validation.new("clientIdentifier")
      |> Validation.param("documentKey", key)
      |> Validation.ignore_if_null()
      |> Validation.not_blank()

    v =
      if Enum.all?(
           [type_id, key, issuance, expiry, exists(p, "issuanceDate"), exists(p, "expiryDate")],
           &is_nil/1
         ),
         do: Validation.no_parameters_for_update(v),
         else: v

    Validation.raise_if_errors!(v)

    client = Clients.fetch!(client_id)
    row = fetch_row!(id)
    {changes, set} = changes(p, row)

    type =
      if Map.has_key?(changes, "documentTypeId"),
        do: code_value!(type_id),
        else: code_value!(row.document_type_id)

    set = if type.id == row.document_type_id, do: set, else: set ++ [document_type_id: type.id]

    unless set == [] do
      ensure_unique!(client_id, type, key || row.document_key, row.active == @active, id)

      TenantRepo.update_all(from(i in "m_client_identifier", where: i.id == ^id),
        set: set ++ audit_set(user)
      )
    end

    Result.new(
      office_id: client.office_id,
      client_id: client_id,
      resource_id: id,
      changes: if(changes == %{}, do: nil, else: changes)
    )
  end

  defp exists(p, key), do: if(Params.exists?(p, key), do: true)

  defp fetch_row!(id) do
    TenantRepo.one(
      from(i in "m_client_identifier",
        where: i.id == ^id,
        select: %{
          id: i.id,
          document_type_id: i.document_type_id,
          document_key: i.document_key,
          description: i.description,
          status: i.status,
          active: i.active,
          issuance_date: i.issuance_date,
          expiry_date: i.expiry_date
        }
      )
    ) || raise not_found(id)
  end

  defp changes(p, row) do
    {%{}, []}
    |> change_type(p, row)
    |> change_text(p, "documentKey", row.document_key, :document_key)
    |> change_text(p, "description", row.description, :description)
    |> change_status(p)
    |> change_date(p, "issuanceDate", row.issuance_date, :issuance_date)
    |> change_date(p, "expiryDate", row.expiry_date, :expiry_date)
  end

  defp change_type({changes, set}, p, row) do
    if Params.changed_long?(p, "documentTypeId", row.document_type_id),
      do: {Map.put(changes, "documentTypeId", Json.long(p, "documentTypeId")), set},
      else: {changes, set}
  end

  defp change_text({changes, set}, p, key, existing, column) do
    if Params.changed_string?(p, key, existing) do
      value = Params.command_string(p, key)
      {Map.put(changes, key, value), set ++ [{column, blank_to_nil(value)}]}
    else
      {changes, set}
    end
  end

  # Fineract compares the status sent with the status's long code, so a status sent is always a change; the
  # name must be in capitals, and only the status is stored (the active flag stays as it was).
  defp change_status({changes, set}, p) do
    if Params.exists?(p, "status") do
      name = Params.command_string(p, "status")
      value = status_exact!(name)
      {Map.put(changes, "status", name), set ++ [status: value]}
    else
      {changes, set}
    end
  end

  defp change_date({changes, set}, p, key, existing, column) do
    if Params.changed_date?(p, key, existing) do
      value = Params.date(p, key)
      {Map.put(changes, key, value), set ++ [{column, value}]}
    else
      {changes, set}
    end
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes identifier `id` of client `client_id`."
  @spec delete!(User.t(), integer, integer) :: Result.t()
  def delete!(%User{} = _user, client_id, id) do
    client = Clients.fetch!(client_id)
    _row = fetch_row!(id)
    TenantRepo.delete_all(from(i in "m_client_identifier", where: i.id == ^id))
    Result.new(office_id: client.office_id, client_id: client_id, resource_id: id)
  end

  # --- shared ---------------------------------------------------------------------------------

  defp code_value!(id) do
    case ECBOrg.Codes.get_value(id) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  # A status given by name when creating: any case (Fineract upper-cases it); no status, or one that is
  # not a status, is an unhandled failure there (a plain HTTP 500).
  defp status_value!(nil), do: raise(ECBLedger.Errors.ServerError)

  defp status_value!(text) do
    Map.get(@statuses, String.upcase(text)) || raise ECBLedger.Errors.ServerError
  end

  # A status given by name when changing: exactly as the enum names it.
  defp status_exact!(text), do: Map.get(@statuses, text) || raise(ECBLedger.Errors.ServerError)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp audit(user) do
    now = DateTime.utc_now()

    %{
      created_by: user.id,
      last_modified_by: user.id,
      created_on_utc: now,
      last_modified_on_utc: now
    }
  end

  defp audit_set(user), do: [last_modified_by: user.id, last_modified_on_utc: DateTime.utc_now()]

  # The two things an identifier cannot repeat, as the errors Fineract gives for them: an active document of
  # one type twice for a client (checked first), and the same key of the same type held by anyone.
  defp ensure_unique!(client_id, type, key, active?, except_id) do
    others = from(i in "m_client_identifier", where: i.id != ^(except_id || 0))

    if active? and
         TenantRepo.exists?(
           from(i in others,
             where:
               i.client_id == ^client_id and i.document_type_id == ^type.id and
                 i.active == ^@active
           )
         ) do
      burn_id(except_id)

      raise DomainRuleViolation,
        code: "error.msg.clientIdentifier.type.duplicate",
        message:
          "Active Client identifier of type #{type.name} is already present for this client",
        args: [type.name]
    end

    if TenantRepo.exists?(
         from(i in others, where: i.document_type_id == ^type.id and i.document_key == ^key)
       ) do
      {name, office} = holder(type.id, key, except_id)
      burn_id(except_id)

      raise DomainRuleViolation,
        code: "error.msg.clientIdentifier.identityKey.duplicate",
        message:
          "Client #{name}under #{office} Branch already has a #{type.name} with unique key #{key}",
        args: [name, office, type.name, key]
    end

    :ok
  end

  # A key or description longer than its column holds is refused by the database before anything else, as an
  # unknown data-integrity problem; the failed insert has used up an id.
  defp check_lengths!(key, description) do
    if String.length(key || "") > 50 or String.length(description || "") > 500 do
      burn_id(nil)

      raise ECBPlatform.Errors.DataIntegrity,
        code: "error.msg.clientIdentifier.unknown.data.integrity.issue",
        message: "Unknown data integrity issue with resource.",
        parameter: nil,
        args: []
    end
  end

  # Fineract only finds the duplicate when the database refuses the new row, which has used up an id
  defp burn_id(nil),
    do: TenantRepo.query!("SELECT nextval(pg_get_serial_sequence('m_client_identifier', 'id'))")

  defp burn_id(_existing), do: :ok

  defp holder(type_id, key, except_id) do
    case TenantRepo.query!(
           """
           SELECT c.display_name, o.name FROM m_client_identifier i
           JOIN m_client c ON c.id = i.client_id JOIN m_office o ON o.id = c.office_id
           WHERE i.document_type_id = $1 AND i.document_key = $2 AND i.id <> $3 LIMIT 1
           """,
           [type_id, key, except_id || 0]
         ).rows do
      [[name, office]] -> {name, office}
      _ -> {"", ""}
    end
  end
end
