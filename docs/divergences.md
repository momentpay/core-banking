# Divergences from Apache Fineract

Every place where E-CoreBank deliberately behaves differently from the pinned Fineract release
(see [ADR-0001](adr/0001-follow-fineract-design.md)). An entry here is a decision, not an accident:
each one says what differs, why, and how it is checked.

## ecb_money

| # | Fineract | E-CoreBank | Why | Check |
|---|---|---|---|---|
| 1 | The rounding mode and 19-digit precision come from a per-tenant global held in `MoneyHelper` and read from thread-local tenant context | Passed explicitly as an `ECBMoney.Context` value on every call | No hidden state. A calculation always states its rounding. Same numeric results | Golden master: every case supplies its own context |
| 2 | `MathUtil.isLessThanOrEqualTo(first, null)` throws a null pointer | `ECBMoney.Math.less_than_or_equal?/2` reads a `nil` second value as zero | Harmless leniency; no caller depends on the exception | Unit test |
| 3 | `Money` has `double` overloads (`multipliedBy(double)`, `plus(double)`, ...) | Floats are rejected with `ArgumentError` | A float has already lost the digits a ledger needs | Unit test |
| 4 | No general allocator | `ECBMoney.allocate/2` (largest remainder) | Needed to split payments and charges without a rounding gap | Property tests |
| 5 | The currency is a `CurrencyData` object with a `displayLabel` | `ECBMoney.Currency` with `display_label/1` | Same label rules (name, then symbol in round brackets or code in square brackets) | Unit test |

No numeric result differs: the golden master requires identical text for 130,144 cases.
