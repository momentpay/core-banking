defmodule ECBMoney do
  @moduledoc """
  An exact monetary amount in one currency.

  This follows Apache Fineract's `Money` class operation by operation, because loan schedules and
  interest postings must match its cents. The rules that matter:

    * The amount is a `Decimal`, never a float. Floats are rejected with `ArgumentError`.
    * **Every operation rounds back to the currency's decimal places** and returns a new value. There
      is no hidden extra precision between steps: `a |> plus(b) |> times(c)` rounds after the addition
      and again after the multiplication, as Fineract does.
    * Addition and subtraction are exact before that final rounding. Multiplication and division first
      round to the context's precision (19 digits in Fineract) with the context's rounding mode.
    * A currency "in multiples of" N with 0 decimal places rounds positive amounts to a multiple of N
      at construction.
    * Mixing currencies raises `ECBMoney.CurrencyMismatchError`.
    * Rounding is a value (`ECBMoney.Context`) carried by the money, never read from process state.

  ## Examples

      iex> usd = ECBMoney.Currency.new("USD", 2)
      iex> ctx = ECBMoney.Context.new(:half_even)
      iex> ECBMoney.new(usd, "10.005", ctx) |> to_string()
      "USD 10.00"
      iex> ECBMoney.new(usd, "10.00", ctx) |> ECBMoney.plus("0.015") |> to_string()
      "USD 10.02"

  Mirrors `org.apache.fineract.organisation.monetary.domain.Money`.
  """

  import Kernel, except: [abs: 1, to_string: 1]

  alias ECBMoney.{Context, Currency, Precision}

  @enforce_keys [:amount, :currency, :context]
  defstruct [:amount, :currency, :context]

  @type t :: %__MODULE__{amount: Decimal.t(), currency: Currency.t(), context: Context.t()}
  @type amount_input :: Decimal.t() | integer | String.t() | nil

  defmodule CurrencyMismatchError do
    @moduledoc "Raised when money in different currencies is combined or compared."
    defexception [:left, :right]

    @impl true
    def message(%{left: left, right: right}), do: "currencies are different: #{left} and #{right}"
  end

  # --- construction ---------------------------------------------------------------------------

  @doc """
  Builds money, rounding as Fineract's constructor does.

  `amount` may be a `Decimal`, an integer, a numeric string, or `nil` (meaning zero). The result's
  scale is the currency's decimal places.
  """
  @spec new(Currency.t(), amount_input, Context.t()) :: t()
  def new(%Currency{} = currency, amount, %Context{} = context) do
    value = amount |> to_decimal() |> Decimal.normalize()

    value =
      if multiples?(currency) and Decimal.gt?(value, 0) do
        divide_round_multiply(
          value,
          currency.in_multiples_of,
          Context.multiples_rounding(context)
        )
      else
        value
      end

    %__MODULE__{
      amount:
        value
        |> Decimal.round(currency.decimal_places, context.rounding)
        |> Precision.normalize_zero(),
      currency: currency,
      context: context
    }
  end

  @doc "Zero in the given currency."
  @spec zero(Currency.t(), Context.t()) :: t()
  def zero(%Currency{} = currency, %Context{} = context), do: new(currency, 0, context)

  @doc """
  Sum of a non-empty list. Raises `ArgumentError` on an empty list, as Fineract does, because the
  currency cannot be known.
  """
  @spec total([t()]) :: t()
  def total([]), do: raise(ArgumentError, "Money list must not be empty")
  def total([first | rest]), do: Enum.reduce(rest, first, &plus(&2, &1))

  # --- accessors ------------------------------------------------------------------------------

  @doc "The amount as a `Decimal` with the currency's scale."
  @spec amount(t()) :: Decimal.t()
  def amount(%__MODULE__{amount: amount}), do: amount

  @doc "The amount, or `nil` when it is zero (Fineract's `getAmountDefaultedToNullIfZero`)."
  @spec amount_or_nil_if_zero(t()) :: Decimal.t() | nil
  def amount_or_nil_if_zero(%__MODULE__{} = money),
    do: if(zero?(money), do: nil, else: money.amount)

  @spec currency(t()) :: Currency.t()
  def currency(%__MODULE__{currency: currency}), do: currency

  @spec currency_code(t()) :: String.t()
  def currency_code(%__MODULE__{currency: %Currency{code: code}}), do: code

  @spec same_currency?(t(), t()) :: boolean
  def same_currency?(%__MODULE__{} = a, %__MODULE__{} = b),
    do: currency_code(a) == currency_code(b)

  # --- addition and subtraction ---------------------------------------------------------------

  @doc """
  Adds money, an amount, or `nil` (which changes nothing).

  The result takes `context` (default: the left operand's). Adding zero returns the left operand
  unchanged.
  """
  @spec plus(t(), t() | amount_input, Context.t() | nil) :: t()
  def plus(money, other, context \\ nil)
  def plus(%__MODULE__{} = money, nil, _context), do: money

  def plus(%__MODULE__{} = money, %__MODULE__{} = other, context) do
    check_currency!(money, other)
    plus(money, other.amount, context)
  end

  def plus(%__MODULE__{} = money, amount, context) do
    amount = to_decimal(amount)

    if Decimal.eq?(amount, 0) do
      money
    else
      new(
        money.currency,
        exact(fn -> Decimal.add(money.amount, amount) end),
        context || money.context
      )
    end
  end

  @doc "Subtracts money, an amount, or `nil` (which changes nothing). See `plus/3`."
  @spec minus(t(), t() | amount_input, Context.t() | nil) :: t()
  def minus(money, other, context \\ nil)
  def minus(%__MODULE__{} = money, nil, _context), do: money

  def minus(%__MODULE__{} = money, %__MODULE__{} = other, context) do
    check_currency!(money, other)
    minus(money, other.amount, context)
  end

  def minus(%__MODULE__{} = money, amount, context) do
    amount = to_decimal(amount)

    if Decimal.eq?(amount, 0) do
      money
    else
      new(
        money.currency,
        exact(fn -> Decimal.sub(money.amount, amount) end),
        context || money.context
      )
    end
  end

  # --- multiplication and division ------------------------------------------------------------

  @doc """
  Multiplies by a number. The product is rounded to the context's precision, then to the currency's
  scale. Multiplying by 1 returns the money unchanged.
  """
  @spec times(t(), Decimal.t() | integer | String.t(), Context.t() | nil) :: t()
  def times(%__MODULE__{} = money, factor, context \\ nil) do
    factor = to_decimal(factor)
    context = context || money.context

    if Decimal.eq?(factor, 1) do
      money
    else
      new(money.currency, rounded_product(money.amount, factor, context), context)
    end
  end

  @doc """
  Divides by a number. The quotient is rounded to the context's precision, then to the currency's
  scale. Dividing by 1 returns the money unchanged; dividing by zero raises `ArithmeticError`.
  """
  @spec divide(t(), Decimal.t() | integer | String.t(), Context.t() | nil) :: t()
  def divide(%__MODULE__{} = money, divisor, context \\ nil) do
    divisor = to_decimal(divisor)
    context = context || money.context

    cond do
      Decimal.eq?(divisor, 1) ->
        money

      Decimal.eq?(divisor, 0) ->
        raise ArithmeticError, "Division by zero"

      true ->
        new(
          money.currency,
          Precision.divide(money.amount, divisor, context.precision, context.rounding),
          context
        )
    end
  end

  @doc """
  `percentage` percent of the amount: multiply exactly, then divide by 100 under the context.
  `percentage_of(1000.00, 12.5)` is 125.00.
  """
  @spec percentage_of(t(), Decimal.t() | integer | String.t(), Context.t() | nil) :: t()
  def percentage_of(%__MODULE__{} = money, percentage, context \\ nil) do
    percentage = to_decimal(percentage)
    context = context || money.context
    exact_product = exact(fn -> Decimal.mult(money.amount, percentage) end)

    new(
      money.currency,
      Precision.divide(exact_product, Decimal.new(100), context.precision, context.rounding),
      context
    )
  end

  @doc """
  Like `times/3`, but rounds explicitly to the currency's scale with the context's mode before
  constructing the result. It differs from `times/3` only for "in multiples of" currencies.
  """
  @spec multiply_retain_scale(t(), Decimal.t() | integer | String.t(), Context.t() | nil) :: t()
  def multiply_retain_scale(%__MODULE__{} = money, factor, context \\ nil) do
    factor = to_decimal(factor)
    context = context || money.context

    if Decimal.eq?(factor, 1) do
      money
    else
      product = rounded_product(money.amount, factor, context)

      new(
        money.currency,
        Decimal.round(product, money.currency.decimal_places, context.rounding),
        context
      )
    end
  end

  @doc """
  Rounds to a multiple of `multiple` using the context's rounding mode. A multiple of 0 or less
  leaves the amount alone.

  As in Fineract, the result is built with the tenant's own context (the context's
  `:multiples_rounding`), which only differs from the context passed in when the two were set apart.
  """
  @spec round_to_multiples_of(t(), integer, Context.t() | nil) :: t()
  def round_to_multiples_of(%__MODULE__{} = money, multiple, context \\ nil)
      when is_integer(multiple) do
    context = context || money.context
    tenant = Context.new(Context.multiples_rounding(context), precision: context.precision)

    value =
      if multiple > 0,
        do: divide_round_multiply(money.amount, multiple, context.rounding),
        else: money.amount

    new(money.currency, value, tenant)
  end

  # --- sign -----------------------------------------------------------------------------------

  @doc "Negates. Zero is returned unchanged."
  @spec negate(t(), Context.t() | nil) :: t()
  def negate(%__MODULE__{} = money, context \\ nil) do
    if zero?(money),
      do: money,
      else: new(money.currency, Decimal.negate(money.amount), context || money.context)
  end

  @doc "Absolute value."
  @spec abs(t(), Context.t() | nil) :: t()
  def abs(%__MODULE__{} = money, context \\ nil) do
    if negative?(money), do: negate(money, context), else: money
  end

  # --- comparison -----------------------------------------------------------------------------

  @doc "Compares two amounts in the same currency. Raises `CurrencyMismatchError` otherwise."
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    check_currency!(a, b)
    Decimal.compare(a.amount, b.amount)
  end

  @spec zero?(t()) :: boolean
  def zero?(%__MODULE__{amount: amount}), do: Decimal.eq?(amount, 0)

  @spec positive?(t()) :: boolean
  def positive?(%__MODULE__{amount: amount}), do: Decimal.gt?(amount, 0)

  @spec negative?(t()) :: boolean
  def negative?(%__MODULE__{amount: amount}), do: Decimal.lt?(amount, 0)

  @spec equal?(t(), t()) :: boolean
  def equal?(a, b), do: compare(a, b) == :eq

  @spec not_equal?(t(), t()) :: boolean
  def not_equal?(a, b), do: compare(a, b) != :eq

  @spec greater_than?(t(), t()) :: boolean
  def greater_than?(a, b), do: compare(a, b) == :gt

  @spec greater_than_or_equal?(t(), t()) :: boolean
  def greater_than_or_equal?(a, b), do: compare(a, b) in [:gt, :eq]

  @spec less_than?(t(), t()) :: boolean
  def less_than?(a, b), do: compare(a, b) == :lt

  @spec less_than_or_equal?(t(), t()) :: boolean
  def less_than_or_equal?(a, b), do: compare(a, b) in [:lt, :eq]

  # --- allocation (E-CoreBank utility, not in Fineract's Money) --------------------------------

  @doc """
  Splits an amount in proportion to `ratios` without losing a unit.

  The shares always add up to the original amount. Each share is a whole number of the currency's
  smallest unit (a cent for 2 decimal places, or the "multiple of" for such currencies). Leftover
  units go to the largest fractional remainders, ties to the earlier ratio. A negative amount is
  split by its absolute value and each share negated. Ratios must be non-negative and not all zero.

  This helper is ours, not Fineract's: Fineract has no general allocator (its loan code distributes
  amounts with specific rules). It exists for callers that must split a payment, a fee or a charge
  across parties and cannot afford a rounding gap.
  """
  @spec allocate(t(), [Decimal.t() | integer | String.t()]) :: [t()]
  def allocate(%__MODULE__{} = money, ratios) when is_list(ratios) and ratios != [] do
    ratios = Enum.map(ratios, &to_decimal/1)

    if Enum.any?(ratios, &Decimal.lt?(&1, 0)),
      do: raise(ArgumentError, "ratios must not be negative")

    total = Enum.reduce(ratios, Decimal.new(0), &exact(fn -> Decimal.add(&2, &1) end))
    if Decimal.eq?(total, 0), do: raise(ArgumentError, "ratios must not all be zero")

    unit = smallest_unit(money.currency)

    units =
      exact(fn -> money.amount |> Decimal.abs() |> Decimal.div_int(unit) end)
      |> Decimal.to_integer()

    sign = if negative?(money), do: -1, else: 1

    # Exact rational arithmetic on integers: share_i = units * ratio_i / total.
    {numerators, denominator} = integer_ratios(ratios, total)

    parts =
      numerators
      |> Enum.with_index()
      |> Enum.map(fn {n, i} ->
        scaled = units * n
        {i, div(scaled, denominator), rem(scaled, denominator)}
      end)

    leftover = units - Enum.sum(Enum.map(parts, fn {_i, whole, _r} -> whole end))

    winners =
      parts
      |> Enum.sort_by(fn {i, _whole, remainder} -> {-remainder, i} end)
      |> Enum.take(leftover)
      |> MapSet.new(fn {i, _whole, _r} -> i end)

    Enum.map(parts, fn {i, whole, _remainder} ->
      share_units = whole + if(MapSet.member?(winners, i), do: 1, else: 0)
      amount = Decimal.mult(Decimal.new(sign * share_units), unit)
      new(money.currency, amount, money.context)
    end)
  end

  # --- display --------------------------------------------------------------------------------

  @doc "`\"USD 12.50\"`, as Fineract's `toString`."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = money) do
    money.currency.code <> " " <> Decimal.to_string(money.amount, :normal)
  end

  defimpl String.Chars do
    def to_string(money), do: ECBMoney.to_string(money)
  end

  defimpl Inspect do
    def inspect(money, _opts), do: "#ECBMoney<#{ECBMoney.to_string(money)}>"
  end

  # --- internals ------------------------------------------------------------------------------

  defp multiples?(%Currency{in_multiples_of: multiple, decimal_places: 0})
       when is_integer(multiple) and multiple > 0,
       do: true

  defp multiples?(_currency), do: false

  defp check_currency!(a, b) do
    unless same_currency?(a, b),
      do: raise(CurrencyMismatchError, left: currency_code(a), right: currency_code(b))

    :ok
  end

  @doc false
  # Accepts the inputs money functions take. Floats are refused on purpose: a float has already lost
  # the digits a ledger needs.
  def to_decimal(nil), do: Decimal.new(0)

  def to_decimal(%Decimal{coef: coef} = d) when coef in [:NaN, :inf],
    do: raise(ArgumentError, "invalid decimal: #{inspect(d)}")

  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(value) when is_integer(value), do: Decimal.new(value)
  def to_decimal(value) when is_binary(value), do: Decimal.new(value)

  def to_decimal(value) when is_float(value),
    do:
      raise(
        ArgumentError,
        "floats are not accepted for money (got #{inspect(value)}); use a Decimal, integer or string"
      )

  def to_decimal(value), do: raise(ArgumentError, "cannot use #{inspect(value)} as an amount")

  defp exact(fun), do: Precision.exact(fun)

  # BigDecimal.multiply(factor, mc): the exact product rounded to the context's precision.
  defp rounded_product(amount, factor, %Context{} = context) do
    exact(fn -> Decimal.mult(amount, factor) end)
    |> Precision.round_significant(context.precision, context.rounding)
  end

  # BigDecimal.divide(multiple, 0, mode).multiply(multiple): exact quotient rounded to a whole number
  # with `mode`, then scaled back. Works on the integer quotient and remainder so nothing is rounded
  # twice, and handles negative amounts by rounding the magnitude with the mirrored mode.
  defp divide_round_multiply(value, multiple, mode) do
    divisor = Decimal.new(multiple)
    negative? = Decimal.lt?(value, 0)
    magnitude = Decimal.abs(value)
    mode = if negative?, do: mirror(mode), else: mode

    {quotient, remainder} =
      exact(fn -> {Decimal.div_int(magnitude, divisor), Decimal.rem(magnitude, divisor)} end)

    rounded = round_quotient(quotient, remainder, divisor, mode)
    result = exact(fn -> Decimal.mult(rounded, divisor) end)
    if negative?, do: Decimal.negate(result), else: result
  end

  # For a negative number, ceiling and floor swap when working on the magnitude.
  defp mirror(:ceiling), do: :down
  defp mirror(:floor), do: :up
  defp mirror(mode), do: mode

  defp round_quotient(quotient, remainder, divisor, mode) do
    cond do
      Decimal.eq?(remainder, 0) ->
        quotient

      increment?(mode, compare_remainder(remainder, divisor), quotient) ->
        exact(fn -> Decimal.add(quotient, 1) end)

      true ->
        quotient
    end
  end

  # Where the remainder sits against half the divisor: below, exactly at, or above.
  defp compare_remainder(remainder, divisor),
    do: Decimal.compare(exact(fn -> Decimal.mult(remainder, 2) end), divisor)

  # Whether to round the (positive) quotient up, given the mode and where the remainder sits.
  defp increment?(mode, _comparison, _quotient) when mode in [:up, :ceiling], do: true
  defp increment?(mode, _comparison, _quotient) when mode in [:down, :floor], do: false
  defp increment?(:half_up, comparison, _quotient), do: comparison != :lt
  defp increment?(:half_down, comparison, _quotient), do: comparison == :gt
  defp increment?(:half_even, :gt, _quotient), do: true
  defp increment?(:half_even, :lt, _quotient), do: false
  defp increment?(:half_even, :eq, quotient), do: odd?(quotient)

  defp odd?(%Decimal{} = d), do: rem(Decimal.to_integer(d), 2) == 1

  # The smallest amount the currency can hold: its multiple (whole-unit currencies) or one
  # unit in the last decimal place.
  defp smallest_unit(%Currency{decimal_places: 0, in_multiples_of: m})
       when is_integer(m) and m > 0,
       do: Decimal.new(m)

  defp smallest_unit(%Currency{decimal_places: places}), do: Decimal.new(1, 1, -places)

  # Turns decimal ratios into integers over a common denominator so allocation is exact.
  defp integer_ratios(ratios, total) do
    exponent = Enum.map([total | ratios], & &1.exp) |> Enum.min() |> min(0)

    scale = fn d ->
      exact(fn -> Decimal.mult(d, Decimal.new(1, 1, -exponent)) end) |> Decimal.to_integer()
    end

    {Enum.map(ratios, scale), scale.(total)}
  end
end
