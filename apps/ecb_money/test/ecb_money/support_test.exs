defmodule ECBMoney.SupportTest do
  use ExUnit.Case, async: true

  alias ECBMoney.{Context, Currency, DayCount, Math, Rounding}

  defp d(v), do: Decimal.new(v)
  defp ctx(mode \\ :half_even), do: Context.new(mode)

  describe "Rounding" do
    test "numbers modes as Fineract's configuration does (java.math.RoundingMode ordinals)" do
      assert Rounding.modes() == [:up, :down, :ceiling, :floor, :half_up, :half_down, :half_even]

      for {mode, int} <- Enum.with_index(Rounding.modes()) do
        assert Rounding.to_int(mode) == int
        assert Rounding.from_int(int) == mode
      end
    end

    test "the Fineract default is 6, half-even" do
      assert Rounding.from_int(6) == :half_even
      assert Rounding.default() == :half_even
    end

    test "rejects values outside 0..6, like Fineract" do
      for bad <- [-1, 7, 100, nil, "6", 6.0] do
        assert_raise ArgumentError, ~r/Invalid rounding mode value/, fn ->
          Rounding.from_int(bad)
        end
      end

      assert_raise ArgumentError, fn -> Rounding.to_int(:unnecessary) end
    end
  end

  describe "Context" do
    test "defaults to Fineract's 19 digits" do
      c = Context.new(:half_up)
      assert c.precision == 19 and c.rounding == :half_up
      assert Context.default_precision() == 19
    end

    test "builds from a configuration value" do
      assert Context.from_rounding_int(4).rounding == :half_up
      assert Context.from_rounding_int(6).rounding == :half_even
    end

    test "multiples rounding falls back to the main mode" do
      assert Context.multiples_rounding(ctx(:floor)) == :floor
      assert Context.multiples_rounding(Context.new(:floor, multiples_rounding: :up)) == :up
    end

    test "validates its inputs" do
      assert_raise ArgumentError, fn -> Context.new(:sideways) end
      assert_raise ArgumentError, fn -> Context.new(:up, precision: 0) end
      assert_raise ArgumentError, fn -> Context.new(:up, multiples_rounding: :nope) end
    end
  end

  describe "Currency" do
    test "validates code, decimal places and multiples" do
      assert %Currency{code: "USD", decimal_places: 2} = Currency.new("USD", 2)
      assert_raise ArgumentError, fn -> Currency.new("US", 2) end
      assert_raise ArgumentError, fn -> Currency.new("USD", -1) end
      assert_raise ArgumentError, fn -> Currency.new("USD", 2, in_multiples_of: -5) end
      assert Currency.new("XXX", 0, in_multiples_of: 0).in_multiples_of == 0
    end

    test "display label is the name and the symbol, or the code in brackets (as Fineract)" do
      assert Currency.display_label(
               Currency.new("USD", 2, name: "US Dollar", display_symbol: "$")
             ) == "US Dollar ($)"

      assert Currency.display_label(Currency.new("KES", 2, name: "Kenyan Shilling")) ==
               "Kenyan Shilling [KES]"

      assert Currency.display_label(
               Currency.new("KES", 2, name: "Kenyan Shilling", display_symbol: "  ")
             ) == "Kenyan Shilling [KES]"

      assert Currency.display_label(Currency.new("KES", 2)) == "[KES]"
    end
  end

  describe "Math (null-safe helpers from MathUtil)" do
    test "null handling" do
      assert Decimal.equal?(Math.null_to_zero(nil), 0)
      assert Decimal.equal?(Math.null_to_default(nil, d(5)), 5)
      assert Decimal.equal?(Math.null_to_default(d(3), d(5)), 3)
      assert Math.zero_to_null(d(0)) == nil
      assert Math.zero_to_null(nil) == nil
      assert Decimal.equal?(Math.zero_to_null(d(2)), 2)
      assert Decimal.equal?(Math.negative_to_zero(d(-2)), 0)
      assert Decimal.equal?(Math.negative_to_zero(nil), 0)
      assert Decimal.equal?(Math.negative_to_zero(d(2)), 2)
    end

    test "predicates" do
      assert Math.empty?(nil) and Math.empty?(d(0)) and not Math.empty?(d(1))

      assert Math.greater_than_zero?(d(1)) and not Math.greater_than_zero?(nil) and
               not Math.greater_than_zero?(d(0))

      assert Math.less_than_zero?(d(-1)) and not Math.less_than_zero?(nil)
      assert Math.zero?(d(0)) and not Math.zero?(nil)

      assert Math.less_than_or_equal_zero?(nil) and Math.less_than_or_equal_zero?(d(0)) and
               not Math.less_than_or_equal_zero?(d(1))

      assert Math.equal?(nil, d(0)) and Math.equal?(d("1.0"), d(1))
      assert Math.greater_than?(d(2), nil) and Math.less_than?(nil, d(1))
      assert Math.greater_than_or_equal?(nil, nil) and Math.less_than_or_equal?(d(1), d(1))
    end

    test "abs, min" do
      assert Decimal.equal?(Math.abs(d(-3)), 3)
      assert Decimal.equal?(Math.abs(nil), 0)
      assert Decimal.equal?(Math.min(d(1), d(2), true), 1)
      assert Decimal.equal?(Math.min(nil, d(2), true), 2)
      assert Decimal.equal?(Math.min(d(1), nil, true), 1)
      assert Math.min(nil, nil, true) == nil
      assert Math.min(nil, d(2), false) == nil
      assert Decimal.equal?(Math.min(d(-1), nil, false), -1)
    end

    test "add and subtract treat nil as absent" do
      assert Math.add(nil, nil, ctx()) == nil
      assert Decimal.equal?(Math.add(nil, d(2), ctx()), 2)
      assert Decimal.equal?(Math.add(d(1), nil, ctx()), 1)
      assert Decimal.equal?(Math.add(d(1), d(2), ctx()), 3)
      assert Decimal.equal?(Math.add_all([nil, d(1), nil, d(2)], ctx()), 3)
      assert Math.add_all([nil, nil], ctx()) == nil
      assert Math.subtract(nil, d(1), ctx()) == nil
      assert Decimal.equal?(Math.subtract(d(5), nil, ctx()), 5)
      assert Decimal.equal?(Math.subtract(d(5), d(7), ctx()), -2)
      assert Decimal.equal?(Math.subtract_to_zero(d(5), [d(2), d(4)], ctx()), 0)
      assert Decimal.equal?(Math.subtract_to_zero(d(5), [d(2)], ctx()), 3)
    end

    test "add rounds to the context's precision" do
      c = Context.new(:half_up, precision: 3)
      assert Decimal.equal?(Math.add(d("1.234"), d("0.002"), c), d("1.24"))
    end

    test "negate and normalize_amount" do
      assert Math.negate(nil, ctx()) == nil
      assert Decimal.equal?(Math.negate(d(0), ctx()), 0)
      assert Decimal.equal?(Math.negate(d(3), ctx()), -3)
      usd = Currency.new("USD", 2)
      assert Decimal.to_string(Math.normalize_amount(d("1.005"), usd, :half_even)) == "1.00"
      assert Decimal.to_string(Math.normalize_amount(d("1.005"), usd, :half_up)) == "1.01"
      assert Math.normalize_amount(nil, usd, :up) == nil
    end
  end

  describe "DayCount" do
    test "codes round trip, as in the Fineract API" do
      for {code, type} <- [{1, :actual}, {360, :days_360}, {364, :days_364}, {365, :days_365}] do
        assert DayCount.days_in_year_from_int(code) == type
        assert DayCount.days_in_year_to_int(type) == code
      end

      for {code, type} <- [{1, :actual}, {30, :days_30}] do
        assert DayCount.days_in_month_from_int(code) == type
        assert DayCount.days_in_month_to_int(type) == code
      end

      assert DayCount.days_in_year_from_int(7) == :invalid
      assert DayCount.days_in_year_from_int(nil) == :invalid
      assert DayCount.days_in_month_from_int(31) == :invalid
      assert DayCount.days_in_year_to_int(:invalid) == 0
    end

    test "days in year" do
      assert DayCount.days_in_year(:actual, ~D[2024-03-01]) == 366
      assert DayCount.days_in_year(:actual, ~D[2025-03-01]) == 365
      assert DayCount.days_in_year(:actual, ~D[1900-01-01]) == 365
      assert DayCount.days_in_year(:actual, ~D[2000-01-01]) == 366
      assert DayCount.days_in_year(:days_360, ~D[2024-03-01]) == 360
      assert DayCount.days_in_year(:days_364, ~D[2024-03-01]) == 364
      assert DayCount.days_in_year(:days_365, ~D[2024-03-01]) == 365
      assert DayCount.days_in_year(:actual, nil) == nil
    end

    test "days in month" do
      assert DayCount.days_in_month(:actual, ~D[2024-02-10]) == 29
      assert DayCount.days_in_month(:actual, ~D[2025-02-10]) == 28
      assert DayCount.days_in_month(:actual, ~D[2025-01-10]) == 31
      assert DayCount.days_in_month(:days_30, ~D[2025-01-10]) == 30
      assert DayCount.days_in_month(:actual, nil) == nil
    end

    test "custom strategies" do
      assert DayCount.custom_strategies() == [:full_leap_year, :feb_29_period_only]
    end
  end
end
