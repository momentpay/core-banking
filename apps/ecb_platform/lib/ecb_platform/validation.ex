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

  def zero_or_positive_amount(v), do: v

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

  # --- free-form ------------------------------------------------------------------------------

  @doc """
  Records a problem that has only a code: `validation.msg.<resource>.<parameter>.<code>`, with the
  message `Failed data validation due to: <code>.` and the value refused as its first argument, as
  Fineract's `failWithCode` does.
  """
  @spec fail_with_code(t, String.t()) :: t
  def fail_with_code(v, code),
    do: add(v, code, "Failed data validation due to: #{code}.", [v.value, []])

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
