defmodule ECBPlatform.Validation do
  @moduledoc """
  Request validation that reports problems the way Fineract's `DataValidatorBuilder` does: every
  problem is collected, each with a message code built from the resource and the parameter, and one
  `PlatformApiDataValidation` error (HTTP 400) lists them all.

      Validation.new("office")
      |> Validation.param("name", name) |> Validation.not_blank() |> Validation.max_length(100)
      |> Validation.param("openingDate", date) |> Validation.not_null()
      |> Validation.raise_if_errors!()

  `param/3` starts a new check and forgets the earlier parameter's settings, as `reset()` does.
  `ignore_if_null/1` makes the checks that follow skip a missing value, for optional parameters.
  The codes read `validation.msg.<resource>.<parameter>.<problem>`, for example
  `validation.msg.office.name.cannot.be.blank`.
  """
  alias ECBPlatform.Errors
  alias ECBPlatform.Errors.PlatformApiDataValidation

  defstruct resource: nil, parameter: nil, value: nil, ignore_null: false, errors: []

  @type t :: %__MODULE__{}

  @doc "Starts validating a request for `resource`."
  @spec new(String.t()) :: t
  def new(resource), do: %__MODULE__{resource: resource}

  @doc "Begins checking `parameter`, whose value is `value`."
  @spec param(t, String.t(), term) :: t
  def param(%__MODULE__{} = v, parameter, value),
    do: %{v | parameter: parameter, value: value, ignore_null: false}

  @doc """
  Runs checks the way Fineract's `reset().parameter(..).value(..)` chains do: on a builder of their own, so that the
  parameter and value they name are not left behind for the problems that are recorded without naming one.
  """
  @spec scoped(t, (t -> t)) :: t
  def scoped(%__MODULE__{} = v, fun) do
    %{parameter: parameter, value: value, ignore_null: ignore} = v
    %{fun.(v) | parameter: parameter, value: value, ignore_null: ignore}
  end

  @doc "Names the parameter the next problems are about but keeps the value (Fineract's `parameter(..)` alone)."
  @spec parameter(t, String.t()) :: t
  def parameter(%__MODULE__{} = v, parameter), do: %{v | parameter: parameter}

  @doc "The checks that follow pass when the value is missing."
  @spec ignore_if_null(t) :: t
  def ignore_if_null(%__MODULE__{} = v), do: %{v | ignore_null: true}

  @doc "True when a problem has been recorded."
  @spec errors?(t) :: boolean
  def errors?(%__MODULE__{errors: errors}), do: errors != []

  @doc "Raises `PlatformApiDataValidation` when problems were recorded; otherwise returns `:ok`."
  @spec raise_if_errors!(t) :: :ok
  def raise_if_errors!(%__MODULE__{errors: []}), do: :ok

  def raise_if_errors!(%__MODULE__{errors: errors}),
    do: raise(PlatformApiDataValidation, errors: Enum.reverse(errors))

  # --- presence -------------------------------------------------------------------------------

  @doc "The value must not be missing."
  @spec not_null(t) :: t
  def not_null(%{value: nil, ignore_null: false} = v), do: mandatory(v)
  def not_null(v), do: v

  @doc "The value must not be missing or blank text."
  @spec not_blank(t) :: t
  def not_blank(%{value: nil, ignore_null: true} = v), do: v

  def not_blank(%{value: value} = v) do
    if is_nil(value) or String.trim(to_string(value)) == "", do: mandatory(v), else: v
  end

  defp mandatory(v) do
    add(
      v,
      "cannot.be.blank",
      "The parameter `#{v.parameter}` is mandatory.",
      [nil]
    )
  end

  # --- text -----------------------------------------------------------------------------------

  @doc "Text no longer than `max` characters (after trimming)."
  @spec max_length(t, pos_integer) :: t
  def max_length(%{value: nil} = v, _max), do: v

  def max_length(%{value: value} = v, max) do
    text = to_string(value)

    if String.length(String.trim(text)) > max,
      do:
        add(
          v,
          "exceeds.max.length",
          "The parameter `#{v.parameter}` exceeds max length of #{max}.",
          [
            max,
            text
          ]
        ),
      else: v
  end

  @doc """
  The whole text must match the regular expression `source` (a string in Java/PCRE syntax). `message`
  replaces the standard text, as Fineract does for a password policy.
  """
  @spec matches(t, String.t(), String.t() | nil) :: t
  def matches(v, source, message \\ nil)
  def matches(%{value: nil} = v, _source, _message), do: v

  def matches(%{value: value} = v, source, message) do
    {:ok, regex} = Regex.compile("\\A(?:" <> source <> ")\\z")

    if Regex.match?(regex, to_string(value)),
      do: v,
      else:
        add(
          v,
          "does.not.match.regexp",
          message ||
            "The parameter `#{v.parameter}` must match the provided regular expression [ #{source} ] .",
          [value, source]
        )
  end

  @doc """
  The current value must equal `linked_value`, the value of another parameter. The problem is recorded
  against the other parameter: `validation.msg.<resource>.<linked>.not.equal.to.<parameter>`.
  """
  @spec equal_to_parameter(t, String.t(), term) :: t
  def equal_to_parameter(%{value: nil} = v, _linked, _linked_value), do: v

  def equal_to_parameter(%{value: value} = v, linked, linked_value) do
    if value == linked_value do
      v
    else
      error =
        Errors.parameter_error(
          "validation.msg.#{v.resource}.#{linked}.not.equal.to.#{v.parameter}",
          "The parameter `#{linked}` is not equal to #{v.parameter}.",
          linked,
          [linked_value, value]
        )

      %{v | errors: [error | v.errors]}
    end
  end

  @doc "A list that has at least one entry."
  @spec array_not_empty(t) :: t
  def array_not_empty(%{value: nil, ignore_null: true} = v), do: v

  def array_not_empty(%{value: value} = v) when value in [nil, []],
    do:
      add(
        v,
        "cannot.be.empty",
        "The parameter `#{v.parameter}` cannot be empty. You must select at least one.",
        []
      )

  def array_not_empty(v), do: v

  @doc "The value must be one of `allowed`."
  @spec one_of(t, [term]) :: t
  def one_of(%{value: nil, ignore_null: true} = v, _allowed), do: v

  def one_of(%{value: value} = v, allowed) do
    if value in allowed,
      do: v,
      else:
        add(
          v,
          "is.not.one.of.expected.enumerations",
          "The parameter `#{v.parameter}` must be one of [ #{Enum.join(allowed, ", ")} ] .",
          [value, allowed]
        )
  end

  @doc "The value must not be any of `unwanted`."
  @spec not_one_of(t, [term]) :: t
  def not_one_of(%{value: nil} = v, _unwanted), do: v

  def not_one_of(%{value: value} = v, unwanted) do
    if value in unwanted,
      do:
        add(
          v,
          "is.one.of.unwanted.enumerations",
          "The parameter `#{v.parameter}` must not be any of [ #{Enum.join(unwanted, ", ")} ] .",
          [value, unwanted]
        ),
      else: v
  end

  @doc """
  The value must be blank when another parameter has a given value (Fineract's
  `mustBeBlankWhenParameterProvidedIs`): `feeOnMonthDay` on a weekly fee, for one.
  """
  @spec blank_when(t, String.t(), term) :: t
  def blank_when(%{value: nil} = v, _other, _other_value), do: v

  def blank_when(%{value: value} = v, other, other_value) do
    if is_binary(value) and String.trim(value) == "",
      do: v,
      else:
        add(
          v,
          "cannot.also.be.provided.when.#{other}.is.#{other_value}",
          "The parameter `#{v.parameter}` cannot also be provided when `#{other}` is #{other_value}",
          [value, other, other_value]
        )
  end

  @doc """
  The value must be blank when another parameter is populated (Fineract's
  `mustBeBlankWhenParameterProvided`): `fullname` beside `firstname`, for one.
  """
  @spec blank_when_populated(t, String.t(), term) :: t
  def blank_when_populated(%{value: nil} = v, _other, _other_value), do: v

  def blank_when_populated(%{value: value} = v, other, other_value) do
    if is_binary(value) and String.trim(value) == "",
      do: v,
      else:
        add(
          v,
          "cannot.also.be.provided.when.#{other}.is.populated",
          "The parameter `#{v.parameter}` cannot also be provided when `#{other}` is populated.",
          [value, other, other_value]
        )
  end

  @doc "The value must be true or false."
  @spec true_or_false(t) :: t
  def true_or_false(%{value: value} = v) when is_boolean(value), do: v
  def true_or_false(%{value: nil, ignore_null: true} = v), do: v

  def true_or_false(v),
    do:
      add(
        v,
        "must.be.true.or.false",
        "The parameter `#{v.parameter}` must be set as true or false.",
        []
      )

  # --- numbers --------------------------------------------------------------------------------

  @doc "A whole number of at least 1."
  @spec greater_than_zero(t) :: t
  def greater_than_zero(%{value: nil} = v), do: v

  def greater_than_zero(%{value: value} = v) when is_integer(value) and value < 1,
    do:
      add(v, "not.greater.than.zero", "The parameter `#{v.parameter}` must be greater than 0.", [
        value,
        0
      ])

  def greater_than_zero(v), do: v

  @doc """
  A number of 0 or more, shown as a decimal in the problem's arguments (`-1.0`), as Fineract shows
  amounts. Used where Fineract validates a whole number as an amount.
  """
  @spec zero_or_positive_amount(t) :: t
  def zero_or_positive_amount(%{value: nil} = v), do: v

  def zero_or_positive_amount(%{value: value} = v) when is_number(value) and value < 0,
    do:
      add(
        v,
        "not.zero.or.greater",
        "The parameter `#{v.parameter}` must be greater than or equal to 0.",
        [value * 1.0, 0]
      )

  def zero_or_positive_amount(%{value: %Decimal{} = value} = v) do
    if Decimal.negative?(value),
      do:
        add(
          v,
          "not.zero.or.greater",
          "The parameter `#{v.parameter}` must be greater than or equal to 0.",
          [Decimal.to_float(value), 0]
        ),
      else: v
  end

  def zero_or_positive_amount(v), do: v

  @doc """
  A decimal above zero. The refused value is shown as a decimal (`-1.0`), as Fineract shows amounts.
  """
  @spec positive_amount(t) :: t
  def positive_amount(%{value: nil} = v), do: v

  def positive_amount(%{value: %Decimal{} = value} = v) do
    if Decimal.compare(value, 0) == :gt,
      do: v,
      else:
        add(
          v,
          "not.greater.than.zero",
          "The parameter `#{v.parameter}` must be greater than 0.",
          [
            Decimal.to_float(value),
            0
          ]
        )
  end

  def positive_amount(v), do: v

  @doc "A decimal of at most `max`."
  @spec not_greater_than_max(t, number) :: t
  def not_greater_than_max(%{value: nil} = v, _max), do: v

  def not_greater_than_max(%{value: %Decimal{} = value} = v, max) do
    if Decimal.compare(value, max) == :gt do
      shown = Decimal.to_float(value)

      add(
        v,
        "is.greater.than.max",
        "The parameter `#{v.parameter}` value #{double_text(shown)} must not be more than maximum value #{max}",
        [shown, max]
      )
    else
      v
    end
  end

  def not_greater_than_max(v, _max), do: v

  # a double as Java writes it in a message: in full, with a decimal point
  defp double_text(float) do
    text = float |> Decimal.from_float() |> Decimal.to_string(:normal)
    if String.contains?(text, "."), do: text, else: text <> ".0"
  end

  @doc "A decimal of at least `min` (Fineract's `notLessThanMin`)."
  @spec not_less_than_min(t, Decimal.t() | nil) :: t
  def not_less_than_min(%{value: %Decimal{} = value} = v, %Decimal{} = min) do
    if Decimal.compare(value, min) == :lt do
      shown = Decimal.to_float(value)

      add(
        v,
        "is.less.than.min",
        "The parameter `#{v.parameter}` value #{double_text(shown)} must not be less than the minimum value #{min}",
        [shown, min]
      )
    else
      v
    end
  end

  def not_less_than_min(v, _min), do: v

  @doc "A decimal between `min` and `max` (Fineract's `inMinAndMaxAmountRange`)."
  @spec in_min_and_max_amount_range(t, Decimal.t(), Decimal.t()) :: t
  def in_min_and_max_amount_range(
        %{value: %Decimal{} = value} = v,
        %Decimal{} = min,
        %Decimal{} = max
      ) do
    if Decimal.compare(value, min) == :lt or Decimal.compare(value, max) == :gt do
      shown = Decimal.to_float(value)

      add(
        v,
        "amount.is.not.within.min.max.range",
        "The parameter `#{v.parameter}` amount #{double_text(shown)} must be between #{min} and #{max} .",
        [shown, min, max]
      )
    else
      v
    end
  end

  def in_min_and_max_amount_range(v, _min, _max), do: v

  @doc """
  The value must be given when another parameter has a given value (Fineract's `cantBeBlankWhenParameterProvidedIs`).
  """
  @spec must_be_provided_when(t, String.t(), term) :: t
  def must_be_provided_when(%{value: value} = v, other, other_value) do
    if value != nil and String.trim(to_string(value)) != "" do
      v
    else
      add(
        v,
        "must.be.provided.when.#{other}.is.#{other_value}",
        "The parameter `#{v.parameter}` must be provided when `#{other}` is #{other_value}",
        [value, other, other_value]
      )
    end
  end

  @doc """
  A date on or after `other` (a missing date passes; Fineract's `validateDateAfter` refuses only a date
  before it, whatever its name says). The problem shows both dates as text.
  """
  @spec date_after(t, Date.t()) :: t
  def date_after(%{value: %Date{} = value} = v, %Date{} = other) do
    if Date.compare(value, other) != :lt,
      do: v,
      else:
        add(
          v,
          "is.less.than.date",
          "The parameter `#{v.parameter}` must be greater than the provided date #{other}",
          [Date.to_iso8601(value), Date.to_iso8601(other)]
        )
  end

  def date_after(v, _other), do: v

  @doc "A whole number of 0 or more."
  @spec zero_or_greater(t) :: t
  def zero_or_greater(%{value: nil} = v), do: v

  def zero_or_greater(%{value: value} = v) when is_integer(value) and value < 0,
    do:
      add(v, "not.zero.or.greater", "The parameter `#{v.parameter}` must be zero or greater.", [
        value,
        0
      ])

  def zero_or_greater(v), do: v

  @doc "A whole number within `min..max`."
  @spec in_range(t, integer, integer) :: t
  def in_range(%{value: nil} = v, _min, _max), do: v

  def in_range(%{value: value} = v, min, max) when is_integer(value) do
    if value < min or value > max,
      do:
        add(
          v,
          "is.not.within.expected.range",
          "The parameter `#{v.parameter}` must be between #{min} and #{max}.",
          [value, min, max]
        ),
      else: v
  end

  def in_range(v, _min, _max), do: v

  # --- dates ----------------------------------------------------------------------------------

  @doc "A date not before `other`."
  @spec date_not_before(t, Date.t()) :: t
  def date_not_before(%{value: %Date{} = value} = v, %Date{} = other) do
    if Date.compare(value, other) == :lt,
      do:
        add(
          v,
          "is.before.than.date",
          "The parameter `#{v.parameter}` must be greater than or equal to provided date #{other}.",
          [value, other]
        ),
      else: v
  end

  def date_not_before(v, _other), do: v

  @doc "A date not after `other`."
  @spec date_not_after(t, Date.t()) :: t
  def date_not_after(%{value: %Date{} = value} = v, %Date{} = other) do
    if Date.compare(value, other) == :gt,
      do:
        add(
          v,
          "is.greater.than.date",
          "The parameter `#{v.parameter}` must be less than or equal to provided date #{other}.",
          [value, other]
        ),
      else: v
  end

  def date_not_after(v, _other), do: v

  @doc """
  A date not after `date` (Fineract's `validateDateBefore`: a value later than `date` is refused). A
  missing date or limit passes.
  """
  @spec date_before(t, Date.t() | nil) :: t
  def date_before(%{value: %Date{} = value} = v, %Date{} = date) do
    if Date.compare(date, value) == :lt,
      do:
        add(
          v,
          "is.greater.than.date",
          "The parameter `#{v.parameter}` must be less than the provided date#{date}",
          [Date.to_iso8601(value), Date.to_iso8601(date)]
        ),
      else: v
  end

  def date_before(v, _date), do: v

  @doc "A date on or before `date` (Fineract's `validateDateBeforeOrEqual`)."
  @spec date_before_or_equal(t, Date.t()) :: t
  def date_before_or_equal(%{value: %Date{} = value} = v, %Date{} = date) do
    if Date.compare(value, date) == :gt,
      do:
        add(
          v,
          "is.greater.than.date",
          "The parameter `#{v.parameter}` must be less than or equal to the provided date: #{date}",
          [Date.to_iso8601(value), Date.to_iso8601(date)]
        ),
      else: v
  end

  def date_before_or_equal(v, _date), do: v

  @doc "A text that, when there is one, is a pattern Java's date formatter accepts."
  @spec valid_date_time_pattern(t) :: t
  def valid_date_time_pattern(%{value: value} = v) when is_binary(value) do
    if String.trim(value) == "" or ECBPlatform.Params.DatePattern.valid?(value) do
      v
    else
      # Fineract builds this error with its arguments in the wrong places: the parameter name is shown as the
      # text for people and the pattern as the parameter name.
      error = %{
        code: "validation.msg.#{v.resource}.#{v.parameter}.invalid.dateFormat.pattern",
        developer_message:
          "The parameter `#{v.parameter}` has an invalid date/time pattern: `#{value}`.",
        default_message: v.parameter,
        parameter: value,
        args: []
      }

      %{v | errors: [error | v.errors]}
    end
  end

  def valid_date_time_pattern(v), do: v

  @doc """
  Text that says true or false (Fineract's `validateForBooleanValue`, which looks at the text of a value, in
  any case). A missing value is refused unless nulls are ignored.
  """
  @spec boolean_text(t) :: t
  def boolean_text(%{value: nil, ignore_null: true} = v), do: v

  def boolean_text(%{value: value} = v) do
    if String.downcase(String.trim(to_string(value))) in ["true", "false"],
      do: v,
      else:
        add(
          v,
          "value.should.true.or.false",
          "The parameter `#{v.parameter}` value should true or false ",
          [value]
        )
  end

  @doc "A whole number greater than `number` (`longGreaterThanNumber`)."
  @spec greater_than_number(t, integer) :: t
  def greater_than_number(%{value: nil} = v, _number), do: v

  def greater_than_number(%{value: value} = v, number) when is_integer(value) do
    if value < number + 1,
      do:
        add(
          v,
          "not.greater.than.specified.number",
          "The parameter `#{v.parameter}` must be greater than #{number}",
          [value, number]
        ),
      else: v
  end

  def greater_than_number(v, _number), do: v

  @doc """
  A problem whose code is `validation.msg.<resource>.<code>` with no parameter in it and the text
  `Failed data validation due to: <code>.` (`failWithCodeNoParameterAddedToErrorCode`).
  """
  @spec fail_without_parameter(t, String.t(), [term]) :: t
  def fail_without_parameter(v, code, extra \\ []) do
    error = %{
      code: "validation.msg.#{v.resource}.#{code}",
      developer_message: "Failed data validation due to: #{code}.",
      default_message: "Failed data validation due to: #{code}.",
      parameter: v.parameter,
      args: [arg(v.value), extra]
    }

    %{v | errors: [error | v.errors]}
  end

  # --- free-form ------------------------------------------------------------------------------

  @doc """
  Records a problem that has only a code: `validation.msg.<resource>.<parameter>.<code>`, with the
  message `Failed data validation due to: <code>.` and the value refused as its first argument, as
  Fineract's `failWithCode` does.
  """
  @spec fail_with_code(t, String.t(), [term]) :: t
  def fail_with_code(v, code, extra \\ []),
    do: add(v, code, "Failed data validation due to: #{code}.", [arg(v.value), extra])

  # a date in the arguments of an error is its text, as Fineract writes it
  defp arg(%Date{} = date), do: Date.to_iso8601(date)
  defp arg(value), do: value

  @doc """
  Records that an update carried nothing to change: `validation.msg.<resource>.no.parameters.for.update`,
  against the parameter `id`, as Fineract's `anyOfNotNull` does.
  """
  @spec no_parameters_for_update(t) :: t
  def no_parameters_for_update(%__MODULE__{} = v) do
    error =
      Errors.parameter_error(
        "validation.msg.#{v.resource}.no.parameters.for.update",
        "No parameters passed for update.",
        "id"
      )

    %{v | errors: [error | v.errors]}
  end

  @doc "Records a problem with a code and message of your own: `validation.msg.<resource>.<parameter>.<code>`."
  @spec fail(t, String.t(), String.t(), [term]) :: t
  def fail(v, code, message, args \\ []), do: add(v, code, message, args)

  @doc """
  Records a problem whose code is not built from the resource and parameter, with the message code, the
  text, the parameter name (which may name several) and the arguments written out in full.
  """
  @spec add_error(t, String.t(), String.t(), String.t(), [term]) :: t
  def add_error(v, code, message, parameter, args),
    do: %{v | errors: [Errors.parameter_error(code, message, parameter, args) | v.errors]}

  defp add(v, problem, message, args) do
    error =
      Errors.parameter_error(
        "validation.msg.#{v.resource}.#{v.parameter}.#{problem}",
        message,
        v.parameter,
        args
      )

    %{v | errors: [error | v.errors]}
  end
end
