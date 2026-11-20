defmodule ECBDeposits.DepositAccounts.MaturityTest do
  use ExUnit.Case, async: true

  alias ECBDeposits.DepositAccounts.Maturity

  defp slab(from, to, rate, extra \\ %{}) do
    Map.merge(
      %{
        period_type: 2,
        from_period: from,
        to_period: to,
        amount_from: nil,
        amount_to: nil,
        rate: Decimal.new(rate)
      },
      extra
    )
  end

  describe "when a term ends" do
    test "days, weeks, months and years are added to the start" do
      assert Maturity.date(~D[2024-03-01], 10, 0) == ~D[2024-03-11]
      assert Maturity.date(~D[2024-03-01], 2, 1) == ~D[2024-03-15]
      assert Maturity.date(~D[2024-03-01], 12, 2) == ~D[2025-03-01]
      assert Maturity.date(~D[2024-03-01], 2, 3) == ~D[2026-03-01]
    end

    test "a month that is shorter ends the term on its last day" do
      assert Maturity.date(~D[2024-01-31], 1, 2) == ~D[2024-02-29]
      assert Maturity.date(~D[2024-08-31], 6, 2) == ~D[2025-02-28]
    end

    test "a unit that is not known gives no date" do
      assert Maturity.date(~D[2024-03-01], 1, 9) == nil
    end
  end

  describe "whole units between two dates" do
    test "months are counted in full, by the day of the month" do
      assert Maturity.between(~D[2024-03-01], ~D[2025-03-01], 2) == 12
      assert Maturity.between(~D[2024-03-15], ~D[2024-04-14], 2) == 0
      assert Maturity.between(~D[2024-03-15], ~D[2024-04-15], 2) == 1
    end

    test "weeks, years and days" do
      assert Maturity.between(~D[2024-03-01], ~D[2024-03-16], 1) == 2
      assert Maturity.between(~D[2024-03-01], ~D[2026-02-28], 3) == 1
      assert Maturity.between(~D[2024-03-01], ~D[2024-03-11], 0) == 10
    end
  end

  describe "the rate of a chart" do
    test "is that of the slab the term falls in" do
      slabs = [slab(1, 12, 6), slab(13, nil, 7)]

      assert Decimal.eq?(
               Maturity.rate(slabs, Decimal.new(1000), ~D[2024-03-01], ~D[2025-03-01]),
               6
             )

      assert Decimal.eq?(
               Maturity.rate(slabs, Decimal.new(1000), ~D[2024-03-01], ~D[2026-03-01]),
               7
             )
    end

    test "is zero when no slab fits" do
      slabs = [slab(6, 12, 6)]

      assert Decimal.eq?(
               Maturity.rate(slabs, Decimal.new(1000), ~D[2024-03-01], ~D[2024-04-01]),
               0
             )
    end

    test "also asks for the amount when the slab has a range" do
      slabs = [
        slab(1, 12, 5, %{amount_from: Decimal.new(1), amount_to: Decimal.new(1000)}),
        slab(1, 12, 6, %{amount_from: Decimal.new(1001), amount_to: nil})
      ]

      assert Decimal.eq?(
               Maturity.rate(slabs, Decimal.new(500), ~D[2024-03-01], ~D[2025-03-01]),
               5
             )

      assert Decimal.eq?(
               Maturity.rate(slabs, Decimal.new(5000), ~D[2024-03-01], ~D[2025-03-01]),
               6
             )
    end
  end
end
