defmodule ECBDeposits.Savings.Interest.CalcTest do
  use ExUnit.Case, async: true

  alias ECBDeposits.Savings.Interest.Calc

  # The expected amounts are what Fineract 1.16.1 posted for the same account (the scenario `savingsint1`).

  defp d(text), do: Date.from_iso8601!(text)

  defp tx(id, date, amount, type),
    do: %{id: id, date: d(date), amount: Decimal.new(amount), type: type}

  # 2000 in on 15 January 2024, 300 out on 20 February, 700 in on 5 March, 100 in on 20 July
  defp account_txs do
    [
      tx(1, "2024-01-15", "2000", 1),
      tx(2, "2024-02-20", "300", 2),
      tx(3, "2024-03-05", "700", 1),
      tx(4, "2024-07-20", "100", 1)
    ]
  end

  defp settings(overrides) do
    Map.merge(
      %{
        start: d("2024-01-15"),
        up_to: d("2025-02-10"),
        posting_type: 4,
        compounding_type: 1,
        calculation_type: 1,
        days_in_year: 365,
        rate: Decimal.new("0.10"),
        overdraft_rate: Decimal.new(0),
        min_balance: Decimal.new(0),
        min_overdraft: Decimal.new(0),
        decimals: 2,
        allow_overdraft: false,
        fy_begin: 1,
        at_period_end: false,
        as_on: [],
        business_date: d("2025-02-10")
      },
      overrides
    )
  end

  defp run(overrides, txs \\ account_txs()) do
    p = settings(overrides)
    p = Map.put(p, :txs, Calc.balances(txs, p.up_to))

    p
    |> Calc.periods()
    |> Enum.map(&{Date.to_iso8601(&1.posting_date), Decimal.to_string(&1.interest)})
  end

  test "daily compounding, monthly posting, daily balance" do
    assert run(%{}) |> Enum.take(5) == [
             {"2024-02-01", "9.34"},
             {"2024-03-01", "15.20"},
             {"2024-04-01", "19.90"},
             {"2024-05-01", "20.17"},
             {"2024-06-01", "21.02"}
           ]
  end

  test "monthly compounding, quarterly posting, 360 days in the year" do
    assert run(%{
             rate: Decimal.new("0.10"),
             compounding_type: 4,
             posting_type: 5,
             days_in_year: 360
           }) ==
             [
               {"2024-04-01", "44.90"},
               {"2024-07-01", "62.32"},
               {"2024-10-01", "66.66"},
               {"2025-01-01", "68.92"},
               {"2025-04-01", "31.30"}
             ]
  end

  test "quarterly compounding with the average daily balance, biannual posting" do
    assert run(%{
             rate: Decimal.new("0.09"),
             compounding_type: 5,
             posting_type: 6,
             calculation_type: 2
           }) ==
             [{"2024-07-01", "94.34"}, {"2025-01-01", "118.56"}, {"2025-07-01", "27.43"}]
  end

  test "biannual compounding, annual posting" do
    assert run(%{rate: Decimal.new("0.08"), compounding_type: 6, posting_type: 7}) ==
             [{"2025-01-01", "186.82"}, {"2026-01-01", "24.14"}]
  end

  test "annual compounding with the average daily balance, annual posting, 360 days" do
    assert run(%{
             rate: Decimal.new("0.075"),
             compounding_type: 7,
             posting_type: 7,
             calculation_type: 2,
             days_in_year: 360
           }) == [{"2025-01-01", "174.40"}, {"2026-01-01", "22.84"}]
  end

  test "anniversary postings come on the day of the month the account began" do
    assert run(%{rate: Decimal.new("0.06"), posting_type: 8}) |> Enum.take(3) == [
             {"2024-02-15", "10.22"},
             {"2024-03-15", "9.57"},
             {"2024-04-15", "12.36"}
           ]

    assert run(%{rate: Decimal.new("0.12"), compounding_type: 4, posting_type: 9}) |> Enum.take(3) ==
             [{"2024-04-15", "64.50"}, {"2024-07-15", "74.47"}, {"2024-10-15", "80.46"}]
  end

  test "a balance under the minimum earns nothing" do
    # 2000 in the account earns, with a minimum of 3000 it does not
    assert run(%{min_balance: Decimal.new(3000), posting_type: 4}) |> Enum.take(2) ==
             [{"2024-02-01", "0.00"}, {"2024-03-01", "0.00"}]
  end

  test "an account overdrawn owes interest at the overdraft rate" do
    txs = [tx(1, "2024-03-01", "100", 1), tx(2, "2024-03-01", "300", 2)]

    [{"2024-04-01", owed}] =
      run(
        %{
          start: d("2024-03-01"),
          up_to: d("2024-03-31"),
          overdraft_rate: Decimal.new("0.18"),
          allow_overdraft: true,
          compounding_type: 1,
          posting_type: 4
        },
        txs
      )

    assert Decimal.lt?(Decimal.new(owed), 0)
  end

  test "running balances and end-of-day balances" do
    txs = [
      tx(1, "2024-03-01", "100", 1),
      tx(2, "2024-03-01", "300", 2),
      tx(3, "2024-03-10", "50", 1)
    ]

    assert Enum.map(Calc.running(txs), &Decimal.to_string(elem(&1, 1))) == ["100", "-200", "-150"]

    balances = Calc.balances(txs, d("2024-03-20"))
    # the first transaction of a day that has another after it holds its balance for no days
    assert Enum.map(balances, & &1.days) == [0, 9, 11]

    assert Enum.map(balances, &Date.to_iso8601(&1.end_date)) == [
             "2024-03-01",
             "2024-03-09",
             "2024-03-20"
           ]
  end

  test "how much of each transaction was taken from or paid into an overdrawn account" do
    txs = [
      tx(1, "2024-03-01", "100", 1),
      tx(2, "2024-03-01", "300", 2),
      tx(3, "2024-03-10", "250", 1)
    ]

    over = Calc.overdrafts(txs)
    assert Decimal.eq?(over[1], 0)
    assert Decimal.eq?(over[2], 200)
    assert Decimal.eq?(over[3], 200)
  end
end
