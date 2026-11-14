defmodule ECBMoney.Currency do
  @moduledoc """
  A currency as Fineract defines it (`m_currency`, selected per tenant in `m_organisation_currency`).

  The two fields that drive arithmetic are `decimal_places` (the scale every amount is rounded to) and
  `in_multiples_of` (round whole-unit amounts to a multiple, for example 5 or 50). The others are for
  display and match Fineract's `CurrencyData`.

  Mirrors `org.apache.fineract.organisation.monetary.data.CurrencyData`.
  """

  @enforce_keys [:code, :decimal_places]
  defstruct [:code, :name, :decimal_places, :in_multiples_of, :display_symbol, :name_code]

  @type t :: %__MODULE__{
          code: String.t(),
          name: String.t() | nil,
          decimal_places: non_neg_integer,
          in_multiples_of: pos_integer | nil,
          display_symbol: String.t() | nil,
          name_code: String.t() | nil
        }

  @doc """
  Builds a currency.

  The code is three characters (Fineract's column is `varchar(3)`). `decimal_places` is 0 or more.
  `:in_multiples_of` must be a positive integer when given; it only takes effect when `decimal_places`
  is 0, exactly as in Fineract.

  ## Options

    * `:name`, `:display_symbol`, `:name_code` - display data
    * `:in_multiples_of` - round whole-unit amounts to this multiple
  """
  @spec new(String.t(), non_neg_integer, keyword) :: t()
  def new(code, decimal_places, opts \\ []) do
    unless is_binary(code) and String.length(code) == 3,
      do: raise(ArgumentError, "currency code must be 3 characters, got: #{inspect(code)}")

    unless is_integer(decimal_places) and decimal_places >= 0,
      do:
        raise(
          ArgumentError,
          "decimal_places must be a non-negative integer, got: #{inspect(decimal_places)}"
        )

    multiples = Keyword.get(opts, :in_multiples_of)

    unless is_nil(multiples) or (is_integer(multiples) and multiples >= 0),
      do:
        raise(
          ArgumentError,
          "in_multiples_of must be a non-negative integer or nil, got: #{inspect(multiples)}"
        )

    %__MODULE__{
      code: code,
      name: Keyword.get(opts, :name),
      decimal_places: decimal_places,
      in_multiples_of: multiples,
      display_symbol: Keyword.get(opts, :display_symbol),
      name_code: Keyword.get(opts, :name_code)
    }
  end

  @doc """
  The label Fineract shows in drop-downs: the name, then the symbol in round brackets, or the code in
  square brackets when there is no symbol. For example `"US Dollar ($)"` or `"Kenyan Shilling [KES]"`.
  """
  @spec display_label(t()) :: String.t()
  def display_label(%__MODULE__{} = c) do
    name = if c.name, do: c.name <> " ", else: ""

    if c.display_symbol && String.trim(c.display_symbol) != "" do
      name <> "(" <> c.display_symbol <> ")"
    else
      name <> "[" <> c.code <> "]"
    end
  end
end
