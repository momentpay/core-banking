# ecb_money

Exact money for E-CoreBank: currency, `Money`, rounding modes, math context and day-count types.
A pure library: no database, no clock, no configuration. It follows Apache Fineract's `Money` class
operation by operation, and is checked against Fineract's own class on 130,144 generated cases.

```elixir
usd = ECBMoney.Currency.new("USD", 2)
ctx = ECBMoney.Context.from_rounding_int(6)          # Fineract's rounding-mode setting; 6 = half-even

ECBMoney.new(usd, "10.005", ctx) |> to_string()        #=> "USD 10.00"
ECBMoney.new(usd, "1000.00", ctx) |> ECBMoney.percentage_of("12.5") |> to_string()   #=> "USD 125.00"
ECBMoney.allocate(ECBMoney.new(usd, "100.00", ctx), [1, 1, 1]) |> Enum.map(&to_string/1)
#=> ["USD 33.34", "USD 33.33", "USD 33.33"]
```

See the [module document](../../docs/modules/ecb_money.md). To refresh the golden master after moving to
a new Fineract version: `parity/scripts/gen-money-golden.sh`.
