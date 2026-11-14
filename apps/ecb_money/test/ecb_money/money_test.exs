defmodule ECBMoneyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ECBMoney.{Context, Currency}
  alias ECBMoney.CurrencyMismatchError

  doctest ECBMoney

  @usd Currency.new("USD", 2)
  @jpy Currency.new("JPY", 0)
  @kwd Currency.new("KWD", 3)
  @five Currency.new("XXX", 0, in_multiples_of: 5)

  defp ctx(mode \\ :half_even), do: Context.new(mode)
  defp usd(amount, mode \\ :half_even), do: ECBMoney.new(@usd, amount, ctx(mode))
  defp str(money), do: ECBMoney.to_string(money)
  defp d(value), do: Decimal.new(value)

  describe "rounding at construction (Java RoundingMode semantics, 0 decimal places)" do
    # Expected values for the classic tie table: 5.5, 2.5, 1.6, 1.1, 1.0, -1.0, -1.1, -1.6, -2.5, -5.5
    @table [
      {"5.5", %{up: 6, down: 5, ceiling: 6, floor: 5, half_up: 6, half_down: 5, half_even: 6}},
      {"2.5", %{up: 3, down: 2, ceiling: 3, floor: 2, half_up: 3, half_down: 2, half_even: 2}},
      {"1.6", %{up: 2, down: 1, ceiling: 2, floor: 1, half_up: 2, half_down: 2, half_even: 2}},
      {"1.1", %{up: 2, down: 1, ceiling: 2, floor: 1, half_up: 1, half_down: 1, half_even: 1}},
      {"1.0", %{up: 1, down: 1, ceiling: 1, floor: 1, half_up: 1, half_down: 1, half_even: 1}},
      {"-1.0",
       %{up: -1, down: -1, ceiling: -1, floor: -1, half_up: -1, half_down: -1, half_even: -1}},
      {"-1.1",
       %{up: -2, down: -1, ceiling: -1, floor: -2, half_up: -1, half_down: -1, half_even: -1}},
      {"-1.6",
       %{up: -2, down: -1, ceiling: -1, floor: -2, half_up: -2, half_down: -2, half_even: -2}},
      {"-2.5",
       %{up: -3, down: -2, ceiling: -2, floor: -3, half_up: -3, half_down: -2, half_even: -2}},
      {"-5.5",
       %{up: -6, down: -5, ceiling: -5, floor: -6, half_up: -6, half_down: -5, half_even: -6}}
    ]

    for {input, expected} <- @table, {mode, result} <- expected do
      test "#{input} with #{mode} gives #{result}" do
        money = ECBMoney.new(@jpy, unquote(input), ctx(unquote(mode)))
        assert Decimal.equal?(ECBMoney.amount(money), unquote(result))
      end
    end
  end

  describe "new/3" do
    test "rounds to the currency's decimal places" do
      assert str(usd("10.005")) == "USD 10.00"
      assert str(usd("10.015")) == "USD 10.02"
      assert str(usd("10.0051", :half_up)) == "USD 10.01"
      assert str(ECBMoney.new(@kwd, "1.23456", ctx())) == "KWD 1.235"
    end

    test "pads to the currency's scale" do
      assert str(usd("12.5")) == "USD 12.50"
      assert str(usd(7)) == "USD 7.00"
      assert str(ECBMoney.new(@jpy, "1E+3", ctx())) == "JPY 1000"
    end

    test "nil is zero" do
      assert ECBMoney.zero?(usd(nil))
      assert str(usd(nil)) == "USD 0.00"
    end

    test "accepts decimals, integers and numeric strings" do
      assert str(usd(Decimal.new("3.14159"))) == "USD 3.14"
      assert str(usd(3)) == "USD 3.00"
      assert str(usd("3.14159")) == "USD 3.14"
    end

    test "refuses floats" do
      assert_raise ArgumentError, ~r/floats are not accepted/, fn -> usd(1.5) end

      assert_raise ArgumentError, ~r/floats are not accepted/, fn ->
        usd("1") |> ECBMoney.plus(0.1)
      end
    end

    test "refuses NaN and infinity" do
      assert_raise ArgumentError, fn -> usd(Decimal.new("NaN")) end
      assert_raise ArgumentError, fn -> usd(Decimal.new("Infinity")) end
    end
  end

  describe "currencies in multiples of" do
    # decimal_places 0 and multiples of 5: amounts snap to 0, 5, 10, ...
    test "round positive amounts to a multiple" do
      assert str(ECBMoney.new(@five, "7.4", ctx())) == "XXX 5"
      assert str(ECBMoney.new(@five, "7.5", ctx())) == "XXX 10"
      assert str(ECBMoney.new(@five, "12.5", ctx())) == "XXX 10"
      assert str(ECBMoney.new(@five, "12.5", ctx(:half_up))) == "XXX 15"
      assert str(ECBMoney.new(@five, "12.5", ctx(:half_down))) == "XXX 10"
      assert str(ECBMoney.new(@five, "11", ctx(:up))) == "XXX 15"
      assert str(ECBMoney.new(@five, "14", ctx(:down))) == "XXX 10"
    end

    test "leave zero and negative amounts to the plain scale rule, as Fineract does" do
      assert str(ECBMoney.new(@five, "0", ctx())) == "XXX 0"
      assert str(ECBMoney.new(@five, "-7", ctx())) == "XXX -7"
    end

    test "only apply when decimal places are 0" do
      cur = Currency.new("YYY", 2, in_multiples_of: 5)
      assert str(ECBMoney.new(cur, "7.123", ctx())) == "YYY 7.12"
    end

    test "can use a different mode for the multiples step than for the scale" do
      context = Context.new(:half_even, multiples_rounding: :half_up)
      assert str(ECBMoney.new(@five, "12.5", context)) == "XXX 15"
    end

    test "round_to_multiples_of handles negatives with mirrored modes" do
      assert str(ECBMoney.new(@jpy, "-12", ctx()) |> ECBMoney.round_to_multiples_of(5)) ==
               "JPY -10"

      assert str(ECBMoney.new(@jpy, "-13", ctx(:floor)) |> ECBMoney.round_to_multiples_of(5)) ==
               "JPY -15"

      assert str(ECBMoney.new(@jpy, "-13", ctx(:ceiling)) |> ECBMoney.round_to_multiples_of(5)) ==
               "JPY -10"

      assert str(ECBMoney.new(@jpy, "13", ctx()) |> ECBMoney.round_to_multiples_of(0)) == "JPY 13"
    end
  end

  describe "plus and minus" do
    test "add exactly, then round" do
      assert str(ECBMoney.plus(usd("10.00"), usd("0.01"))) == "USD 10.01"
      assert str(ECBMoney.plus(usd("10.00"), "0.015")) == "USD 10.02"
      assert str(ECBMoney.minus(usd("10.00"), "0.005")) == "USD 10.00"
      assert str(ECBMoney.minus(usd("10.00"), usd("12.50"))) == "USD -2.50"
    end

    test "nil changes nothing; zero returns the very same value" do
      m = usd("5")
      assert ECBMoney.plus(m, nil) == m
      assert ECBMoney.minus(m, nil) == m
      assert ECBMoney.plus(m, 0) == m
      assert ECBMoney.minus(m, "0.00") == m
    end

    test "take the context given, otherwise the left operand's" do
      assert ECBMoney.plus(usd("1.00", :half_up), "0.005").amount |> Decimal.to_string() == "1.01"

      assert ECBMoney.plus(usd("1.00", :half_up), "0.005", ctx(:half_even)).amount
             |> Decimal.to_string() == "1.00"
    end

    test "mixing currencies raises" do
      assert_raise CurrencyMismatchError, ~r/USD and JPY/, fn ->
        ECBMoney.plus(usd("1"), ECBMoney.new(@jpy, 1, ctx()))
      end

      assert_raise CurrencyMismatchError, fn ->
        ECBMoney.minus(usd("1"), ECBMoney.new(@jpy, 1, ctx()))
      end
    end

    test "total sums a non-empty list and refuses an empty one" do
      assert str(ECBMoney.total([usd("1.10"), usd("2.20"), usd("3.30")])) == "USD 6.60"
      assert_raise ArgumentError, ~r/must not be empty/, fn -> ECBMoney.total([]) end
    end
  end

  describe "times, divide, percentage_of" do
    test "multiply and round at each step" do
      assert str(ECBMoney.times(usd("10.00"), "0.125")) == "USD 1.25"
      assert str(ECBMoney.times(usd("10.00"), "0.0125")) == "USD 0.12"
      assert str(ECBMoney.times(usd("10.00"), "0.0125", ctx(:half_up))) == "USD 0.13"
      assert str(ECBMoney.times(usd("33.33"), 3)) == "USD 99.99"
    end

    test "multiplying or dividing by 1 returns the value untouched" do
      m = usd("42.42", :half_up)
      assert ECBMoney.times(m, 1, ctx(:down)) == m
      assert ECBMoney.divide(m, 1, ctx(:down)) == m
    end

    test "divide rounds to the currency scale" do
      assert str(ECBMoney.divide(usd("10.00"), 3)) == "USD 3.33"
      assert str(ECBMoney.divide(usd("20.00"), 3)) == "USD 6.67"
      assert str(ECBMoney.divide(usd("1.00"), 8, ctx(:half_up))) == "USD 0.13"
      assert str(ECBMoney.divide(usd("1.00"), 8)) == "USD 0.12"
    end

    test "division by zero raises" do
      assert_raise ArithmeticError, ~r/Division by zero/, fn -> ECBMoney.divide(usd("1"), 0) end
    end

    test "percentage_of" do
      assert str(ECBMoney.percentage_of(usd("1000.00"), "12.5")) == "USD 125.00"
      assert str(ECBMoney.percentage_of(usd("19.99"), "7.5")) == "USD 1.50"
      assert str(ECBMoney.percentage_of(usd("0.01"), "50")) == "USD 0.00"
      assert str(ECBMoney.percentage_of(usd("0.01"), "50", ctx(:half_up))) == "USD 0.01"
    end

    test "multiply_retain_scale matches times for ordinary currencies" do
      for factor <- ["0.125", "0.0125", "3", "1.005"] do
        assert ECBMoney.multiply_retain_scale(usd("10.00"), factor) ==
                 ECBMoney.times(usd("10.00"), factor)
      end
    end

    test "each step rounds, so a chain differs from one exact calculation" do
      stepwise = usd("10.00") |> ECBMoney.times("0.333") |> ECBMoney.times("3")
      single = ECBMoney.times(usd("10.00"), "0.999")
      assert str(stepwise) == "USD 9.99"
      assert str(single) == "USD 9.99"
      # 10.00 x 0.0049 = 0.049, which rounds to 0.05 before the next step: 0.05 x 100 = 5.00,
      # whereas one exact step (10.00 x 0.49) gives 4.90.
      stepwise = usd("10.00") |> ECBMoney.times("0.0049") |> ECBMoney.times("100")
      assert str(stepwise) == "USD 5.00"
      assert str(ECBMoney.times(usd("10.00"), "0.49")) == "USD 4.90"
    end
  end

  describe "sign and comparison" do
    test "negate and abs" do
      assert str(ECBMoney.negate(usd("5"))) == "USD -5.00"
      assert ECBMoney.negate(usd("0")) == usd("0")
      assert str(ECBMoney.abs(usd("-5"))) == "USD 5.00"
      assert str(ECBMoney.abs(usd("5"))) == "USD 5.00"
    end

    test "predicates" do
      assert ECBMoney.zero?(usd("0.004"))
      assert ECBMoney.positive?(usd("0.01"))
      assert ECBMoney.negative?(usd("-0.01"))
      assert ECBMoney.equal?(usd("1"), usd("1.00"))
      assert ECBMoney.greater_than?(usd("2"), usd("1"))
      assert ECBMoney.greater_than_or_equal?(usd("2"), usd("2"))
      assert ECBMoney.less_than?(usd("1"), usd("2"))
      assert ECBMoney.less_than_or_equal?(usd("2"), usd("2"))
      assert ECBMoney.not_equal?(usd("1"), usd("2"))
    end

    test "comparing across currencies raises" do
      assert_raise CurrencyMismatchError, fn ->
        ECBMoney.compare(usd("1"), ECBMoney.new(@jpy, 1, ctx()))
      end
    end

    test "amount_or_nil_if_zero" do
      assert ECBMoney.amount_or_nil_if_zero(usd("0")) == nil
      assert Decimal.equal?(ECBMoney.amount_or_nil_if_zero(usd("1.5")), d("1.5"))
    end
  end

  describe "allocate/2" do
    test "splits without losing a cent" do
      shares = ECBMoney.allocate(usd("100.00"), [1, 1, 1])
      assert Enum.map(shares, &str/1) == ["USD 33.34", "USD 33.33", "USD 33.33"]
      assert str(ECBMoney.total(shares)) == "USD 100.00"
    end

    test "respects proportions" do
      shares = ECBMoney.allocate(usd("10.00"), [70, 20, 10])
      assert Enum.map(shares, &str/1) == ["USD 7.00", "USD 2.00", "USD 1.00"]
    end

    test "gives leftover cents to the largest remainders, ties to the earlier ratio" do
      shares = ECBMoney.allocate(usd("0.05"), [3, 7])
      assert Enum.map(shares, &str/1) == ["USD 0.02", "USD 0.03"]

      assert Enum.map(ECBMoney.allocate(usd("0.02"), [1, 1, 1]), &str/1) == [
               "USD 0.01",
               "USD 0.01",
               "USD 0.00"
             ]
    end

    test "handles negative amounts, zero ratios, decimal ratios and zero-decimal currencies" do
      assert Enum.map(ECBMoney.allocate(usd("-10.00"), [1, 2]), &str/1) == [
               "USD -3.33",
               "USD -6.67"
             ]

      assert Enum.map(ECBMoney.allocate(usd("10.00"), [0, 1]), &str/1) == [
               "USD 0.00",
               "USD 10.00"
             ]

      assert Enum.map(ECBMoney.allocate(usd("10.00"), ["0.5", "0.5"]), &str/1) == [
               "USD 5.00",
               "USD 5.00"
             ]

      assert Enum.map(ECBMoney.allocate(ECBMoney.new(@jpy, 10, ctx()), [1, 1, 1]), &str/1) == [
               "JPY 4",
               "JPY 3",
               "JPY 3"
             ]

      assert Enum.map(ECBMoney.allocate(ECBMoney.new(@five, 25, ctx()), [1, 1]), &str/1) == [
               "XXX 15",
               "XXX 10"
             ]
    end

    test "refuses bad ratios" do
      assert_raise ArgumentError, fn -> ECBMoney.allocate(usd("1"), [1, -1]) end
      assert_raise ArgumentError, fn -> ECBMoney.allocate(usd("1"), [0, 0]) end
      assert_raise FunctionClauseError, fn -> ECBMoney.allocate(usd("1"), []) end
    end
  end

  describe "display" do
    test "to_string, String.Chars and Inspect" do
      assert str(usd("1234.5")) == "USD 1234.50"
      assert "#{usd("1.00")}" == "USD 1.00"
      assert inspect(usd("1.00")) == "#ECBMoney<USD 1.00>"
    end
  end

  describe "properties" do
    property "construction is idempotent: rebuilding from the rounded amount changes nothing" do
      check all(amount <- decimal_gen(), mode <- mode_gen()) do
        money = ECBMoney.new(@usd, amount, ctx(mode))
        assert ECBMoney.new(@usd, money.amount, ctx(mode)) == money
      end
    end

    property "the result always has the currency's scale" do
      check all(
              amount <- decimal_gen(),
              mode <- mode_gen(),
              currency <- member_of([@usd, @jpy, @kwd])
            ) do
        money = ECBMoney.new(currency, amount, ctx(mode))
        assert money.amount.exp == -currency.decimal_places
      end
    end

    property "addition is commutative and associative for same-context money" do
      check all(a <- decimal_gen(), b <- decimal_gen(), c <- decimal_gen()) do
        [x, y, z] = Enum.map([a, b, c], &usd/1)
        assert ECBMoney.plus(x, y) == ECBMoney.plus(y, x)
        assert ECBMoney.plus(ECBMoney.plus(x, y), z) == ECBMoney.plus(x, ECBMoney.plus(y, z))
      end
    end

    property "plus then minus returns the original" do
      check all(a <- decimal_gen(), b <- decimal_gen()) do
        x = usd(a)
        y = usd(b)
        assert ECBMoney.minus(ECBMoney.plus(x, y), y) == x
      end
    end

    property "negating twice gives the original" do
      check all(a <- decimal_gen()) do
        x = usd(a)
        assert ECBMoney.negate(ECBMoney.negate(x)) == x
      end
    end

    property "allocation always sums to the original and never loses or invents a unit" do
      check all(
              amount <- decimal_gen(),
              ratios <- list_of(integer(0..1000), min_length: 1, max_length: 8),
              Enum.sum(ratios) > 0
            ) do
        money = usd(amount)
        shares = ECBMoney.allocate(money, ratios)
        assert length(shares) == length(ratios)
        assert ECBMoney.total(shares) == money
        assert Enum.all?(shares, &(&1.amount.exp == -2))
        # no share is further than one cent from its exact proportion
        total = Enum.sum(ratios)

        for {share, ratio} <- Enum.zip(shares, ratios) do
          exact = Decimal.div(Decimal.mult(money.amount, ratio), total)
          diff = share.amount |> Decimal.sub(exact) |> Decimal.abs()
          assert Decimal.lt?(diff, Decimal.new("0.01"))
        end
      end
    end

    property "allocation works the same in a whole-unit currency in multiples of 5" do
      check all(
              units <- integer(0..100_000),
              ratios <- list_of(integer(0..50), min_length: 1, max_length: 6),
              Enum.sum(ratios) > 0
            ) do
        money = ECBMoney.new(@five, units * 5, ctx())
        shares = ECBMoney.allocate(money, ratios)
        assert ECBMoney.total(shares) == money
        assert Enum.all?(shares, &(rem(Decimal.to_integer(&1.amount), 5) == 0))
      end
    end
  end

  defp decimal_gen do
    gen all(units <- integer(-100_000_000..100_000_000), extra <- integer(0..9)) do
      # a value with up to 3 decimal places, so ties and sub-cent digits occur
      Decimal.new(units * 10 + extra) |> Decimal.div(1000)
    end
  end

  defp mode_gen, do: member_of(ECBMoney.Rounding.modes())
end
