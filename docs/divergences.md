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

## ecb_platform: command pipeline

| # | Fineract | E-CoreBank | Why | Check |
|---|---|---|---|---|
| 1 | Failures are thrown as exceptions and mapped to HTTP responses by a global handler | `Commands.execute/3` returns `{:ok, result}` or `{:error, exception}` | A caller (API, job, test) decides what to do; no control flow by exception | Integration tests |
| 2 | Retry is automatic inside one request (Resilience4j) and reuses the stored command through a request attribute | `execute(..., retry: true)` continues the stored command found by its idempotency key | No request-scoped attributes; the caller says it is a retry | Integration test |
| 3 | Handlers are Spring beans looked up by name | `Commands.Handlers` registry (`register(entity, action, module)`) filled by each app at start | Explicit, compile-visible registration; no reflection | Unit tests |
| 4 | Post-command hooks publish webhook events through Spring's event publisher | A list of hook modules in `:command_hooks`; each gets `after_success/2` and `after_error/2` and cannot change the outcome | The event outbox and webhooks (ecb_events) plug in here | Integration test |
| 5 | A command's JSON may be sanitised (keys masked) before it is stored | **Not yet implemented**; `is_sanitized` is always false | Needed for password-bearing commands; arrives with user administration | Planned |
| 6 | A change of one's own user details skips maker-checker; updates are refused while the scheduler holds a lock | **Not yet implemented** | Arrive with user administration and ecb_batch | Planned |
| 7 | 1.16 adds a typed command framework with an `m_command` table | Not built; the legacy `m_portfolio_command_source` flow is what the API of 1.16 still uses for writes | Parity first; revisit when the typed framework is chosen (open question in the module document) | n/a |

No stored value differs: command rows, statuses, result codes and result JSON field names are Fineract's.
