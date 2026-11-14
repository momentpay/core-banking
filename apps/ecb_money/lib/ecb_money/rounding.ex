defmodule ECBMoney.Rounding do
  @moduledoc """
  Rounding modes, numbered exactly as Apache Fineract stores them.

  Fineract keeps the tenant's mode in the global configuration `rounding-mode` as an integer 0 to 6
  (default 6) and converts it with `java.math.RoundingMode.valueOf(int)`. The numbering below is that
  enumeration's order, so a configuration value migrates unchanged:

  | Value | Mode        | Behaviour                                               |
  |------:|-------------|---------------------------------------------------------|
  | 0     | `:up`       | away from zero                                          |
  | 1     | `:down`     | toward zero (truncate)                                  |
  | 2     | `:ceiling`  | toward positive infinity                                |
  | 3     | `:floor`    | toward negative infinity                                |
  | 4     | `:half_up`  | nearest; a tie goes away from zero                      |
  | 5     | `:half_down`| nearest; a tie goes toward zero                         |
  | 6     | `:half_even`| nearest; a tie goes to the even neighbour (banker's)    |

  These atoms are also the rounding names `Decimal` understands, with the same meaning.

  Mirrors `org.apache.fineract.organisation.monetary.domain.MoneyHelper` (validation 0..6).
  """

  @modes [:up, :down, :ceiling, :floor, :half_up, :half_down, :half_even]

  @type t :: :up | :down | :ceiling | :floor | :half_up | :half_down | :half_even

  @doc "All modes, in Fineract's numeric order."
  @spec modes() :: [t()]
  def modes, do: @modes

  @doc "True for a supported mode."
  @spec valid?(term) :: boolean
  def valid?(mode), do: mode in @modes

  @doc "The default tenant mode in Fineract (configuration value 6)."
  @spec default() :: t()
  def default, do: :half_even

  @doc """
  Converts a Fineract configuration value (0 to 6) to a mode.

  Raises `ArgumentError` for anything else, as Fineract does.
  """
  @spec from_int(integer) :: t()
  def from_int(value) when is_integer(value) and value in 0..6, do: Enum.at(@modes, value)

  def from_int(value) do
    raise ArgumentError,
          "Invalid rounding mode value: #{inspect(value)}. Valid values are 0-6 (corresponding to RoundingMode enum ordinals)"
  end

  @doc "Converts a mode to its Fineract configuration value (0 to 6)."
  @spec to_int(t()) :: 0..6
  def to_int(mode) when mode in @modes, do: Enum.find_index(@modes, &(&1 == mode))
  def to_int(mode), do: raise(ArgumentError, "unknown rounding mode: #{inspect(mode)}")
end
