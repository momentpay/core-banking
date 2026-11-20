defmodule ECBDeposits.InterestChartsTest do
  use ExUnit.Case, async: true

  alias ECBDeposits.DepositProducts.TermChanges
  alias ECBDeposits.InterestCharts
  alias ECBPlatform.Validation

  defp slab(from, to, extra \\ %{}) do
    Map.merge(
      %{
        description: nil,
        period_type: 2,
        from_period: from,
        to_period: to,
        amount_from: nil,
        amount_to: nil,
        rate: Decimal.new(5)
      },
      extra
    )
  end

  defp codes(chart) do
    "fixeddepositproduct"
    |> Validation.new()
    |> InterestCharts.validate_slabs(chart)
    |> Map.fetch!(:errors)
    |> Enum.reverse()
    |> Enum.map(& &1.code)
  end

  defp by_period(slabs), do: %{grouping: false, slabs: slabs}

  describe "the slabs of a chart" do
    test "slabs that follow each other from the first month are fine" do
      assert codes(by_period([slab(1, 6), slab(7, 12), slab(13, nil)])) == []
    end

    test "the order the slabs are sent in does not matter" do
      assert codes(by_period([slab(7, 12), slab(1, 6)])) == []
    end

    test "a chart must start at 0 or 1" do
      assert codes(by_period([slab(2, 12)])) == [
               "validation.msg.fixeddepositproduct.chart.slabs.range.start.incorrect"
             ]
    end

    test "a missing month is a gap and a shared month an overlap" do
      assert codes(by_period([slab(1, 6), slab(8, 12)])) == [
               "validation.msg.savings.interestRateChart.slabs.gap"
             ]

      assert codes(by_period([slab(1, 6), slab(6, 12)])) == [
               "validation.msg.savings.interestRateChart.slabs.overlap"
             ]
    end

    test "all slabs count in one kind of period" do
      assert codes(by_period([slab(1, 6), slab(7, 12, %{period_type: 3})])) == [
               "validation.msg.fixeddepositproduct.periodType.period.type.is.not.same"
             ]
    end

    test "slabs by amount within a period follow without a gap" do
      amounts = fn from, to ->
        %{amount_from: Decimal.new(from), amount_to: to && Decimal.new(to)}
      end

      ok = by_period([slab(1, 6, amounts.(1, 1000)), slab(1, 6, amounts.(1001, nil))])
      assert codes(ok) == []

      gap = by_period([slab(1, 6, amounts.(1, 1000)), slab(1, 6, amounts.(2000, nil))])
      assert codes(gap) == ["validation.msg.savings.interestRateChart.slabs.gap"]
    end

    test "a chart grouped by amount needs the start of an amount in every slab" do
      blank = %{grouping: true, slabs: [slab(nil, nil, %{period_type: nil})]}
      assert "validation.msg.fixeddepositproduct.amountRangeFrom.cannot.be.blank" in codes(blank)
    end
  end

  describe "the dates of charts" do
    defp chart(from, to),
      do: %{from_date: Date.from_iso8601!(from), end_date: to && Date.from_iso8601!(to)}

    test "charts overlap when one starts or ends within the other" do
      today = ~D[2024-03-01]

      assert InterestCharts.dates_overlap?(
               chart("2024-01-01", "2024-06-30"),
               chart("2024-06-01", "2024-12-31"),
               today
             )

      refute InterestCharts.dates_overlap?(
               chart("2024-01-01", "2024-05-31"),
               chart("2024-06-01", "2024-12-31"),
               today
             )
    end

    test "each overlapping pair is a problem in both directions" do
      v = Validation.new("fixeddepositproduct")
      a = chart("2024-01-01", "2024-06-30")
      b = chart("2024-06-01", "2024-12-31")

      assert length(InterestCharts.validate_dates(v, [a, b], ~D[2024-03-01]).errors) == 2
    end

    test "the active chart is the last one unless an earlier one starts after the end of a later one" do
      first = Map.put(chart("2023-01-01", "2023-12-31"), :id, 1)
      second = Map.put(chart("2024-01-01", nil), :id, 2)

      assert InterestCharts.active([first, second]).id == 2
      # the one that starts after the end of the other stays
      assert InterestCharts.active([second, first]).id == 2
      assert InterestCharts.active([]) == nil
    end
  end

  test "a term is compared in days, a month counting 30 and a year 365" do
    assert TermChanges.days(2, 1) == 14
    assert TermChanges.days(1, 2) == 30
    assert TermChanges.days(1, 3) == 365
  end
end
