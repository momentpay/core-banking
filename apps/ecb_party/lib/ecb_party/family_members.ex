defmodule ECBParty.FamilyMembers do
  @moduledoc """
  The family members of a client (`m_family_members`), following Fineract's family member services. The
  requests are typed (fields Fineract does not list are dropped), and its update has a quirk that is
  kept: a change must name the marital status, gender and profession, or it fails.

  Must run inside a tenant scope.
  """
  import Ecto.Query

  alias ECBParty.Clients
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors.ResourceNotFound
  alias ECBPlatform.{Params, TenantRepo}

  @fields ~w(lastName firstName middleName clientId dateFormat mobileNumber genderId isDependent
             dateOfBirth relationshipId locale familyMembers qualification maritalStatusId id age
             professionId)

  # --- read -----------------------------------------------------------------------------------

  @doc "The family members of client `client_id`, by id."
  @spec list(integer) :: [map]
  def list(client_id), do: base() |> where([f], f.client_id == ^client_id) |> all()

  @doc "One family member of a client, or `{:error, ResourceNotFound}`."
  @spec get(integer, integer) :: {:ok, map} | {:error, Exception.t()}
  def get(client_id, id) do
    case base() |> where([f], f.client_id == ^client_id and f.id == ^id) |> all() do
      [row] -> {:ok, row}
      [] -> {:error, not_found(id, client_id)}
    end
  end

  defp all(query), do: query |> order_by([f], f.id) |> TenantRepo.all()

  defp base do
    from(f in "m_family_members",
      left_join: r in "m_code_value",
      on: r.id == f.relationship_cv_id,
      left_join: m in "m_code_value",
      on: m.id == f.marital_status_cv_id,
      left_join: g in "m_code_value",
      on: g.id == f.gender_cv_id,
      left_join: p in "m_code_value",
      on: p.id == f.profession_cv_id,
      select: %{
        id: f.id,
        client_id: f.client_id,
        first_name: f.firstname,
        middle_name: f.middlename,
        last_name: f.lastname,
        qualification: f.qualification,
        mobile_number: f.mobile_number,
        age: f.age,
        is_dependent: f.is_dependent,
        relationship: r.code_value,
        relationship_id: f.relationship_cv_id,
        marital_status: m.code_value,
        marital_status_id: f.marital_status_cv_id,
        gender: g.code_value,
        gender_id: f.gender_cv_id,
        date_of_birth: f.date_of_birth,
        profession: p.code_value,
        profession_id: f.profession_cv_id
      }
    )
  end

  @doc "The not-found error."
  @spec not_found(integer, integer) :: Exception.t()
  def not_found(id, client_id),
    do:
      ResourceNotFound.new(
        "error.msg.family.member.id.invalid",
        "Family member with identifier #{id} does not exist for client with identifier #{client_id}",
        [id, client_id]
      )

  # --- create ---------------------------------------------------------------------------------

  @doc "Adds a family member to client `client_id`."
  @spec create!(integer, Params.t()) :: Result.t()
  def create!(client_id, %Params{} = p) do
    p = Params.typed(p, @fields)
    typed!(p)

    _client = Clients.fetch!(client_id)
    row = member(p)

    {1, [%{id: id}]} =
      guard(fn ->
        TenantRepo.insert_all("m_family_members", [Map.put(row, :client_id, client_id)],
          returning: [:id]
        )
      end)

    Result.new(resource_id: id)
  end

  @doc """
  Adds the family members sent with a new client (`familyMembers`, a list of objects). As in Fineract, a
  member that leaves a value out inherits the one before it, and a birth date is read with the member's
  own `dateFormat`.
  """
  @spec add_all!(integer, [map]) :: :ok
  def add_all!(client_id, members) when is_list(members) do
    start = %{
      "firstName" => "",
      "middleName" => "",
      "lastName" => "",
      "qualification" => "",
      "mobileNumber" => "",
      "isDependent" => false
    }

    _last =
      Enum.reduce(members, start, fn member, state ->
        member = member |> then(&%Params{map: &1}) |> Params.check_supported!(@fields)

        state =
          Enum.reduce(member.map, state, fn {key, value}, acc ->
            put_member(acc, key, value, member)
          end)

        insert_member!(client_id, state)
        state
      end)

    :ok
  end

  # a value left out keeps what the member before it had; a birth date is read with the member's own
  # `dateFormat` and `locale`, and needs both
  defp put_member(state, "dateOfBirth", _value, member) do
    case Params.date(member, "dateOfBirth") do
      nil -> state
      date -> Map.put(state, "dateOfBirth", date)
    end
  end

  defp put_member(state, key, value, _member)
       when key in ~w(age relationshipId maritalStatusId genderId professionId) and value != nil,
       do: Map.put(state, key, to_long(value))

  defp put_member(state, key, value, _member)
       when key in ~w(firstName middleName lastName qualification mobileNumber) and value != nil,
       do: Map.put(state, key, to_string(value))

  defp put_member(state, "isDependent", value, _member) when value != nil,
    do: Map.put(state, "isDependent", value in [true, "true"])

  defp put_member(state, _key, _value, _member), do: state

  defp to_long(value) when is_integer(value), do: value

  defp to_long(value) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> raise ECBLedger.Errors.ServerError
    end
  end

  defp insert_member!(client_id, state) do
    TenantRepo.insert_all("m_family_members", [
      %{
        client_id: client_id,
        firstname: state["firstName"],
        middlename: state["middleName"],
        lastname: state["lastName"],
        qualification: state["qualification"],
        mobile_number: state["mobileNumber"],
        age: state["age"],
        is_dependent: state["isDependent"],
        relationship_cv_id: state["relationshipId"],
        marital_status_cv_id: state["maritalStatusId"],
        gender_cv_id: state["genderId"],
        profession_cv_id: state["professionId"],
        date_of_birth: state["dateOfBirth"]
      }
    ])
  end

  # --- update ---------------------------------------------------------------------------------

  @doc """
  Changes family member `id`. Fineract only changes what is named, but reads the marital status, gender and
  profession without checking they are there, so a request without all three fails (an HTTP 500).
  """
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = p) do
    p = Params.typed(p, @fields)
    typed!(p)
    ensure_exists!(id)

    for key <- ~w(maritalStatusId genderId professionId),
        Params.long(p, key) == nil,
        do: raise(ECBLedger.Errors.ServerError)

    set = changes(p)

    unless set == [] do
      guard(fn ->
        TenantRepo.update_all(from(f in "m_family_members", where: f.id == ^id), set: set)
      end)
    end

    Result.new(resource_id: id)
  end

  # a rule the database enforces (a required value missing, a code value that does not exist)
  defp guard(fun) do
    ECBPlatform.Integrity.translate(
      fun,
      %{},
      {"error.msg.data.integrity.issue",
       "The request caused a data integrity issue to be fired by the database."}
    )
  end

  # The record is first touched when its first field is set, and a missing one is a persistence error there
  defp ensure_exists!(id) do
    unless TenantRepo.exists?(from(f in "m_family_members", where: f.id == ^id)) do
      raise ECBPlatform.Errors.DataIntegrity,
        code: "error.msg.persistence.error",
        message: "Could not find Entity for id: #{id}",
        parameter: nil,
        args: []
    end
  end

  # Fineract reads an absent text as the empty text and stores it, so a change that leaves out a name
  # blanks it; the numbers, the flag and the date are only changed when they are sent
  defp changes(p) do
    texts =
      for {key, column} <- [
            {"firstName", :firstname},
            {"middleName", :middlename},
            {"lastName", :lastname},
            {"qualification", :qualification},
            {"mobileNumber", :mobile_number}
          ],
          do: {column, Params.command_string(p, key)}

    sent =
      [
        {"age", :age, &Params.long/2},
        {"isDependent", :is_dependent, &Params.boolean/2},
        {"relationshipId", :relationship_cv_id, &Params.long/2},
        {"maritalStatusId", :marital_status_cv_id, &Params.long/2},
        {"genderId", :gender_cv_id, &Params.long/2},
        {"professionId", :profession_cv_id, &Params.long/2},
        {"dateOfBirth", :date_of_birth, &Params.date/2}
      ]
      |> Enum.flat_map(fn {key, column, read} ->
        case read.(p, key) do
          nil -> []
          value -> [{column, value}]
        end
      end)

    texts ++ sent
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Deletes family member `id`."
  @spec delete!(integer) :: Result.t()
  def delete!(id) do
    # Fineract deletes without looking, so a family member that is not there is deleted all the same
    TenantRepo.delete_all(from(f in "m_family_members", where: f.id == ^id))
    Result.new(resource_id: id)
  end

  # --- shared ---------------------------------------------------------------------------------

  defp member(p) do
    %{
      firstname: Params.command_string(p, "firstName"),
      middlename: Params.command_string(p, "middleName"),
      lastname: Params.command_string(p, "lastName"),
      qualification: Params.command_string(p, "qualification"),
      mobile_number: Params.command_string(p, "mobileNumber"),
      age: Params.long(p, "age"),
      is_dependent: Params.boolean(p, "isDependent"),
      relationship_cv_id: Params.long(p, "relationshipId"),
      marital_status_cv_id: Params.long(p, "maritalStatusId"),
      gender_cv_id: Params.long(p, "genderId"),
      profession_cv_id: Params.long(p, "professionId"),
      date_of_birth: Params.date(p, "dateOfBirth")
    }
  end

  # Fineract's typed request refuses a number or flag that is not one.
  defp typed!(p) do
    for key <- ~w(age relationshipId maritalStatusId genderId professionId clientId id),
        do: Params.long(p, key)

    if Params.exists?(p, "isDependent"), do: Params.strict_boolean(p, "isDependent")
    :ok
  end
end
