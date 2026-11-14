defmodule ECBPlatform.Params do
  @moduledoc """
  The values of a command's JSON body, read the way Fineract's `FromJsonHelper` and `JsonCommand`
  read them.

    * A parameter *exists* when the key is present, even with a `null` value. That is what makes
      an update able to clear a field.
    * A text value that is blank counts as no value.
    * Dates arrive as text with a `dateFormat` (a Java pattern such as `dd MMMM yyyy`) and a `locale`
      beside them. Reading a date without those is a validation error, as is a date that does not
      match the pattern.
    * `changed_*?` say whether an update really changes a stored value, which is how an update
      reports `changes`.

  Functions that cannot continue raise `ECBPlatform.Errors.InvalidJson`, `UnsupportedParameter` or
  `PlatformApiDataValidation`; the command pipeline turns those into Fineract's error response.
  """
  alias ECBPlatform.Errors
  alias ECBPlatform.Errors.{InvalidJson, PlatformApiDataValidation, UnsupportedParameter}
  alias ECBPlatform.Params.DatePattern

  defstruct map: %{}

  @type t :: %__MODULE__{map: map}

  @doc """
  Parses a request body. Raises `InvalidJson` when it is blank, not valid JSON, or not a JSON object.
  """
  @spec parse!(String.t() | nil) :: t
  def parse!(json) when json in [nil, ""], do: raise(InvalidJson, detail: nil)

  def parse!(json) when is_binary(json) do
    if String.trim(json) == "", do: raise(InvalidJson, detail: nil)

    case Jason.decode(json) do
      {:ok, %{} = map} ->
        %__MODULE__{map: map}

      {:ok, _other} ->
        raise InvalidJson, detail: "Expected BEGIN_OBJECT but was a different JSON value"

      {:error, %Jason.DecodeError{} = error} ->
        raise InvalidJson, detail: Exception.message(error)
    end
  end

  @doc "Raises `UnsupportedParameter` for any key not in `supported`."
  @spec check_supported!(t, [String.t()]) :: t
  def check_supported!(%__MODULE__{map: map} = params, supported) do
    case Enum.reject(Map.keys(map), &(&1 in supported)) do
      [] -> params
      unknown -> raise UnsupportedParameter, parameters: Enum.sort(unknown)
    end
  end

  @doc "True when the key is in the body, whatever its value."
  @spec exists?(t, String.t()) :: boolean
  def exists?(%__MODULE__{map: map}, key), do: Map.has_key?(map, key)

  @doc "True when the key is in the body with a value that is not null or blank."
  @spec has_value?(t, String.t()) :: boolean
  def has_value?(%__MODULE__{map: map}, key) do
    case Map.get(map, key) do
      nil -> false
      "" -> false
      [] -> false
      value when is_map(value) -> map_size(value) > 0
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end
  end

  @doc "A text parameter: `nil` when absent, null, blank, or not a simple value. Numbers and booleans become text."
  @spec string(t, String.t()) :: String.t() | nil
  def string(%__MODULE__{map: map}, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      value when is_number(value) or is_boolean(value) -> to_string(value)
      _ -> nil
    end
  end

  @doc "A whole-number parameter, or `nil`. A value that is not a whole number is a validation error."
  @spec long(t, String.t()) :: integer | nil
  def long(%__MODULE__{} = params, key) do
    case string(params, key) do
      nil ->
        nil

      text ->
        case Integer.parse(String.trim(text)) do
          {number, ""} -> number
          _ -> raise_number_error(key, text)
        end
    end
  end

  @doc "Same as `long/2`: Fineract keeps `Long` and `Integer` apart, but both are whole numbers here."
  @spec integer(t, String.t()) :: integer | nil
  def integer(params, key), do: long(params, key)

  @doc "A true or false parameter, or `nil`."
  @spec boolean(t, String.t()) :: boolean | nil
  def boolean(%__MODULE__{map: map}, key) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  @doc """
  A decimal parameter, or `nil`. Numbers in JSON are exact; text is read in the request's locale
  (`1,234.50`), of which only the English style is understood so far.
  """
  @spec decimal(t, String.t()) :: Decimal.t() | nil
  def decimal(%__MODULE__{map: map} = params, key) do
    case Map.get(map, key) do
      nil ->
        nil

      value when is_integer(value) ->
        Decimal.new(value)

      value when is_float(value) ->
        Decimal.from_float(value)

      value when is_binary(value) ->
        _ = locale(params)
        decimal_from_text(key, value)

      _ ->
        nil
    end
  end

  defp decimal_from_text(key, value) do
    text = value |> String.trim() |> String.replace(",", "")

    case Decimal.parse(text) do
      {decimal, ""} -> decimal
      _ when text == "" -> nil
      _ -> raise_number_error(key, value)
    end
  end

  @doc "The `dateFormat` sent with the request, or `nil`."
  @spec date_format(t) :: String.t() | nil
  def date_format(%__MODULE__{} = params), do: string(params, "dateFormat")

  @doc """
  The `locale` sent with the request, as text, or `nil`. A locale that is present must be of the form
  `en` or `en_US`; anything else is a validation error.
  """
  @spec locale(t) :: String.t() | nil
  def locale(%__MODULE__{map: map} = params) do
    if Map.has_key?(map, "locale") and is_binary(Map.get(map, "locale")) do
      validate_locale!(Map.get(map, "locale"))
    else
      string(params, "locale")
    end
  end

  @doc """
  A date parameter, or `nil` when absent or blank. When there is a value, the request must carry a
  `dateFormat` and a `locale`, and the value must match the format.
  """
  @spec date(t, String.t()) :: Date.t() | nil
  def date(%__MODULE__{map: map} = params, key) do
    locale = locale(params)
    format = date_format(params)

    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: parse_date!(value, key, format, locale)

      value when is_number(value) ->
        parse_date!(to_string(value), key, format, locale)

      _ ->
        nil
    end
  end

  # --- change detection -----------------------------------------------------------------------

  @doc """
  The text of a parameter as a command reads it when deciding what changed: a missing or blank value is
  the empty text, never `nil`. (Reading a value to validate it gives `nil` instead; see `string/2`.)
  """
  @spec command_string(t, String.t()) :: String.t()
  def command_string(params, key), do: string(params, key) || ""

  @doc """
  True when the parameter exists and its text differs from `existing`. As in Fineract, clearing a field
  that was already empty (`nil`) still counts as a change, because the blank value is `""`.
  """
  @spec changed_string?(t, String.t(), String.t() | nil) :: boolean
  def changed_string?(params, key, existing),
    do: exists?(params, key) and differs?(existing, command_string(params, key))

  @doc "True when the parameter exists and its whole-number value differs from `existing`."
  @spec changed_long?(t, String.t(), integer | nil) :: boolean
  def changed_long?(params, key, existing),
    do: exists?(params, key) and differs?(existing, long(params, key))

  @doc "True when the parameter exists and its true/false value differs from `existing`."
  @spec changed_boolean?(t, String.t(), boolean | nil) :: boolean
  def changed_boolean?(params, key, existing),
    do: exists?(params, key) and differs?(existing, boolean(params, key))

  @doc "True when the parameter exists and its date differs from `existing`."
  @spec changed_date?(t, String.t(), Date.t() | nil) :: boolean
  def changed_date?(params, key, existing),
    do: exists?(params, key) and differs?(existing, date(params, key))

  @doc "True when the parameter exists and its decimal value differs from `existing`."
  @spec changed_decimal?(t, String.t(), Decimal.t() | nil) :: boolean
  def changed_decimal?(params, key, existing) do
    exists?(params, key) and
      case {existing, decimal(params, key)} do
        {nil, nil} -> false
        {nil, _} -> true
        {_, nil} -> true
        {a, b} -> not Decimal.equal?(a, b)
      end
  end

  defp differs?(same, same), do: false
  defp differs?(_a, _b), do: true

  # --- internals ------------------------------------------------------------------------------

  defp parse_date!(value, key, format, locale) do
    missing =
      [
        if(is_nil(format),
          do:
            Errors.parameter_error(
              "validation.msg.missing.dateFormat.parameter",
              "The parameter `#{key}` requires a `dateFormat` parameter to be passed with it.",
              key
            )
        ),
        if(is_nil(locale),
          do:
            Errors.parameter_error(
              "validation.msg.missing.locale.parameter",
              "The parameter `#{key}` requires a `locale` parameter to be passed with it.",
              key
            )
        )
      ]
      |> Enum.reject(&is_nil/1)

    if missing != [], do: raise(PlatformApiDataValidation, errors: missing)

    case DatePattern.parse(value, format) do
      {:ok, date} ->
        date

      :error ->
        raise PlatformApiDataValidation,
          errors: [
            Errors.parameter_error(
              "validation.msg.invalid.dateFormat.format",
              "The parameter `#{key}` is invalid based on the dateFormat: `#{format}` and locale: `#{locale}` provided:",
              key,
              [nil, format]
            )
          ]
    end
  end

  defp validate_locale!(text) do
    cond do
      String.trim(text) == "" ->
        raise PlatformApiDataValidation,
          errors: [
            Errors.parameter_error(
              "validation.msg.invalid.locale.format",
              "The parameter `locale` is invalid. It cannot be blank.",
              "locale"
            )
          ]

      Regex.match?(~r/^[a-z]{2,3}(_[A-Z]{2})?(_[A-Za-z0-9]+)?$/, text) ->
        text

      true ->
        raise PlatformApiDataValidation,
          errors: [
            Errors.parameter_error(
              "validation.msg.invalid.locale.format",
              "The parameter `locale` has an invalid format: #{text} .",
              "locale"
            )
          ]
    end
  end

  defp raise_number_error(key, text) do
    raise PlatformApiDataValidation,
      errors: [
        Errors.parameter_error(
          "validation.msg.invalid.number.format",
          "The parameter `#{key}` has an invalid number: `#{text}`.",
          key
        )
      ]
  end
end
