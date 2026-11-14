defmodule ECBOrg.Staff.Write do
  @moduledoc """
  Creating and changing staff members (`m_staff`), following Fineract 1.16's staff service.

  Staff are one of the resources Fineract moved to typed requests checked by bean validation, so the
  validation errors read differently from the older resources: the message code is the name of the rule
  (`org.apache.fineract.organisation.staff.office-id.not-null`) and the parameter is the path of the
  field (`createStaff.request.officeId`).
  """
  import Ecto.Query

  alias ECBOrg.Staff
  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Errors
  alias ECBPlatform.Errors.PlatformApiDataValidation
  alias ECBPlatform.{Integrity, Params, TenantRepo}

  @prefix "org.apache.fineract.organisation.staff."
  @phone ~r/^\+?\d{7,15}$/

  @doc "Creates the staff member `params` describe."
  @spec create!(Params.t()) :: Result.t()
  def create!(%Params{} = params) do
    office_id = Params.long(params, "officeId")
    firstname = Params.string(params, "firstname")
    lastname = Params.string(params, "lastname")
    external_id = Params.string(params, "externalId")
    joining_date = Params.date(params, "joiningDate")

    violations =
      Enum.reject(
        [
          required("officeId", office_id, "office-id", "createStaff"),
          required("firstname", firstname, "firstname", "createStaff"),
          required("lastname", lastname, "lastname", "createStaff")
        ] ++ shape_violations(params, "createStaff"),
        &is_nil/1
      )

    unless violations == [], do: raise(PlatformApiDataValidation, errors: violations)

    office_name = office_name!(office_id)
    display_name = display_name(firstname, lastname)

    {1, [%{id: id}]} =
      guard(external_id, display_name, fn ->
        TenantRepo.insert_all(
          "m_staff",
          [
            %{
              office_id: office_id,
              firstname: firstname,
              lastname: lastname,
              display_name: display_name,
              external_id: external_id,
              mobile_no: Params.string(params, "mobileNo"),
              email_address: Params.string(params, "emailAddress"),
              is_loan_officer: Params.boolean(params, "isLoanOfficer") || false,
              is_active: Params.boolean(params, "isActive") != false,
              joining_date: joining_date
            }
          ],
          returning: [:id]
        )
      end)

    _ = office_name
    Result.new(resource_id: id, office_id: office_id)
  end

  @doc "Changes staff member `id`. Only values that are sent and not empty are applied."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    violations = Enum.reject(shape_violations(params, "updateStaff"), &is_nil/1)
    unless violations == [], do: raise(PlatformApiDataValidation, errors: violations)

    staff = Staff.fetch!(id)
    new_office_id = Params.long(params, "officeId")
    if new_office_id, do: office_name!(new_office_id)

    {changes, set} =
      Enum.reduce(fields(params, new_office_id, staff), {%{}, []}, fn
        {_key, _column, nil, _shown}, acc -> acc
        {key, column, value, shown}, {c, s} -> {Map.put(c, key, shown), [{column, value} | s]}
      end)

    unless changes == %{} do
      set = [
        {:display_name,
         display_name(value_of(set, :firstname, staff), value_of(set, :lastname, staff))}
        | set
      ]

      guard(Params.string(params, "externalId"), nil, fn ->
        TenantRepo.update_all(from(s in "m_staff", where: s.id == ^id), set: set)
      end)
    end

    office_id = new_office_id || staff.office_id

    Result.new(
      [resource_id: id, office_id: office_id] ++
        if(changes == %{}, do: [], else: [changes: changes])
    )
  end

  # {parameter, column, value to store, value to show}; a missing or empty value changes nothing
  defp fields(params, new_office_id, staff) do
    joining = Params.date(params, "joiningDate")

    [
      {"officeId", :office_id, new_office_id, new_office_id},
      {"firstname", :firstname, Params.string(params, "firstname"),
       Params.string(params, "firstname")},
      {"lastname", :lastname, Params.string(params, "lastname"),
       Params.string(params, "lastname")},
      {"externalId", :external_id, Params.string(params, "externalId"),
       Params.string(params, "externalId")},
      {"emailAddress", :email_address, Params.string(params, "emailAddress"),
       Params.string(params, "emailAddress")},
      {"mobileNo", :mobile_no, Params.string(params, "mobileNo"),
       Params.string(params, "mobileNo")},
      {"isLoanOfficer", :is_loan_officer, Params.boolean(params, "isLoanOfficer"),
       Params.boolean(params, "isLoanOfficer")},
      {"isActive", :is_active, Params.boolean(params, "isActive"),
       Params.boolean(params, "isActive")},
      {"joiningDate", :joining_date, if(joining != staff.joining_date, do: joining),
       Params.string(params, "joiningDate")}
    ]
  end

  defp value_of(set, column, staff), do: Keyword.get(set, column, Map.fetch!(staff, column))

  defp display_name(firstname, lastname) when firstname in [nil, ""], do: lastname
  defp display_name(firstname, lastname), do: "#{lastname}, #{firstname}"

  defp office_name!(office_id) do
    case TenantRepo.one(from o in "m_office", where: o.id == ^office_id, select: o.name) do
      nil ->
        raise Errors.ResourceNotFound,
          code: "error.msg.office.id.invalid",
          message: "Office with identifier #{office_id} does not exist",
          args: [office_id]

      name ->
        name
    end
  end

  # --- bean validation ------------------------------------------------------------------------

  defp required(_name, value, _rule, _request) when not is_nil(value), do: nil

  defp required(name, nil, rule, request),
    do:
      Errors.parameter_error(
        @prefix <> rule <> ".not-null",
        "The parameter '#{name}' is mandatory",
        "#{request}.request.#{name}"
      )

  # Length and format rules that apply to both create and update.
  defp shape_violations(params, request) do
    [
      max_length(params, "firstname", 50, request),
      max_length(params, "lastname", 50, request),
      max_length(params, "externalId", 100, request, "external-id"),
      max_length(params, "emailAddress", 254, request, "email", "email"),
      max_length(params, "mobileNo", 50, request, "mobile-no"),
      phone(params, request)
    ]
  end

  defp max_length(params, name, max, request, rule \\ nil, shown \\ nil) do
    value = Params.string(params, name)

    if value && String.length(value) > max,
      do:
        Errors.parameter_error(
          @prefix <> (rule || name) <> ".max",
          "The parameter '#{shown || name}' exceeds the maximum size of #{max} characters",
          "#{request}.request.#{name}"
        )
  end

  defp phone(params, request) do
    value = Params.string(params, "mobileNo")

    if value && not Regex.match?(@phone, value),
      do:
        Errors.parameter_error(
          @prefix <> "mobile-no.invalid",
          "The parameter 'mobileNo' must contain only digits with an optional leading '+' and be between 7 and 15 digits long",
          "#{request}.request.mobileNo"
        )
  end

  defp guard(external_id, display_name, fun) do
    Integrity.translate(
      fun,
      %{
        "m_staff_external_id_key" =>
          {"error.msg.staff.duplicate.externalId",
           "Staff with externalId `#{external_id}` already exists", "externalId", [external_id]},
        "m_staff_display_name_key" =>
          {"error.msg.staff.duplicate.displayName",
           "A staff with the given display name '#{display_name}' already exists", "displayName",
           [display_name]},
        "m_staff_mobile_no_key" =>
          {"error.msg.staff.duplicate.mobileNo", "A staff with that mobile number already exists",
           "mobileNo", []}
      },
      {"error.msg.staff.unknown.data.integrity.issue",
       "Unknown data integrity issue with resource."}
    )
  end
end
