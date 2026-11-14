defmodule ECBMoney.Context do
  @moduledoc """
  Precision and rounding for money arithmetic: the equivalent of Fineract's `java.math.MathContext`
  as built by `MoneyHelper`.

  Fineract creates one context per tenant: 19 significant digits and the tenant's rounding mode.
  Here the context is a plain value passed in, never read from process state or configuration, so a
  calculation always says what rounding it uses.

  `:multiples_rounding` covers one Fineract quirk. When a currency is "in multiples of" a number
  (for example whole units in multiples of 5), the amount is first rounded to that multiple with the
  *tenant's* rounding mode, while the final scale uses the context's mode. They are normally the same.
  Leave it `nil` to use the context's rounding for both, or set it to reproduce a caller that builds a
  context with a different mode.
  """

  alias ECBMoney.Rounding

  @precision 19

  @enforce_keys [:rounding]
  defstruct precision: @precision, rounding: :half_even, multiples_rounding: nil

  @type t :: %__MODULE__{
          precision: pos_integer,
          rounding: Rounding.t(),
          multiples_rounding: Rounding.t() | nil
        }

  @doc "Fineract's precision: 19 significant digits."
  @spec default_precision() :: pos_integer
  def default_precision, do: @precision

  @doc """
  Builds a context.

  ## Options

    * `:precision` - significant digits for multiplication and division (default 19)
    * `:multiples_rounding` - mode for the "multiples of" step (default: same as `rounding`)
  """
  @spec new(Rounding.t(), keyword) :: t()
  def new(rounding, opts \\ []) do
    unless Rounding.valid?(rounding),
      do: raise(ArgumentError, "unknown rounding mode: #{inspect(rounding)}")

    precision = Keyword.get(opts, :precision, @precision)

    unless is_integer(precision) and precision > 0,
      do: raise(ArgumentError, "precision must be a positive integer, got: #{inspect(precision)}")

    multiples = Keyword.get(opts, :multiples_rounding)

    unless is_nil(multiples) or Rounding.valid?(multiples),
      do: raise(ArgumentError, "unknown rounding mode: #{inspect(multiples)}")

    %__MODULE__{precision: precision, rounding: rounding, multiples_rounding: multiples}
  end

  @doc "Builds a context from a Fineract `rounding-mode` configuration value (0 to 6)."
  @spec from_rounding_int(integer) :: t()
  def from_rounding_int(value), do: new(Rounding.from_int(value))

  @doc "The mode used for the 'multiples of' step."
  @spec multiples_rounding(t()) :: Rounding.t()
  def multiples_rounding(%__MODULE__{multiples_rounding: nil, rounding: rounding}), do: rounding
  def multiples_rounding(%__MODULE__{multiples_rounding: mode}), do: mode
end
