defmodule ECBParty.Clients.Domain do
  @moduledoc """
  The rules of the `Client` entity that the write side shares: which dates a client may carry, what an
  update changes, how a display name is derived, and what must go when a client is deleted. Follows
  Fineract's `Client` and `ClientNonPerson` entities.
  """
  import Ecto.Query

  alias ECBParty.Clients
  alias ECBParty.Clients.Validate
  alias ECBParty.Json
  alias ECBParty.Lookups
  alias ECBPlatform.{BusinessDate, Params, TenantRepo}
  alias ECBPlatform.Errors.DomainRuleViolation
  alias ECBPlatform.Params.DatePattern

  @gender "Gender"
  @client_type "ClientType"
  @classification "ClientClassification"
  @constitution "Constitution"
  @main_business_line "Main Business Line"

  # --- dates ----------------------------------------------------------------------------------

  @doc """
  Checks the dates a client carries: the submission and activation dates against today, against each
  other and against the office's opening, and a reopening against the activation. `c` has `:office`,
  `:activation_date`, `:submitted_on` and `:reopened_on`.
  """
  @spec validate_activation!(map, Date.t()) :: :ok
  def validate_activation!(c, today) do
    today = today || BusinessDate.current()

    errors =
      [
        submitted_in_future(c, today),
        submitted_after_activation(c),
        reopened_after_activation(c),
        activation_in_future(c, today),
        activation_before_office(c)
      ]
      |> Enum.reject(&is_nil/1)

    if errors == [], do: :ok, else: Validate.raise_errors!(errors)
  end

  defp submitted_in_future(%{submitted_on: submitted}, today) do
    if submitted && later?(submitted, today),
      do:
        error(
          "error.msg.clients.submittedOnDate.in.the.future",
          "submitted date cannot be in the future.",
          "submittedOnDate",
          submitted
        )
  end

  defp submitted_after_activation(%{submitted_on: submitted, activation_date: activation}) do
    if activation && submitted && later?(submitted, activation),
      do:
        error(
          "error.msg.clients.submittedOnDate.after.activation.date",
          "submitted date cannot be after the activation date",
          "submittedOnDate",
          submitted
        )
  end

  defp reopened_after_activation(%{reopened_on: reopened, activation_date: activation}) do
    if activation && reopened && later?(reopened, activation),
      do:
        error(
          "error.msg.clients.submittedOnDate.after.reopened.date",
          "reopened date cannot be after the submittedon date",
          "reopenedDate",
          reopened
        )
  end

  defp activation_in_future(%{activation_date: activation}, today) do
    if activation && later?(activation, today),
      do:
        error(
          "error.msg.clients.activationDate.in.the.future",
          "Activation date cannot be in the future.",
          "activationDate",
          activation
        )
  end

  defp activation_before_office(%{activation_date: activation, office: office}) do
    if activation && office.opening_date && later?(office.opening_date, activation),
      do:
        error(
          "error.msg.clients.activationDate.cannot.be.before.office.activation.date",
          "Client activation date cannot be a date before the office opening date.",
          "activationDate",
          activation
        )
  end

  defp error(code, message, parameter, date),
    do: ECBPlatform.Errors.parameter_error(code, message, parameter, [Date.to_iso8601(date)])

  defp later?(a, b), do: Date.compare(a, b) == :gt

  @doc "A date written as the request's `dateFormat` writes it."
  @spec format_date(Params.t(), Date.t()) :: String.t()
  def format_date(p, date) do
    case Params.date_format(p) do
      nil -> Date.to_iso8601(date)
      pattern -> DatePattern.format(date, pattern) || Date.to_iso8601(date)
    end
  end

  # --- names ----------------------------------------------------------------------------------

  @doc "The name a client is known by: the full name, or for a person the name parts joined."
  @spec display_name(map) :: String.t()
  def display_name(client) do
    cond do
      present?(client.fullname) ->
        client.fullname

      client.legal_form_enum in [nil, 1] ->
        [client.firstname, client.middlename, client.lastname]
        |> Enum.filter(&present?/1)
        |> Enum.join(" ")

      true ->
        ""
    end
  end

  defp present?(text), do: is_binary(text) and String.trim(text) != ""

  # --- update ---------------------------------------------------------------------------------

  @text_fields [
    {"accountNo", :account_no, :account_no},
    {"externalId", :external_id, :external_id},
    {"mobileNo", :mobile_no, :mobile_no},
    {"emailAddress", :email_address, :email_address},
    {"firstname", :firstname, :firstname},
    {"middlename", :middlename, :middlename},
    {"lastname", :lastname, :lastname},
    {"fullname", :fullname, :fullname}
  ]

  @date_fields [
    {"activationDate", :activation_date, :activation_date},
    {"dateOfBirth", :date_of_birth, :date_of_birth},
    {"submittedOnDate", :submitted_on, :submittedon_date}
  ]

  @id_fields [
    {"staffId", :staff_id},
    {"genderId", :gender_id},
    {"savingsProductId", :savings_product_id},
    {"clientTypeId", :client_type_id},
    {"clientClassificationId", :classification_id}
  ]

  @doc """
  What a request changes in a client: `{changes, set}`. `changes` is the map the response shows, `set`
  the columns to store. The references to other records (`staffId`, `genderId`, ...) are only recorded
  as changes here; `resolve_references/5` checks them and stores them.
  """
  @spec changes(Params.t(), map) :: {map, keyword}
  def changes(p, client) do
    {%{}, []}
    |> text_changes(p, client)
    |> id_changes(p, client)
    |> legal_form_change(p, client)
    |> date_changes(p, client)
  end

  defp text_changes(acc, p, client) do
    Enum.reduce(@text_fields, acc, fn field, acc -> text_change(acc, p, client, field) end)
  end

  defp text_change({changes, set} = acc, p, client, {key, field, column}) do
    if Params.changed_string?(p, key, Map.get(client, field)) do
      value = Params.command_string(p, key)
      stored = if value == "" and key != "fullname", do: nil, else: value
      # an external id that is cleared is shown as no value at all
      shown = if key == "externalId" and value == "", do: nil, else: value
      {Map.put(changes, key, shown), set ++ [{column, stored}]}
    else
      acc
    end
  end

  defp id_changes(acc, p, client) do
    Enum.reduce(@id_fields, acc, fn field, acc -> id_change(acc, p, client, field) end)
  end

  defp id_change({changes, set} = acc, p, client, {key, field}) do
    if Params.changed_long?(p, key, Map.get(client, field)),
      do: {Map.put(changes, key, Json.long(p, key)), set},
      else: acc
  end

  defp legal_form_change({changes, set} = acc, p, client) do
    if Params.changed_long?(p, "legalFormId", client.legal_form_enum) do
      form = Params.integer(p, "legalFormId")

      {Map.put(changes, "legalFormId", Clients.legal_form_option(form)),
       set ++ legal_form_set(form)}
    else
      acc
    end
  end

  defp legal_form_set(nil), do: [legal_form_enum: nil]
  defp legal_form_set(1), do: [legal_form_enum: 1, fullname: nil]

  defp legal_form_set(form),
    do: [legal_form_enum: form, firstname: nil, lastname: nil, display_name: nil]

  defp date_changes(acc, p, client) do
    Enum.reduce(@date_fields, acc, fn field, acc -> date_change(acc, p, client, field) end)
  end

  defp date_change({changes, set} = acc, p, client, {key, field, column}) do
    if Params.changed_date?(p, key, Map.get(client, field)) do
      date = Params.date(p, key)

      changes =
        changes
        |> Map.put(key, Params.string(p, key))
        |> Map.put("dateFormat", Params.date_format(p))
        |> Map.put("locale", Params.locale(p))

      extra = if key == "activationDate", do: [office_joining_date: date], else: []
      {changes, set ++ [{column, date}] ++ extra}
    else
      acc
    end
  end

  @doc "The client as it will be once `set` is stored (the columns that matter to the rules)."
  @spec apply_changes(map, keyword) :: map
  def apply_changes(client, set) do
    renames = %{submittedon_date: :submitted_on, display_name: :display_name}

    Enum.reduce(set, client, fn {column, value}, acc ->
      Map.put(acc, Map.get(renames, column, column), value)
    end)
    |> then(fn updated -> Map.put(updated, :status_enum, client.status_enum) end)
  end

  @doc """
  Looks up what the request points to (staff, code values, savings product), storing the ones that
  changed. Answers `{changes, set}`.
  """
  @spec resolve_references(Params.t(), map, map, map, keyword) :: {map, keyword}
  def resolve_references(p, client, office, changes, set) do
    set =
      set
      |> reference(changes, "staffId", :staff_id, fn id ->
        Lookups.staff!(id, office.hierarchy).id
      end)
      |> reference(changes, "genderId", :gender_cv_id, &Lookups.code_value!(@gender, &1).id)
      |> savings_product(changes, client)
      |> reference(
        changes,
        "clientTypeId",
        :client_type_cv_id,
        &Lookups.code_value!(@client_type, &1).id
      )
      |> reference(
        changes,
        "clientClassificationId",
        :client_classification_cv_id,
        &Lookups.code_value!(@classification, &1).id
      )

    _ = p
    {changes, set}
  end

  defp reference(set, changes, key, column, lookup) do
    case Map.fetch(changes, key) do
      {:ok, nil} -> set ++ [{column, nil}]
      {:ok, id} -> set ++ [{column, lookup.(id)}]
      :error -> set
    end
  end

  defp savings_product(set, changes, client) do
    case Map.fetch(changes, "savingsProductId") do
      :error ->
        set

      {:ok, id} ->
        if client.status_enum == Clients.status(:active) do
          raise DomainRuleViolation,
            code: "error.msg.client.active.for.update.parameter.savingsProductId",
            message:
              "The Client with id `#{client.id}` is active,can't update parameter savingsProductId",
            args: [client.id, "savingsProductId"]
        end

        if id, do: Lookups.savings_product!(id)
        set ++ [default_savings_product: id]
    end
  end

  @doc "The external id a client has once `set` is stored, as text, or `nil` when it has none."
  @spec external_id_after(map, keyword) :: String.t() | nil
  def external_id_after(client, set) do
    value =
      if Keyword.has_key?(set, :external_id), do: set[:external_id], else: client.external_id

    if value in [nil, ""], do: nil, else: value
  end

  # --- entity details -------------------------------------------------------------------------

  @doc """
  Keeps the entity details of client `id` in step with a change of legal form and with the details sent,
  and adds what changed in them to `changes`.
  """
  @spec change_non_person!(integer, Params.t(), Params.t() | nil, map, map) :: map
  def change_non_person!(id, p, np, client, changes) do
    if Map.has_key?(changes, "legalFormId") do
      form = Params.integer(p, "legalFormId")

      if form == 2,
        do: create_non_person!(id, np, client.date_of_birth),
        else: TenantRepo.delete_all(from(n in "m_client_non_person", where: n.client_id == ^id))
    end

    existing = non_person_row(id)

    cond do
      existing != nil and np != nil ->
        np_changes = update_non_person!(existing, np)
        Map.merge(changes, np_changes)

      existing == nil and Params.integer(p, "legalFormId") == 2 ->
        create_non_person!(id, np, client.date_of_birth)
        changes

      true ->
        changes
    end
  end

  defp non_person_row(id) do
    TenantRepo.one(
      from(n in "m_client_non_person",
        where: n.client_id == ^id,
        select: %{
          id: n.id,
          constitution: n.constitution_cv_id,
          incorp_no: n.incorp_no,
          incorp_validity_till: n.incorp_validity_till,
          main_business_line: n.main_business_line_cv_id,
          remarks: n.remarks
        }
      )
    )
  end

  @doc """
  Records the entity details sent with a client (nothing when none were sent). The details must name a
  constitution, and their validity must not end before the client's date of birth.
  """
  @spec create_non_person!(integer, Params.t() | nil, Date.t() | nil) :: :ok
  def create_non_person!(_id, nil, _date_of_birth), do: :ok

  def create_non_person!(id, np, date_of_birth) do
    if map_size(np.map) > 0 do
      constitution = code_value(np, "constitutionId", @constitution)
      line = code_value(np, "mainBusinessLineId", @main_business_line)
      till = Params.date(np, "incorpValidityTillDate")
      check_non_person!(constitution, till, date_of_birth)

      TenantRepo.insert_all("m_client_non_person", [
        %{
          client_id: id,
          constitution_cv_id: constitution,
          incorp_no: trimmed(Params.string(np, "incorpNumber")),
          incorp_validity_till: till,
          main_business_line_cv_id: line,
          remarks: trimmed(Params.string(np, "remarks"))
        }
      ])
    end

    :ok
  end

  defp check_non_person!(constitution, till, date_of_birth) do
    errors =
      Enum.reject(
        [
          if(till && date_of_birth && later?(date_of_birth, till),
            do:
              ECBPlatform.Errors.parameter_error(
                "error.msg.clients.incorpValidityTill.after.incorp.date",
                "incorpvaliditytill date cannot be after the incorporation date",
                "incorpValidityTillDate",
                [Date.to_iso8601(till)]
              )
          ),
          if(constitution == nil,
            do:
              ECBPlatform.Errors.parameter_error(
                "error.msg.clients.constitutionid.is.null",
                "Constitution ID may not be null",
                "constitutionId"
              )
          )
        ],
        &is_nil/1
      )

    if errors != [], do: Validate.raise_errors!(errors)
  end

  defp trimmed(nil), do: nil
  defp trimmed(text), do: String.trim(text)

  defp code_value(np, key, code_name) do
    case Json.long(np, key) do
      nil -> nil
      value -> Lookups.code_value!(code_name, value).id
    end
  end

  defp update_non_person!(row, np) do
    {changes, set} =
      {%{}, []}
      |> np_text(np, "incorpNumber", row.incorp_no, :incorp_no)
      |> np_text(np, "remarks", row.remarks, :remarks)
      |> np_date(np, row)
      |> np_id(np, "constitutionId", row.constitution, :constitution_cv_id, @constitution)
      |> np_id(
        np,
        "mainBusinessLineId",
        row.main_business_line,
        :main_business_line_cv_id,
        @main_business_line
      )

    unless set == [],
      do:
        TenantRepo.update_all(from(n in "m_client_non_person", where: n.id == ^row.id), set: set)

    changes
  end

  defp np_text({changes, set}, np, key, existing, column) do
    if Params.changed_string?(np, key, existing) do
      value = Params.command_string(np, key)
      {Map.put(changes, key, value), set ++ [{column, if(value == "", do: nil, else: value)}]}
    else
      {changes, set}
    end
  end

  defp np_date({changes, set}, np, row) do
    key = "incorpValidityTillDate"

    if Params.changed_date?(np, key, row.incorp_validity_till) do
      changes =
        changes
        |> Map.put(key, Params.string(np, key))
        |> Map.put("dateFormat", Params.date_format(np))
        |> Map.put("locale", Params.locale(np))

      {changes, set ++ [incorp_validity_till: Params.date(np, key)]}
    else
      {changes, set}
    end
  end

  defp np_id({changes, set}, np, key, existing, column, code_name) do
    if Params.changed_long?(np, key, existing) do
      value = Json.long(np, key)
      stored = if value, do: Lookups.code_value!(code_name, value).id
      {Map.put(changes, key, value), set ++ [{column, stored}]}
    else
      {changes, set}
    end
  end

  # --- delete ---------------------------------------------------------------------------------

  @doc "Removes what hangs off client `id` and goes with it: the entity details and the identifiers."
  @spec delete_dependents!(integer) :: :ok
  def delete_dependents!(id) do
    TenantRepo.delete_all(from(n in "m_client_non_person", where: n.client_id == ^id))
    TenantRepo.delete_all(from(i in "m_client_identifier", where: i.client_id == ^id))
    :ok
  end

  @doc """
  A client with loans or savings accounts still open cannot be closed. Those modules are not built
  yet, so no account can block a closure for now.
  """
  @spec ensure_no_open_accounts!(integer, Date.t()) :: :ok
  def ensure_no_open_accounts!(_client_id, _closure_date), do: :ok

  @doc """
  What happens after a client is created: addresses and family members sent with it are added.
  """
  @spec after_create!(integer, Params.t(), boolean) :: :ok
  def after_create!(id, p, _address_on?) do
    case Params.value(p, "familyMembers") do
      members when is_list(members) -> ECBParty.FamilyMembers.add_all!(id, members)
      nil -> :ok
      # anything but a list cannot be read as members: an unhandled failure there
      _ -> raise ECBLedger.Errors.ServerError
    end

    if Params.exists?(p, "datatables") and Params.value(p, "datatables") not in [nil, []] do
      raise DomainRuleViolation,
        code: "error.msg.datatables.not.supported.yet",
        message: "Data tables are not available yet.",
        args: []
    end

    :ok
  end
end
