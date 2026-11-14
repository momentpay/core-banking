defmodule ECBPlatform.Configuration.Write do
  @moduledoc """
  Changing a global configuration property (`c_configuration`), following Fineract's update service.

  A property can be enabled or disabled and can carry a number (`value`), a date (`dateValue`) or text
  (`stringValue`). The few text properties that have a fixed set of allowed values are checked against it:
  each element is matched ignoring case, written in its canonical spelling and de-duplicated. A property
  marked as a trap door cannot be changed once a loan or savings account exists.
  """
  import Ecto.Query

  alias ECBPlatform.Commands.Result
  alias ECBPlatform.Configuration
  alias ECBPlatform.Errors.{DomainRuleViolation, PlatformApiDataValidation, ResourceNotFound}
  alias ECBPlatform.Params
  alias ECBPlatform.TenantRepo
  alias ECBPlatform.Validation

  @supported ~w(locale dateFormat enabled value dateValue stringValue)
  @force_reset_days "force-password-reset-days"

  @force_reset_message "For enabling 'Force Password Reset Days' configuration , the value (number of days after which a user is forced to reset his password) must be set to a number greater than 0."

  @doc "Updates property `id`. The result lists what changed."
  @spec update!(integer, Params.t()) :: Result.t()
  def update!(id, %Params{} = params) do
    params = Params.check_supported!(params, @supported)
    validate!(params)

    property = fetch!(id)

    if property.trap_door and products_exist?(),
      do:
        raise(DomainRuleViolation,
          code: "error.msg.configuration.id.not.modifiable",
          message: "Configuration identifier `#{id}` cannot be modified",
          args: [id]
        )

    allowed = Configuration.allowed_values(property.name)
    check_allowed!(params, allowed)

    changes =
      []
      |> change_enabled(params, property)
      |> change_value(params, property)
      |> change_date(params, property)
      |> change_string(params, property, allowed)

    unless changes == [] do
      TenantRepo.update_all(from(c in "c_configuration", where: c.id == ^id), set: changes)
    end

    check_force_reset_days!(property, params, changes)

    Result.new(resource_id: id, changes: shown(changes))
  end

  @doc "The id of the property named `name`, or raises the not-found error."
  @spec id_of!(String.t()) :: integer
  def id_of!(name) do
    case Configuration.get_by_name(name) do
      {:ok, %{id: id}} -> id
      {:error, error} -> raise error
    end
  end

  # --- validation -----------------------------------------------------------------------------

  defp validate!(params) do
    Validation.new("globalConfiguration")
    |> maybe(params, "value", fn v ->
      v
      |> Validation.param("value", Params.long(params, "value"))
      |> Validation.zero_or_positive_amount()
    end)
    |> maybe(params, "dateValue", fn v ->
      v
      |> Validation.param("dateValue", Params.date(params, "dateValue"))
      |> Validation.not_null()
    end)
    |> maybe(params, "stringValue", fn v ->
      v
      |> Validation.param("stringValue", Params.string(params, "stringValue"))
      |> Validation.not_null()
    end)
    |> Validation.raise_if_errors!()
  end

  defp maybe(validation, params, key, fun),
    do: if(Params.exists?(params, key), do: fun.(validation), else: validation)

  # A restricted text property takes only its allowed values, singly or (where allowed) as a list.
  defp check_allowed!(_params, nil), do: :ok

  defp check_allowed!(params, %{values: values, multiple: multiple?}) do
    case Params.string(params, "stringValue") do
      nil ->
        :ok

      text ->
        errors =
          for element <- elements(text, multiple?), not allowed?(values, element) do
            ECBPlatform.Errors.parameter_error(
              "validation.msg.globalConfiguration.stringValue.is.not.one.of.expected.enumerations",
              "The parameter `stringValue` must be one of [ #{Enum.join(values, ", ")} ] .",
              "stringValue",
              [element, values]
            )
          end

        if errors != [], do: raise(PlatformApiDataValidation, errors: errors)
    end
  end

  defp allowed?(values, element),
    do: Enum.any?(values, &(String.downcase(&1) == String.downcase(element)))

  defp elements(text, true), do: text |> String.split(",") |> Enum.map(&String.trim/1)
  defp elements(text, false), do: [String.trim(text)]

  # --- changes --------------------------------------------------------------------------------

  defp change_enabled(changes, params, property) do
    if Params.changed_boolean?(params, "enabled", property.enabled),
      do: [{:enabled, Params.boolean(params, "enabled")} | changes],
      else: changes
  end

  defp change_value(changes, params, property) do
    if Params.changed_long?(params, "value", property.value),
      do: [{:value, Params.long(params, "value")} | changes],
      else: changes
  end

  defp change_date(changes, params, property) do
    if Params.changed_date?(params, "dateValue", property.date_value),
      do: [{:date_value, Params.date(params, "dateValue")} | changes],
      else: changes
  end

  defp change_string(changes, params, property, allowed) do
    if Params.exists?(params, "stringValue") do
      new = canonical(Params.command_string(params, "stringValue"), allowed)
      if new != property.string_value, do: [{:string_value, new} | changes], else: changes
    else
      changes
    end
  end

  defp canonical(text, nil), do: text

  defp canonical(text, %{values: values, multiple: multiple?}) do
    text
    |> elements(multiple?)
    |> Enum.map(fn element ->
      Enum.find(values, element, &(String.downcase(&1) == String.downcase(element)))
    end)
    |> Enum.uniq()
    |> Enum.join(",")
  end

  defp shown(changes) do
    for {column, value} <- changes, into: %{}, do: {camel(column), value}
  end

  defp camel(:date_value), do: "dateValue"
  defp camel(:string_value), do: "stringValue"
  defp camel(other), do: Atom.to_string(other)

  # Turning on the password-reset period needs a number of days to count.
  defp check_force_reset_days!(%{name: @force_reset_days} = property, params, changes) do
    enabled = Keyword.get(changes, :enabled, property.enabled)

    value =
      if Params.exists?(params, "value"), do: Params.long(params, "value"), else: property.value

    if enabled and (value || 0) == 0,
      do:
        raise(DomainRuleViolation,
          code: "error.msg.password.reset.days.value.must.be.greater.than.zero",
          message: @force_reset_message,
          args: []
        )
  end

  defp check_force_reset_days!(_property, _params, _changes), do: :ok

  # --- stored state ---------------------------------------------------------------------------

  defp fetch!(id) do
    row =
      TenantRepo.one(
        from c in "c_configuration",
          where: c.id == ^id,
          select: %{
            id: c.id,
            name: c.name,
            enabled: c.enabled,
            value: c.value,
            date_value: c.date_value,
            string_value: c.string_value,
            trap_door: c.is_trap_door
          }
      )

    row ||
      raise ResourceNotFound,
        code: "error.msg.configuration.id.invalid",
        message: "Configuration identifier `#{id}` does not exist",
        args: [id]
  end

  # Loans, savings and share accounts live in modules that may not exist yet; a missing table means none.
  defp products_exist? do
    Enum.any?(~w(m_loan m_savings_account m_share_account), fn table ->
      %{rows: [[found]]} = TenantRepo.query!("SELECT to_regclass($1)::text", [table])

      found != nil and
        TenantRepo.query!("SELECT EXISTS (SELECT 1 FROM #{table})").rows == [[true]]
    end)
  end
end
