defmodule ECBMoney.Math do
  @moduledoc """
  Null-safe helpers for plain decimal amounts, ported from Fineract's `MathUtil` (the `BigDecimal`
  section). Fineract passes `null` around for "no value"; these helpers give `nil` the meaning the
  original gives it, so code ported from Fineract keeps its behaviour.

  Unlike `ECBMoney`, these do not round to a currency scale. Where the original rounds (addition and
  subtraction with a `MathContext`) a `ECBMoney.Context` is taken explicitly.

  Mirrors `org.apache.fineract.infrastructure.core.service.MathUtil`.
  """

  import Kernel, except: [abs: 1]

  alias ECBMoney.{Context, Currency, Precision}

  @type amount :: Decimal.t() | nil

  @doc "`nil` becomes zero."
  @spec null_to_zero(amount) :: Decimal.t()
  def null_to_zero(nil), do: Decimal.new(0)
  def null_to_zero(%Decimal{} = value), do: value

  @doc "`nil` becomes `default`."
  @spec null_to_default(amount, Decimal.t()) :: Decimal.t()
  def null_to_default(nil, default), do: default
  def null_to_default(%Decimal{} = value, _default), do: value

  @doc "Zero (or `nil`) becomes `nil`."
  @spec zero_to_null(amount) :: Decimal.t() | nil
  def zero_to_null(value), do: if(empty?(value), do: nil, else: value)

  @doc "A negative value becomes zero. Zero and `nil` give zero."
  @spec negative_to_zero(amount) :: Decimal.t()
  def negative_to_zero(value), do: if(greater_than_zero?(value), do: value, else: Decimal.new(0))

  @doc "True for `nil` or zero."
  @spec empty?(amount) :: boolean
  def empty?(nil), do: true
  def empty?(%Decimal{} = value), do: Decimal.eq?(value, 0)

  @doc "True when the value exists and is above zero."
  @spec greater_than_zero?(amount) :: boolean
  def greater_than_zero?(nil), do: false
  def greater_than_zero?(%Decimal{} = value), do: Decimal.gt?(value, 0)

  @doc "True when the value exists and is below zero."
  @spec less_than_zero?(amount) :: boolean
  def less_than_zero?(nil), do: false
  def less_than_zero?(%Decimal{} = value), do: Decimal.lt?(value, 0)

  @doc "True when the value exists and is zero. `nil` is not zero here, as in Fineract."
  @spec zero?(amount) :: boolean
  def zero?(nil), do: false
  def zero?(%Decimal{} = value), do: Decimal.eq?(value, 0)

  @doc "True when the value is `nil` or at most zero."
  @spec less_than_or_equal_zero?(amount) :: boolean
  def less_than_or_equal_zero?(value), do: value |> null_to_zero() |> Decimal.lte?(0)

  @doc "Equal, treating `nil` as zero."
  @spec equal?(amount, amount) :: boolean
  def equal?(a, b), do: Decimal.eq?(null_to_zero(a), null_to_zero(b))

  @spec greater_than?(amount, amount) :: boolean
  def greater_than?(a, b), do: Decimal.gt?(null_to_zero(a), null_to_zero(b))

  @spec less_than?(amount, amount) :: boolean
  def less_than?(a, b), do: Decimal.lt?(null_to_zero(a), null_to_zero(b))

  @spec greater_than_or_equal?(amount, amount) :: boolean
  def greater_than_or_equal?(a, b), do: Decimal.gte?(null_to_zero(a), null_to_zero(b))

  @doc """
  `a <= b`, treating a `nil` first value as zero. A `nil` second value is also read as zero here;
  Fineract's own method would fail with a null pointer in that case.
  """
  @spec less_than_or_equal?(amount, amount) :: boolean
  def less_than_or_equal?(a, b), do: Decimal.lte?(null_to_zero(a), null_to_zero(b))

  @doc "Absolute value; `nil` gives zero."
  @spec abs(amount) :: Decimal.t()
  def abs(nil), do: Decimal.new(0)
  def abs(%Decimal{} = value), do: Decimal.abs(value)

  @doc """
  The smaller of two values. With `not_null` true a `nil` is ignored; with it false the comparison
  treats `nil` as zero. Returns `nil` only when both are `nil` and `not_null` is true.
  """
  @spec min(amount, amount, boolean) :: amount
  def min(first, second, true) do
    cond do
      is_nil(first) -> second
      is_nil(second) -> first
      true -> min(first, second, false)
    end
  end

  def min(first, second, false), do: if(less_than?(first, second), do: first, else: second)

  @doc "Sum of two values, `nil` meaning absent. Rounds to the context's precision."
  @spec add(amount, amount, Context.t()) :: amount
  def add(nil, second, _context), do: second
  def add(first, nil, _context), do: first

  def add(first, second, %Context{} = context),
    do: Precision.exact(fn -> Decimal.add(first, second) end) |> rounded(context)

  @doc "Sum of a list, skipping `nil`. Returns `nil` when every item is `nil`."
  @spec add_all([amount], Context.t()) :: amount
  def add_all(amounts, %Context{} = context), do: Enum.reduce(amounts, nil, &add(&2, &1, context))

  @doc "First minus second, `nil` meaning absent: a `nil` first gives `nil`, a `nil` second gives the first."
  @spec subtract(amount, amount, Context.t()) :: amount
  def subtract(nil, _second, _context), do: nil
  def subtract(first, nil, _context), do: first

  def subtract(first, second, %Context{} = context),
    do: Precision.exact(fn -> Decimal.sub(first, second) end) |> rounded(context)

  @doc "First minus the others, but never below zero."
  @spec subtract_to_zero(amount, [amount], Context.t()) :: Decimal.t()
  def subtract_to_zero(first, others, %Context{} = context) do
    others |> Enum.reduce(first, &subtract(&2, &1, context)) |> negative_to_zero()
  end

  @doc "Negates a non-empty value; `nil` and zero come back unchanged."
  @spec negate(amount, Context.t()) :: amount
  def negate(value, %Context{}) when is_nil(value), do: nil

  def negate(%Decimal{} = value, %Context{} = context) do
    if Decimal.eq?(value, 0), do: value, else: value |> Decimal.negate() |> rounded(context)
  end

  @doc """
  Sets the scale of an amount to the currency's decimal places, with the given rounding mode.
  `nil` stays `nil`.
  """
  @spec normalize_amount(amount, Currency.t(), ECBMoney.Rounding.t()) :: amount
  def normalize_amount(nil, %Currency{}, _rounding), do: nil

  def normalize_amount(%Decimal{} = amount, %Currency{decimal_places: places}, rounding),
    do: Decimal.round(amount, places, rounding)

  # BigDecimal.add/subtract/negate with a MathContext: exact, then rounded to the context's precision.
  defp rounded(%Decimal{} = value, %Context{} = context) do
    value
    |> Precision.round_significant(context.precision, context.rounding)
    |> Precision.normalize_zero()
  end
end
