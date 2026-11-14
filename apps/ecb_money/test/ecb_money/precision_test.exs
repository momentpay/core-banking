defmodule ECBMoney.PrecisionTest do
  @moduledoc """
  Regression tests for the two defects the golden-master comparison with Fineract found in a first
  port that leaned on the `Decimal` library's context rounding (Decimal 2.4.1; version 3 fixed the
  first one, but these tests stay so the behaviour never depends on it).
  """
  use ExUnit.Case, async: true

  alias ECBMoney.{Context, Currency, Precision}

  defp d(v), do: Decimal.new(v)
  defp plain(decimal), do: Decimal.to_string(decimal, :normal)

  describe "round_significant/3 (BigDecimal.round with a MathContext)" do
    test "leaves a value with few enough digits alone" do
      assert plain(Precision.round_significant(d("123.45"), 19, :up)) == "123.45"
    end

    test "rounds to the number of significant digits with each mode" do
      value = d("1234.5678")
      assert plain(Precision.round_significant(value, 6, :down)) == "1234.56"
      assert plain(Precision.round_significant(value, 6, :up)) == "1234.57"
      assert plain(Precision.round_significant(value, 6, :half_up)) == "1234.57"
      assert plain(Precision.round_significant(value, 6, :ceiling)) == "1234.57"
      assert plain(Precision.round_significant(value, 6, :floor)) == "1234.56"
    end

    test "rounding up does not move a value whose discarded digits are all zero" do
      # Decimal 2.4.1's own :up rounding returned ...000001 here; BigDecimal returns ...000000.
      exact = Precision.exact(fn -> Decimal.mult(d("1000000000000.00"), d("3.2016064")) end)
      assert plain(Precision.round_significant(exact, 19, :up)) == "3201606400000.000000"
      assert plain(Precision.round_significant(exact, 19, :ceiling)) == "3201606400000.000000"
    end

    test "rounds large values to tens, hundreds and so on" do
      assert plain(Precision.round_significant(d("123456789"), 4, :half_up)) == "123500000"
      assert plain(Precision.round_significant(d("123456789"), 4, :down)) == "123400000"
    end

    test "zero is returned as it is" do
      assert Precision.round_significant(d("0.000"), 3, :up) == d("0.000")
    end
  end

  describe "divide/4 (BigDecimal.divide with a MathContext)" do
    test "gives an exact quotient when there is one" do
      assert plain(Precision.divide(d("10"), d("4"), 19, :half_even)) == "2.5"
      assert Decimal.equal?(Precision.divide(d("1"), d("8"), 19, :up), d("0.125"))
    end

    test "rounds a repeating quotient to the precision" do
      assert plain(Precision.divide(d("1"), d("3"), 5, :half_even)) == "0.33333"
      assert plain(Precision.divide(d("2"), d("3"), 5, :half_even)) == "0.66667"
      assert plain(Precision.divide(d("2"), d("3"), 5, :down)) == "0.66666"
      assert plain(Precision.divide(d("1"), d("3"), 5, :up)) == "0.33334"
    end

    test "tells an exact tie from a value just above it" do
      # 1/32 = 0.03125 is an exact tie at 3 significant digits: 0.0312 or 0.0313
      assert plain(Precision.divide(d("1"), d("32"), 3, :half_even)) == "0.0312"
      assert plain(Precision.divide(d("1"), d("32"), 3, :half_down)) == "0.0312"
      assert plain(Precision.divide(d("1"), d("32"), 3, :half_up)) == "0.0313"
      # 0.03125001 is not a tie, so every half mode rounds it up
      for mode <- [:half_even, :half_down, :half_up] do
        assert plain(Precision.divide(d("3125001"), d("100000000"), 3, mode)) == "0.0313"
      end
    end

    test "keeps the sign" do
      assert plain(Precision.divide(d("-1"), d("3"), 3, :half_even)) == "-0.333"
      assert plain(Precision.divide(d("1"), d("-3"), 3, :half_even)) == "-0.333"
      assert plain(Precision.divide(d("-1"), d("-3"), 3, :half_even)) == "0.333"
    end

    test "zero divided by anything is zero" do
      assert Decimal.eq?(Precision.divide(d("0"), d("7"), 19, :up), 0)
    end
  end

  describe "negative zero" do
    test "normalize_zero drops the sign of a zero only" do
      assert Precision.normalize_zero(Decimal.new(-1, 0, -2)) == Decimal.new(1, 0, -2)
      assert Precision.normalize_zero(d("-1.5")) == d("-1.5")
    end

    test "money that rounds to zero is never negative" do
      usd = Currency.new("USD", 2)
      ctx = Context.new(:half_even)

      assert ECBMoney.to_string(ECBMoney.new(usd, "-0.001", ctx)) == "USD 0.00"
      assert ECBMoney.to_string(ECBMoney.times(ECBMoney.new(usd, "-2.50", ctx), 0)) == "USD 0.00"
      assert ECBMoney.to_string(ECBMoney.new(Currency.new("JPY", 0), "-0.4", ctx)) == "JPY 0"
    end
  end

  describe "multiplication at 19 digits, as in Fineract" do
    test "an exact product whose trailing digits are zero is not rounded up" do
      usd = Currency.new("USD", 2)
      ctx = Context.new(:up)

      # 999999999999.995 rounds UP to 1000000000000.00 first; times 3.2016064 is exactly 3201606400000.00
      money = ECBMoney.new(usd, "999999999999.995", ctx)
      assert ECBMoney.to_string(money) == "USD 1000000000000.00"
      assert ECBMoney.to_string(ECBMoney.times(money, "3.2016064")) == "USD 3201606400000.00"
    end
  end
end
