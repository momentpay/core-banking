defmodule ECBLoans.Guarantors do
  @moduledoc """
  The guarantors of a loan (`m_guarantor`), following Fineract's `GuarantorsApiResource`, its command, services and
  entity. A guarantor is a customer of the bank (type 1), a member of staff (2), an external person (3) or a group
  (4, which is not built). A guarantor is never deleted, only made inactive; it can be added, changed or removed
  while the loan is awaiting approval or disbursal, or active.

  Guarantors that pledge a savings account (`savingsId`, with an `amount`) are refused: savings accounts are not
  built yet. What Fineract does that is kept so clients behave alike:

    * a customer or a member of staff can have only their relationship to the borrower changed (a change of the
      person or of the type is accepted and ignored); an external person can have the other details changed
    * an update must say the type of the guarantor, or Fineract fails (HTTP 500), and does so too when another
      guarantor of the loan is an external person while the update is for a customer, staff or group
    * the relationship asked for in an update always counts as a change
  """
  import Ecto.Query

  alias ECBLoans.Loans
  alias ECBParty.{Clients, Lookups}
  alias ECBPlatform.Commands.Result

  alias ECBPlatform.Errors.{
    DataIntegrity,
    DomainRuleViolation,
    PlatformApiDataValidation,
    ResourceNotFound,
    ServerError
  }

  alias ECBPlatform.{Json, Params, TenantRepo, Validation}

  @customer 1
  @staff 2
  @external 3
  @group 4
  @relationship_code "GuarantorRelationship"
  @open_loans [100, 200, 300]

  @types %{
    @customer => {"guarantor.existing.customer", "CUSTOMER"},
    @staff => {"guarantor.staff", "STAFF"},
    @external => {"guarantor.external", "EXTERNAL"},
    @group => {"guarantor.existing.group", "GROUP"}
  }

  # the longest each text can be in the table
  @column_sizes %{
    "firstname" => 50,
    "lastname" => 50,
    "addressLine1" => 500,
    "addressLine2" => 500,
    "city" => 50,
    "state" => 50,
    "country" => 50,
    "zip" => 20,
    "housePhoneNumber" => 20,
    "mobileNumber" => 20,
    "comment" => 500
  }

  # request name => column, in the order Fineract looks for changes
  @external_fields [
    {"firstname", :firstname},
    {"lastname", :lastname},
    {"dob", :dob},
    {"addressLine1", :address_line_1},
    {"addressLine2", :address_line_2},
    {"city", :city},
    {"state", :state},
    {"country", :country},
    {"zip", :zip},
    {"housePhoneNumber", :house_phone_number},
    {"mobileNumber", :mobile_number},
    {"comment", :comment}
  ]

  # --- reads --------------------------------------------------------------------------------------

  @doc "The types of guarantor, as Fineract's enumeration shows them."
  @spec type_option(integer) :: map
  def type_option(type) do
    {code, value} = Map.fetch!(@types, type)
    %{"id" => type, "code" => code, "value" => value}
  end

  @doc "All the types of guarantor."
  @spec type_options() :: [map]
  def type_options, do: Enum.map(1..4, &type_option/1)

  @doc "The guarantors of a loan, in order of id, with what is known of the customer or staff member each is."
  @spec list(integer) :: [map]
  def list(loan_id) do
    loan_id |> rows() |> Enum.map(&merge/1)
  end

  @doc "One guarantor of a loan, or `nil`."
  @spec get(integer, integer) :: map | nil
  def get(loan_id, id) do
    loan_id |> rows() |> Enum.find(&(&1.id == id)) |> then(&(&1 && merge(&1)))
  end

  @doc "How many guarantors (of any status) the loan has."
  @spec count(integer) :: non_neg_integer
  def count(loan_id),
    do: TenantRepo.aggregate(from(g in "m_guarantor", where: g.loan_id == ^loan_id), :count)

  defp rows(loan_id) do
    from(g in "m_guarantor",
      left_join: cv in "m_code_value",
      on: cv.id == g.client_reln_cv_id,
      where: g.loan_id == ^loan_id,
      order_by: g.id,
      select: %{
        id: g.id,
        loan_id: g.loan_id,
        relationship_id: g.client_reln_cv_id,
        relationship_name: cv.code_value,
        type: g.type_enum,
        entity_id: g.entity_id,
        firstname: g.firstname,
        lastname: g.lastname,
        dob: g.dob,
        address_line_1: g.address_line_1,
        address_line_2: g.address_line_2,
        city: g.city,
        state: g.state,
        country: g.country,
        zip: g.zip,
        house_phone_number: g.house_phone_number,
        mobile_number: g.mobile_number,
        comment: g.comment,
        active: g.is_active
      }
    )
    |> TenantRepo.all()
  end

  # a customer or a member of staff shows their own name, office and (a customer) day of joining
  defp merge(%{type: @customer, entity_id: entity} = g) when not is_nil(entity) do
    case TenantRepo.query!(
           """
           SELECT c.firstname, c.lastname, o.name, c.activation_date, c.external_id
           FROM m_client c JOIN m_office o ON o.id = c.office_id WHERE c.id = $1
           """,
           [entity]
         ).rows do
      [[first, last, office, joined, external_id]] ->
        %{g | firstname: first, lastname: last, dob: nil}
        |> Map.merge(%{office_name: office, joined_date: joined, external_id: external_id})
        |> clear_external_details()

      [] ->
        g
    end
  end

  defp merge(%{type: @staff, entity_id: entity} = g) when not is_nil(entity) do
    case TenantRepo.query!(
           """
           SELECT s.firstname, s.lastname, o.name
           FROM m_staff s JOIN m_office o ON o.id = s.office_id WHERE s.id = $1
           """,
           [entity]
         ).rows do
      [[first, last, office]] ->
        %{g | firstname: first, lastname: last, dob: nil}
        |> Map.merge(%{office_name: office})
        |> clear_external_details()

      [] ->
        g
    end
  end

  defp merge(g), do: g

  defp clear_external_details(g) do
    Map.merge(g, %{
      address_line_1: nil,
      address_line_2: nil,
      city: nil,
      state: nil,
      country: nil,
      zip: nil,
      house_phone_number: nil,
      mobile_number: nil,
      comment: nil
    })
  end

  @doc "The error for a guarantor that is not there for the loan."
  @spec not_found(integer, integer, integer | nil) :: Exception.t()
  def not_found(loan_id, id, funding_id \\ nil) do
    detail = if funding_id == nil, do: "null", else: to_string(funding_id)

    ResourceNotFound.new(
      "error.msg.loan.guarantor.not.found",
      "Guarantor with identifier #{id}and with funding detail #{detail} does not exist for loan with Identifier #{loan_id}",
      [loan_id, id, funding_id]
    )
  end

  defp not_found_for_update(loan_id, id) do
    ResourceNotFound.new(
      "error.msg.loan.guarantor.not.found",
      "Guarantor with identifier #{id} does not exist for loan with Identifier #{loan_id}",
      [loan_id, id]
    )
  end

  # --- adding -------------------------------------------------------------------------------------

  @doc "Adds a guarantor to loan `loan_id`."
  @spec create!(struct, integer, Params.t()) :: Result.t()
  def create!(_user, loan_id, %Params{} = p) do
    cmd = command(p)
    loan = Loans.fetch!(loan_id)
    validate_create!(cmd)
    check_open!(loan)
    refuse_savings!(cmd)
    relationship = cmd.relationship && Lookups.code_value!(@relationship_code, cmd.relationship)
    check_not_a_duplicate!(loan, cmd)
    check_business_rules!(loan, cmd)

    external? = cmd.type == @external

    row =
      %{
        loan_id: loan.id,
        client_reln_cv_id: relationship && relationship.id,
        type_enum: cmd.type,
        entity_id: if(external?, do: nil, else: cmd.entity_id),
        is_active: true
      }
      |> Map.merge(if external?, do: external_columns(cmd), else: %{})

    {1, [%{id: id}]} = TenantRepo.insert_all("m_guarantor", [row], returning: [:id])
    Result.new(office_id: loan.client_office_id, loan_id: loan.id, resource_id: id)
  end

  defp external_columns(cmd) do
    %{
      firstname: blank_to_nil(cmd.firstname),
      lastname: blank_to_nil(cmd.lastname),
      dob: cmd.dob,
      address_line_1: blank_to_nil(cmd.address_line_1),
      address_line_2: blank_to_nil(cmd.address_line_2),
      city: blank_to_nil(cmd.city),
      state: blank_to_nil(cmd.state),
      country: blank_to_nil(cmd.country),
      zip: blank_to_nil(cmd.zip),
      house_phone_number: blank_to_nil(cmd.house_phone_number),
      mobile_number: blank_to_nil(cmd.mobile_number),
      comment: blank_to_nil(cmd.comment)
    }
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # what the request says (a text that is blank is not there)
  defp command(%Params{} = p) do
    %{
      relationship: Json.long(p, "clientRelationshipTypeId"),
      type: Json.long(p, "guarantorTypeId"),
      entity_id: Json.long(p, "entityId"),
      firstname: text(p, "firstname"),
      lastname: text(p, "lastname"),
      address_line_1: text(p, "addressLine1"),
      address_line_2: text(p, "addressLine2"),
      city: text(p, "city"),
      state: text(p, "state"),
      zip: text(p, "zip"),
      country: text(p, "country"),
      mobile_number: text(p, "mobileNumber"),
      house_phone_number: text(p, "housePhoneNumber"),
      comment: text(p, "comment"),
      dob: Params.date(p, "dob"),
      savings_id: Json.long(p, "savingsId")
    }
  end

  defp text(p, key) do
    case Params.string(p, key) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: value
    end
  end

  defp validate_create!(cmd) do
    Validation.new("Guarantor")
    |> Validation.param("clientRelationshipTypeId", cmd.relationship)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("guarantorTypeId", cmd.type)
    |> Validation.not_null()
    |> Validation.in_range(1, 4)
    |> person_or_details(cmd, true)
    |> Validation.raise_if_errors!()
  end

  # a customer, member of staff or group is named by its id; an external person is described
  defp person_or_details(v, %{type: type} = cmd, create?) when type != @external do
    v
    |> Validation.param("entityId", cmd.entity_id)
    |> then(&if(create?, do: Validation.not_null(&1), else: Validation.ignore_if_null(&1)))
    |> Validation.greater_than_zero()
    |> Validation.param("savingsId", cmd.savings_id)
    |> Validation.greater_than_zero()
  end

  defp person_or_details(v, cmd, create?) do
    v
    |> Validation.param("firstname", cmd.firstname)
    |> name(create?)
    |> Validation.param("lastname", cmd.lastname)
    |> name(create?)
    |> optional_details(cmd)
  end

  defp name(v, true), do: v |> Validation.not_blank() |> Validation.max_length(50)
  defp name(v, false), do: v |> Validation.ignore_if_null() |> Validation.max_length(50)

  defp optional_details(v, cmd) do
    for {param, value, max} <- [
          {"addressLine1", cmd.address_line_1, 500},
          {"addressLine2", cmd.address_line_2, 500},
          {"city", cmd.city, 50},
          {"state", cmd.state, 50},
          {"zip", cmd.zip, 50},
          {"country", cmd.country, 50}
        ],
        reduce: v do
      v -> v |> Validation.param(param, value) |> Validation.max_length(max)
    end
    |> phone("mobileNumber", cmd.mobile_number)
    |> phone("housePhoneNumber", cmd.house_phone_number)
    |> Validation.param("comment", cmd.comment)
    |> Validation.max_length(500)
  end

  defp phone(v, param, value) do
    v = v |> Validation.param(param, value) |> Validation.max_length(20)

    if value != nil and not Regex.match?(~r/^\+?[0-9. ()-]{0,25}$/, value) do
      Validation.add_error(
        v,
        "validation.msg.Guarantor.#{param}.format.is.invalid",
        "The parameter `#{param}` is in invalid format, should contain '-','+','()' and numbers only.",
        param,
        [value]
      )
    else
      v
    end
  end

  defp check_open!(%{loan_status_id: status}) when status in @open_loans, do: :ok

  defp check_open!(_loan) do
    raise PlatformApiDataValidation,
      errors: [
        %{
          code: "validation.msg.loan.guarantor.loan.is.closed",
          developer_message: "Failed data validation due to: loan.is.closed.",
          default_message: "Failed data validation due to: loan.is.closed.",
          parameter: nil,
          args: [nil, []]
        }
      ]
  end

  defp refuse_savings!(%{savings_id: nil}), do: :ok

  defp refuse_savings!(_cmd) do
    raise DomainRuleViolation,
      code: "error.msg.loan.feature.not.supported.yet",
      message: "A guarantor that pledges a savings account is not supported yet by E-CoreBank",
      args: ["savingsId"]
  end

  # the same person already guarantees the loan
  defp check_not_a_duplicate!(loan, cmd) do
    if cmd.entity_id != nil and
         Enum.any?(rows(loan.id), &(&1.active and same_person?(&1, cmd.entity_id, cmd.type, nil))) do
      duplicate!(loan, cmd.type, cmd.entity_id)
    end
  end

  defp same_person?(g, entity_id, type, except_id) do
    g.entity_id != nil and g.entity_id == entity_id and g.type == type and g.id != except_id
  end

  defp duplicate!(loan, type, entity_id) do
    name =
      case type do
        @staff -> staff!(entity_id).display_name
        @group -> group_not_found!(entity_id)
        _ -> Clients.fetch!(entity_id).display_name
      end

    raise DomainRuleViolation,
      code: "error.msg.client.guarantor.is.already.exist.same.loan",
      message: "#{name} already exists as a guarantor for this loan",
      args: [entity_id, loan.id]
  end

  defp check_business_rules!(loan, %{type: @customer, entity_id: entity_id}) do
    Clients.fetch!(entity_id)

    if entity_id == loan.client_id do
      raise DomainRuleViolation,
        code: "error.msg.guarantor.can.not.be.own",
        message:
          "Tried to set Client with id #{entity_id} as a guarantor to his/her own loan with loan identifier =#{loan.id}",
        args: [entity_id, loan.id]
    end
  end

  defp check_business_rules!(_loan, %{type: @staff, entity_id: entity_id}), do: staff!(entity_id)

  defp check_business_rules!(_loan, %{type: @group, entity_id: entity_id}),
    do: group_not_found!(entity_id)

  defp check_business_rules!(_loan, _cmd), do: :ok

  defp staff!(id) do
    case TenantRepo.one(
           from(s in "m_staff", where: s.id == ^id, select: %{display_name: s.display_name})
         ) do
      nil ->
        raise ResourceNotFound.new(
                "error.msg.staff.id.invalid",
                "Staff with identifier #{id} does not exist",
                [id]
              )

      staff ->
        staff
    end
  end

  # groups are not built, so there is none
  defp group_not_found!(id) do
    raise ResourceNotFound.new(
            "error.msg.group.id.invalid",
            "Group with identifier #{id} does not exist",
            [id]
          )
  end

  # --- changing -----------------------------------------------------------------------------------

  @doc "Changes a guarantor."
  @spec update!(struct, integer, integer, Params.t()) :: Result.t()
  def update!(_user, loan_id, id, %Params{} = p) do
    cmd = command(p)
    validate_update!(cmd)
    loan = Loans.fetch!(loan_id)
    check_open!(loan)

    guarantor =
      loan.id |> rows() |> Enum.find(&(&1.id == id)) || raise not_found_for_update(loan.id, id)

    changes = changes(guarantor, p, cmd)
    check_sizes!(changes)
    relationship = relationship_change(changes)
    if relationship, do: Lookups.code_value!(@relationship_code, relationship)

    check_type_and_others!(loan, guarantor, cmd)
    save!(id, changes, relationship)

    # Fineract shows the loan's id where the office's belongs
    Result.new(office_id: loan.id, resource_id: id, changes: if(changes != %{}, do: changes))
  end

  defp validate_update!(cmd) do
    Validation.new("Guarantor")
    |> Validation.param("clientRelationshipTypeId", cmd.relationship)
    |> Validation.ignore_if_null()
    |> Validation.greater_than_zero()
    |> Validation.param("guarantorTypeId", cmd.type)
    |> Validation.ignore_if_null()
    |> Validation.in_range(1, 4)
    |> person_or_details(cmd, false)
    |> any_of_not_null(cmd)
    |> Validation.raise_if_errors!()
  end

  defp any_of_not_null(v, cmd) do
    given =
      [
        cmd.entity_id,
        cmd.address_line_1,
        cmd.address_line_2,
        cmd.city,
        cmd.comment,
        cmd.country,
        cmd.firstname,
        cmd.house_phone_number,
        cmd.lastname,
        cmd.mobile_number,
        cmd.state,
        cmd.zip
      ]
      |> Enum.any?(&(&1 != nil))

    if given, do: v, else: Validation.no_parameters_for_update(v)
  end

  # what changes: the relationship (always, when given and not 0) and, for an external person, the details
  defp changes(guarantor, p, cmd) do
    base = relationship_asked(cmd.relationship)

    if guarantor.type == @external do
      Enum.reduce(@external_fields, base, fn {param, column}, acc ->
        external_change(acc, p, guarantor, param, column)
      end)
    else
      base
    end
  end

  defp relationship_asked(relationship) when relationship in [nil, 0], do: %{}
  defp relationship_asked(relationship), do: %{"clientRelationshipTypeId" => relationship}

  defp external_change(acc, p, guarantor, "dob", column) do
    case Params.date(p, "dob") do
      nil -> acc
      date -> if date == Map.fetch!(guarantor, column), do: acc, else: Map.put(acc, "dob", date)
    end
  end

  defp external_change(acc, p, guarantor, param, column) do
    case Params.value(p, param) do
      value when is_binary(value) ->
        new = String.trim(value)
        old = Map.fetch!(guarantor, column) || ""
        if new == old, do: acc, else: Map.put(acc, param, new)

      _ ->
        acc
    end
  end

  defp relationship_change(changes), do: changes["clientRelationshipTypeId"]

  # a text longer than its column is a refusal of the database
  defp check_sizes!(changes) do
    Enum.each(changes, fn {param, value} ->
      size = Map.get(@column_sizes, param)

      if size != nil and is_binary(value) and String.length(value) > size do
        raise DataIntegrity,
          code: "error.msg.guarantor.unknown.data.integrity.issue",
          message:
            "Unknown data integrity issue with resource Guarantor: ERROR: value too long for type character varying(#{size})",
          args: []
      end
    end)
  end

  # Fineract has to know the type the request gives, and walks the guarantors of the loan for a customer, a member
  # of staff or a group: an external person among them (who has no entity) fails it
  defp check_type_and_others!(loan, guarantor, cmd) do
    cond do
      cmd.type == nil ->
        raise ServerError

      cmd.type in [@customer, @staff, @group] ->
        Enum.each(rows(loan.id), &check_other!(&1, loan, guarantor, cmd))

      true ->
        :ok
    end
  end

  defp check_other!(other, loan, guarantor, cmd) do
    if other.entity_id == nil, do: raise(ServerError)

    if same_person?(other, cmd.entity_id, cmd.type, guarantor.id),
      do: duplicate!(loan, cmd.type, cmd.entity_id)

    :ok
  end

  defp save!(_id, changes, _relationship) when changes == %{}, do: :ok

  defp save!(id, changes, relationship) do
    set =
      for {param, column} <- @external_fields,
          Map.has_key?(changes, param),
          do: {column, store(Map.fetch!(changes, param))}

    set = if relationship, do: [{:client_reln_cv_id, relationship} | set], else: set

    if set != [],
      do: TenantRepo.update_all(from(g in "m_guarantor", where: g.id == ^id), set: set)

    :ok
  end

  defp store(%Date{} = date), do: date
  defp store(value), do: value

  # --- removing -----------------------------------------------------------------------------------

  @doc "Makes a guarantor inactive."
  @spec delete!(struct, integer, integer, integer | nil) :: Result.t()
  def delete!(_user, loan_id, id, funding_id) do
    loan = Loans.fetch!(loan_id)
    check_open!(loan)
    guarantor = loan.id |> rows() |> Enum.find(&(&1.id == id))

    # a guarantor that pledges a savings account has funding details; none can exist here
    if guarantor == nil or funding_id != nil, do: raise(not_found(loan.id, id, funding_id))

    unless guarantor.active do
      raise PlatformApiDataValidation,
        errors: [
          %{
            code: "validation.msg.Guarantor.not.active",
            developer_message: "Failed data validation due to: not.active.",
            default_message: "Failed data validation due to: not.active.",
            parameter: nil,
            args: [nil, []]
          }
        ]
    end

    TenantRepo.update_all(from(g in "m_guarantor", where: g.id == ^id), set: [is_active: false])
    Result.new(office_id: loan.client_office_id, loan_id: loan.id, resource_id: id)
  end
end
