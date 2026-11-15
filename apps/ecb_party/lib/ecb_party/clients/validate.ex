defmodule ECBParty.Clients.Validate do
  @moduledoc """
  What a request to create, change or move a client through its life must carry, following Fineract's
  `ClientDataValidator`. Every check runs and the problems come back together; the exceptions are the
  values that cannot be read at all (a date with no `dateFormat`, a number that is not one), which stop
  the request where they are, as Fineract does.
  """
  alias ECBPlatform.{BusinessDate, Params, Validation}
  alias ECBPlatform.Errors.PlatformApiDataValidation

  @create_supported ~w(familyMembers address locale dateFormat groupId accountNo externalId mobileNo
                       emailAddress firstname middlename lastname fullname officeId active activationDate
                       staffId submittedOnDate savingsProductId dateOfBirth genderId clientTypeId
                       clientClassificationId clientNonPersonDetails displayname legalFormId datatables
                       isStaff)
  @non_person_create_supported ~w(familyMembers address locale dateFormat incorpNumber remarks
                                  incorpValidityTillDate constitutionId mainBusinessLineId datatables)
  @update_supported ~w(locale dateFormat accountNo externalId mobileNo emailAddress firstname middlename
                       lastname fullname active activationDate staffId savingsProductId dateOfBirth
                       genderId clientTypeId clientClassificationId submittedOnDate
                       clientNonPersonDetails displayname legalFormId isStaff)
  @non_person_update_supported ~w(locale dateFormat incorpNumber remarks incorpValidityTillDate
                                  constitutionId mainBusinessLineId)

  # Fineract's default phone-number rule.
  @mobile_pattern "^\\+?[0-9]{7,15}$"

  @doc "The parameters a create request may carry."
  def create_supported, do: @create_supported

  @doc "The parameters the details of an entity client may carry on create."
  def non_person_create_supported, do: @non_person_create_supported

  @doc "The parameters an update request may carry."
  def update_supported, do: @update_supported

  @doc "The parameters the details of an entity client may carry on update."
  def non_person_update_supported, do: @non_person_update_supported

  # --- create ---------------------------------------------------------------------------------

  @doc """
  Checks a create request. `non_person` is the entity details as a `Params` (or `nil`). `address_on?`
  says whether the tenant keeps addresses.
  """
  @spec create!(Params.t(), Params.t() | nil, boolean) :: :ok
  def create!(%Params{} = p, non_person, address_on?) do
    v =
      Validation.new("client")
      |> Validation.param("officeId", ECBPlatform.Json.long(p, "officeId"))
      |> Validation.not_null()
      |> Validation.greater_than_zero()
      |> optional_positive(p, "groupId", :not_null)
      |> optional_positive(p, "staffId", :ignore_null)
      |> account_no(p)
      |> optional_positive(p, "savingsProductId", :ignore_null)
      |> create_names(p)
      |> external_id(p, :ignore_null)
      |> mobile_no(p)
      |> active_and_dates(p)

    v
    |> optional_integer(p, "genderId")
    |> optional_integer(p, "clientTypeId")
    |> optional_integer(p, "clientClassificationId")
    |> date_format(p)
    |> legal_form(p, :required)
    |> staff_flag(p)
    |> address_list(p, address_on?)
    |> date_format_when_present(p)
    |> non_person_create(non_person)
    |> Validation.raise_if_errors!()
  end

  defp account_no(v, p) do
    if Params.exists?(p, "accountNo") do
      v
      |> Validation.param("accountNo", Params.string(p, "accountNo"))
      |> Validation.not_blank()
      |> Validation.max_length(20)
    else
      v
    end
  end

  defp external_id(v, p, mode) do
    if Params.exists?(p, "externalId") do
      v = Validation.param(v, "externalId", Params.string(p, "externalId"))
      v = if mode == :ignore_null, do: Validation.ignore_if_null(v), else: v
      Validation.max_length(v, 100)
    else
      v
    end
  end

  defp mobile_no(v, p) do
    if Params.exists?(p, "mobileNo") do
      v
      |> Validation.param("mobileNo", Params.string(p, "mobileNo"))
      |> Validation.ignore_if_null()
      |> Validation.matches(@mobile_pattern)
      |> Validation.max_length(50)
    else
      v
    end
  end

  defp optional_positive(v, p, key, mode) do
    if Params.exists?(p, key) do
      v = Validation.param(v, key, ECBPlatform.Json.long(p, key))
      v = if mode == :ignore_null, do: Validation.ignore_if_null(v), else: Validation.not_null(v)
      Validation.greater_than_zero(v)
    else
      v
    end
  end

  defp optional_integer(v, p, key) do
    if Params.exists?(p, key) do
      v
      |> Validation.param(key, Params.integer(p, key))
      |> Validation.greater_than_zero()
    else
      v
    end
  end

  # active -> activation date; the submitted and birth dates
  defp active_and_dates(v, p) do
    active = Params.boolean(p, "active")

    v =
      if active == true do
        v
        |> Validation.param("activationDate", Params.date(p, "activationDate"))
        |> Validation.not_null()
      else
        v
      end

    submitted =
      if Params.exists?(p, "submittedOnDate"), do: Params.date(p, "submittedOnDate")

    v =
      if Params.exists?(p, "submittedOnDate"),
        do: v |> Validation.param("submittedOnDate", submitted) |> Validation.not_null(),
        else: v

    birth_date(v, p, submitted)
  end

  defp birth_date(v, p, submitted) do
    if Params.exists?(p, "dateOfBirth") do
      v
      |> Validation.param("dateOfBirth", Params.date(p, "dateOfBirth"))
      |> Validation.not_null()
      |> Validation.date_before(BusinessDate.current())
      |> Validation.date_before(submitted)
    else
      v
    end
  end

  defp date_format(v, p) do
    if Params.exists?(p, "dateFormat") do
      v
      |> Validation.param("dateFormat", Params.string(p, "dateFormat"))
      |> Validation.not_blank()
      |> Validation.valid_date_time_pattern()
    else
      v
    end
  end

  defp legal_form(v, p, mode) do
    if mode == :required or Params.exists?(p, "legalFormId") do
      v
      |> Validation.param("legalFormId", Params.integer(p, "legalFormId"))
      |> Validation.not_null()
      |> Validation.in_range(1, 2)
    else
      v
    end
  end

  defp staff_flag(v, p) do
    if Params.exists?(p, "isStaff") do
      v |> Validation.param("isStaff", Params.boolean(p, "isStaff")) |> Validation.not_null()
    else
      v
    end
  end

  defp address_list(v, p, true) do
    value = Params.value(p, "address")

    v
    |> Validation.param("address", value)
    |> Validation.ignore_if_null()
    |> Validation.array_not_empty()
  end

  defp address_list(v, _p, false), do: v

  defp date_format_when_present(v, p) do
    format = Params.string(p, "dateFormat")

    if Params.exists?(p, "dateFormat") and format != nil and
         not ECBPlatform.Params.DatePattern.valid?(format) do
      Validation.add_error(
        v,
        "validation.msg.invalid.dateFormat.format",
        "Invalid dateFormat: `#{format}`. Use a valid Java date/time pattern (e.g. dd MMMM yyyy).",
        "dateFormat",
        []
      )
    else
      v
    end
  end

  # --- names ----------------------------------------------------------------------------------

  defp create_names(v, p) do
    cond do
      fullname_provided?(p) or individual_provided?(p) ->
        provided_names(v, p)

      fullname_passed?(p) or individual_passed?(p) ->
        passed_names(v, p)

      true ->
        v |> Validation.param("id", nil) |> Validation.fail_with_code(".no.name.details.passed")
    end
  end

  defp update_names(v, p) do
    cond do
      fullname_provided?(p) or individual_provided?(p) -> provided_names(v, p)
      fullname_passed?(p) or individual_passed?(p) -> passed_names(v, p)
      true -> v
    end
  end

  defp provided_names(v, p) do
    full? = fullname_provided?(p)
    individual? = individual_provided?(p)

    cond do
      full? and not individual? -> fullname_not_blank(v, p)
      individual? and not full? -> required_parts(v, p)
      true -> parts_with_fullname(v, p)
    end
  end

  defp passed_names(v, p) do
    full? = fullname_passed?(p)
    individual? = individual_passed?(p)

    cond do
      full? and not individual? ->
        fullname_not_blank(v, p)

      individual? and not full? ->
        required_parts(v, p)

      true ->
        v |> Validation.param("id", nil) |> Validation.fail_with_code(".no.name.details.passed")
    end
  end

  defp fullname_not_blank(v, p) do
    v
    |> Validation.param("fullname", Params.string(p, "fullname"))
    |> Validation.not_blank()
    |> Validation.max_length(160)
  end

  defp required_parts(v, p) do
    v
    |> Validation.param("firstname", Params.string(p, "firstname"))
    |> Validation.not_blank()
    |> Validation.max_length(50)
    |> Validation.param("middlename", Params.string(p, "middlename"))
    |> Validation.ignore_if_null()
    |> Validation.max_length(50)
    |> Validation.param("lastname", Params.string(p, "lastname"))
    |> Validation.not_blank()
    |> Validation.max_length(50)
  end

  defp parts_with_fullname(v, p) do
    Enum.reduce(~w(firstname middlename lastname), v, fn part, v ->
      value = Params.string(p, part)

      if value do
        v
        |> Validation.param("fullname", Params.string(p, "fullname"))
        |> Validation.blank_when_populated(part, value)
      else
        v
      end
    end)
  end

  defp fullname_provided?(p), do: Params.string(p, "fullname") != nil

  defp individual_provided?(p),
    do: Enum.any?(~w(firstname middlename lastname), &(Params.string(p, &1) != nil))

  defp fullname_passed?(p), do: Params.exists?(p, "fullname")

  defp individual_passed?(p),
    do: Enum.any?(~w(firstname middlename lastname), &Params.exists?(p, &1))

  # --- entity details -------------------------------------------------------------------------

  defp non_person_create(v, nil), do: v

  defp non_person_create(v, np) do
    v
    |> text_if_present(np, "incorpNumber", 50, :ignore_null)
    |> text_if_present(np, "remarks", 150, :ignore_null)
    |> incorp_validity(np)
    |> id_if_present(np, "constitutionId", true)
    |> id_if_present(np, "mainBusinessLineId", false)
  end

  defp text_if_present(v, np, key, max, mode) do
    if Params.exists?(np, key) do
      v = Validation.param(v, key, Params.string(np, key))
      v = if mode == :ignore_null, do: Validation.ignore_if_null(v), else: v
      Validation.max_length(v, max)
    else
      v
    end
  end

  defp incorp_validity(v, np) do
    if Params.exists?(np, "incorpValidityTillDate") do
      v
      |> Validation.param("incorpValidityTillDate", Params.date(np, "incorpValidityTillDate"))
      |> Validation.ignore_if_null()
    else
      v
    end
  end

  defp id_if_present(v, np, key, not_blank?) do
    if Params.exists?(np, key) do
      v = v |> Validation.param(key, Params.integer(np, key)) |> Validation.greater_than_zero()
      if not_blank?, do: Validation.not_blank(v), else: v
    else
      v
    end
  end

  # --- update ---------------------------------------------------------------------------------

  @doc "Checks an update request; `non_person` is the entity details as a `Params` or `nil`."
  @spec update!(Params.t(), Params.t() | nil) :: :ok
  def update!(%Params{} = p, non_person) do
    v = Validation.new("client") |> account_no(p) |> update_names(p)
    passed? = Params.exists?(p, "accountNo")

    {v, passed?} =
      Enum.reduce(~w(fullname lastname middlename firstname), {v, passed?}, fn key,
                                                                               {v, passed?} ->
        {v, passed? or Params.exists?(p, key)}
      end)

    {v, passed?} = update_more_fields(v, p, passed?)
    {v, np_passed?} = non_person_update(v, non_person)

    v = if passed? or np_passed?, do: v, else: Validation.no_parameters_for_update(v)

    Validation.raise_if_errors!(v)
  end

  defp update_more_fields(v, p, passed?) do
    {v, passed?} =
      if Params.exists?(p, "externalId"),
        do: {external_id(v, p, :plain), true},
        else: {v, passed?}

    {v, passed?} =
      if Params.exists?(p, "mobileNo"),
        do: {mobile_no(v, p), true},
        else: {v, passed?}

    active = Params.boolean(p, "active")

    {v, passed?} =
      cond do
        active == true ->
          {v
           |> Validation.param("activationDate", Params.date(p, "activationDate"))
           |> Validation.not_null(), true}

        active == false ->
          {v, true}

        true ->
          {v, passed?}
      end

    {v, passed?} = update_references(v, p, passed?)

    {v, passed?, submitted} = update_submitted(v, p, passed?)
    {v, passed?} = update_birth(v, p, passed?, submitted)

    v = date_format(v, p)

    {v, passed?} =
      if Params.exists?(p, "legalFormId"),
        do: {legal_form(v, p, :optional), true},
        else: {v, passed?}

    v = staff_flag(v, p)
    {date_format_when_present(v, p), passed?}
  end

  # the references to other records, each checked when it is sent
  @update_references [
    {"staffId", :long, :ignore_null},
    {"savingsProductId", :long, :ignore_null},
    {"genderId", :integer, nil},
    {"clientTypeId", :integer, nil},
    {"clientClassificationId", :integer, nil}
  ]

  defp update_references(v, p, passed?) do
    Enum.reduce(@update_references, {v, passed?}, fn ref, acc -> update_reference(acc, p, ref) end)
  end

  defp update_reference({v, passed?}, p, {key, kind, mode}) do
    cond do
      not Params.exists?(p, key) -> {v, passed?}
      kind == :long -> {optional_positive(v, p, key, mode), true}
      true -> {optional_integer(v, p, key), true}
    end
  end

  defp update_submitted(v, p, passed?) do
    if Params.exists?(p, "submittedOnDate") do
      submitted = Params.date(p, "submittedOnDate")

      {v |> Validation.param("submittedOnDate", submitted) |> Validation.not_null(), true,
       submitted}
    else
      {v, passed?, nil}
    end
  end

  defp update_birth(v, p, passed?, submitted) do
    if Params.exists?(p, "dateOfBirth") do
      {birth_date(v, p, submitted), true}
    else
      {v, passed?}
    end
  end

  defp non_person_update(v, nil), do: {v, false}

  defp non_person_update(v, np) do
    keys = ~w(incorpNumber remarks incorpValidityTillDate constitutionId mainBusinessLineId)
    passed? = Enum.any?(keys, &Params.exists?(np, &1))

    v =
      v
      |> text_if_present(np, "incorpNumber", 50, :ignore_null)
      |> text_if_present(np, "remarks", 150, :plain)
      |> update_incorp_validity(np)
      |> id_if_present(np, "constitutionId", true)
      |> id_if_present(np, "mainBusinessLineId", false)

    {v, passed?}
  end

  defp update_incorp_validity(v, np) do
    if Params.exists?(np, "incorpValidityTillDate"),
      do:
        Validation.param(v, "incorpValidityTillDate", Params.date(np, "incorpValidityTillDate")),
      else: v
  end

  # --- commands -------------------------------------------------------------------------------

  @doc """
  Checks the body of a lifecycle command. `spec` lists, in order, the date parameter and the id
  parameter (or `nil`) it needs; `supported` the parameters it may carry. `limit` makes the date at
  most today (undo of a rejection or a withdrawal).
  """
  @spec command!(Params.t(), [String.t()], keyword) :: %{atom => term}
  def command!(%Params{} = p, supported, opts) do
    Params.check_supported!(p, supported)
    date_key = Keyword.fetch!(opts, :date)
    date = Params.date(p, date_key)

    v = Validation.new("client") |> Validation.param(date_key, date) |> Validation.not_null()

    v =
      if opts[:limit_today],
        do: Validation.date_before_or_equal(v, BusinessDate.current()),
        else: v

    {v, id} =
      case opts[:id] do
        nil ->
          {v, nil}

        id_key ->
          id = ECBPlatform.Json.long(p, id_key)

          {v
           |> Validation.param(id_key, id)
           |> Validation.not_null()
           |> Validation.greater_than_zero(), id}
      end

    Validation.raise_if_errors!(v)
    %{date: date, id: id}
  end

  @doc "Checks the body of a staff assignment (`staffId` and nothing else); `resource` names the resource in codes."
  @spec staff_command!(Params.t(), String.t()) :: integer
  def staff_command!(%Params{} = p, resource) do
    Params.check_supported!(p, ["staffId"])
    staff_id = ECBPlatform.Json.long(p, "staffId")

    Validation.new(resource)
    |> Validation.param("staffId", staff_id)
    |> Validation.not_null()
    |> Validation.greater_than_zero()
    |> Validation.raise_if_errors!()

    staff_id
  end

  @doc "Raises the validation error `errors` (a list of already built problems)."
  def raise_errors!(errors), do: raise(PlatformApiDataValidation, errors: errors)
end
