defmodule ECBDeposits.Savings.Interest.PeriodsTest do
  use ExUnit.Case, async: true

  alias ECBDeposits.Savings.Interest.Periods

  defp d(text), do: Date.from_iso8601!(text)
  defp spans(list), do: Enum.map(list, fn {a, b} -> {Date.to_iso8601(a), Date.to_iso8601(b)} end)

  describe "posting periods" do
    test "monthly: each calendar month, the first one from the day interest begins" do
      assert spans(Periods.posting_periods(d("2024-01-15"), d("2024-03-20"), 4, 1, [])) == [
               {"2024-01-15", "2024-01-31"},
               {"2024-02-01", "2024-02-29"},
               {"2024-03-01", "2024-03-31"}
             ]
    end

    test "quarterly and biannual follow the financial year" do
      assert spans(Periods.posting_periods(d("2024-01-15"), d("2024-08-01"), 5, 1, [])) == [
               {"2024-01-15", "2024-03-31"},
               {"2024-04-01", "2024-06-30"},
               {"2024-07-01", "2024-09-30"}
             ]

      assert spans(Periods.posting_periods(d("2024-01-15"), d("2024-08-01"), 6, 1, [])) == [
               {"2024-01-15", "2024-06-30"},
               {"2024-07-01", "2024-12-31"}
             ]

      # a financial year that begins in April ends the quarters in June, September, December and March
      assert spans(Periods.posting_periods(d("2024-01-15"), d("2024-05-01"), 5, 4, [])) == [
               {"2024-01-15", "2024-03-31"},
               {"2024-04-01", "2024-06-30"}
             ]
    end

    test "annual ends with the financial year" do
      assert spans(Periods.posting_periods(d("2024-03-10"), d("2025-02-10"), 7, 1, [])) == [
               {"2024-03-10", "2024-12-31"},
               {"2025-01-01", "2025-12-31"}
             ]
    end

    test "anniversary periods keep the day of the month the account began, as far as the month allows" do
      assert spans(Periods.posting_periods(d("2024-01-15"), d("2024-04-20"), 8, 1, [])) == [
               {"2024-01-15", "2024-02-14"},
               {"2024-02-15", "2024-03-14"},
               {"2024-03-15", "2024-04-14"},
               {"2024-04-15", "2024-05-14"}
             ]

      assert spans(Periods.posting_periods(d("2024-01-31"), d("2024-03-31"), 8, 1, [])) == [
               {"2024-01-31", "2024-02-28"},
               {"2024-02-29", "2024-03-30"},
               {"2024-03-31", "2024-04-29"}
             ]

      assert spans(Periods.posting_periods(d("2024-01-15"), d("2024-10-20"), 9, 1, [])) == [
               {"2024-01-15", "2024-04-14"},
               {"2024-04-15", "2024-07-14"},
               {"2024-07-15", "2024-10-14"},
               {"2024-10-15", "2025-01-14"}
             ]
    end

    test "a manual posting ends the period it falls in the day before" do
      assert spans(
               Periods.posting_periods(d("2024-03-25"), d("2024-05-02"), 4, 1, [d("2024-04-15")])
             ) == [
               {"2024-03-25", "2024-03-31"},
               {"2024-04-01", "2024-04-14"},
               {"2024-04-15", "2024-04-30"},
               {"2024-05-01", "2024-05-31"}
             ]
    end

    test "nothing without a start, an end or a type" do
      assert Periods.posting_periods(nil, d("2024-01-01"), 4, 1, []) == []
      assert Periods.posting_periods(d("2024-01-01"), nil, 4, 1, []) == []
      assert Periods.posting_periods(d("2024-01-01"), d("2024-02-01"), nil, 1, []) == []
    end
  end

  describe "compounding periods" do
    test "daily compounding is one period over the posting period" do
      assert spans(
               Periods.compounding_periods(
                 {d("2024-01-15"), d("2024-01-31")},
                 1,
                 1,
                 d("2024-02-01")
               )
             ) ==
               [{"2024-01-15", "2024-01-31"}]
    end

    test "monthly, quarterly and annual compounding periods lie wholly inside the posting period" do
      posting = {d("2024-01-01"), d("2024-06-30")}

      assert spans(Periods.compounding_periods(posting, 4, 1, d("2024-07-01"))) ==
               for(
                 m <- 1..6,
                 do: {"2024-0#{m}-01", Date.to_iso8601(Date.end_of_month(Date.new!(2024, m, 1)))}
               )

      assert spans(Periods.compounding_periods(posting, 5, 1, d("2024-07-01"))) ==
               [{"2024-01-01", "2024-03-31"}, {"2024-04-01", "2024-06-30"}]

      assert spans(
               Periods.compounding_periods(
                 {d("2024-03-10"), d("2024-12-31")},
                 7,
                 1,
                 d("2025-01-01")
               )
             ) ==
               [{"2024-03-10", "2024-12-31"}]
    end
  end
end
