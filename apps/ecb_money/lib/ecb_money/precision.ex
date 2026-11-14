defmodule ECBMoney.Precision do
  @moduledoc false
  # Exact arithmetic and significant-digit rounding with `java.math.BigDecimal` semantics.
  #
  # Fineract rounds products and quotients to a MathContext: a number of significant digits (19)
  # and a rounding mode. The `Decimal` library has a context for this too, but in version 2.4.1 its
  # `:up` mode rounded up even when every discarded digit was zero (for example 1000000000000.00 x
  # 3.2016064 at 19 digits gave ...000001 instead of ...000000), which Java does not do. A
  # golden-master comparison with Fineract's own `Money` found it. Decimal 3 no longer has the quirk,
  # but the rounding here stays explicit: it is done on exact values with `Decimal.round/3` and integer
  # division, so the results do not depend on how a library implements its context, and the golden
  # master guards it.

  @exact_precision 200

  @doc """
  Runs `fun` with enough precision that `Decimal` never rounds addition, subtraction or
  multiplication of the sizes money uses. Equivalent to BigDecimal's exact add, subtract and
  multiply without a MathContext.
  """
  def exact(fun) do
    Decimal.Context.with(%Decimal.Context{precision: @exact_precision, rounding: :half_even}, fun)
  end

  @doc """
  Rounds to `precision` significant digits with `mode`: `new BigDecimal(x).round(new MathContext(precision, mode))`.
  A value with no more digits than `precision` is returned as it is.
  """
  def round_significant(%Decimal{coef: 0} = value, _precision, _mode), do: value

  def round_significant(%Decimal{coef: coef, exp: exp} = value, precision, mode) do
    digits = digit_count(coef)

    if digits <= precision do
      value
    else
      Decimal.round(value, precision - digits - exp, mode)
    end
  end

  @doc """
  `dividend.divide(divisor, new MathContext(precision, mode))`: the exact quotient rounded to
  `precision` significant digits. The divisor must not be zero.

  The quotient is built with integer division to at least `precision + 1` digits, then a final
  digit of 1 is appended whenever the remainder is not zero. That digit makes every rounding mode
  see "something follows", so a true tie (nothing follows) is told apart from a near tie.
  """
  def divide(%Decimal{coef: 0}, %Decimal{}, _precision, _mode), do: Decimal.new(0)

  def divide(
        %Decimal{sign: sa, coef: ca, exp: ea},
        %Decimal{sign: sb, coef: cb, exp: eb},
        precision,
        mode
      )
      when cb != 0 do
    shift = max(0, precision + 2 + digit_count(cb) - digit_count(ca))
    numerator = ca * Integer.pow(10, shift)
    quotient = div(numerator, cb)
    sticky = if rem(numerator, cb) == 0, do: 0, else: 1

    rounded =
      Decimal.new(sa * sb, quotient * 10 + sticky, ea - eb - shift - 1)
      |> round_significant(precision, mode)

    # BigDecimal returns an exact quotient without trailing zeros (2.5, not 2.500000000000000000).
    if sticky == 0, do: Decimal.normalize(rounded), else: rounded
  end

  @doc "Zero has no sign in BigDecimal; `Decimal` keeps one. Drop it."
  def normalize_zero(%Decimal{coef: 0, sign: -1} = value), do: %{value | sign: 1}
  def normalize_zero(%Decimal{} = value), do: value

  defp digit_count(coef), do: coef |> Integer.to_string() |> byte_size()
end
