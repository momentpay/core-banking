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
| 5 | A command's JSON may be sanitised (keys masked) before it is stored | Built for the `USER` commands: `password` and `repeatPassword` are stored as `***` and the row is marked sanitized. A sanitized command **cannot be approved later** from its stored copy | The secret must never be written; Fineract's own approval of such a command would run with the masked value | `SanitizerTest`, `AdministrationWriteTest` |
| 6 | A change of one's own user details skips maker-checker; updates are refused while the scheduler holds a lock | **Not yet implemented** | Arrive with ecb_batch | Planned |
| 7 | 1.16 adds a typed command framework with an `m_command` table | Not built; the legacy `m_portfolio_command_source` flow is what the API of 1.16 still uses for writes | Parity first; revisit when the typed framework is chosen (open question in the module document) | n/a |

No stored value differs: command rows, statuses, result codes and result JSON field names are Fineract's.

## ecb_api_fineract

| # | Fineract | E-CoreBank | Why | Check |
|---|---|---|---|---|
| 1 | Unknown or unbuilt paths are answered by the web container (404) | An operation that Fineract has but E-CoreBank has not built yet answers **HTTP 501** with a platform error | A client can tell "not built" from "does not exist"; the deferred operations in the cut list answer the same way | API test, contract probe (reported as a status difference) |
| 2 | JSON objects list their fields in Fineract's class order | Fields are written in alphabetical order (the order Jason gives a map) | JSON object order carries no meaning and clients do not depend on it | Contract probe compares shape, not order |
| 3 | Passwords of new users are written as `{bcrypt}` | The same: `{bcrypt}$2a$10$...`. The legacy `{SHA-256}{salt}hash` is still checked, for the seeded users | Same format, so Fineract can read what E-CoreBank writes and the reverse | `AdministrationWriteTest` |
| 4 | `shouldRenewPassword` and two-factor reflect the user's state | Both are always false for now | Two-factor authentication and password expiry arrive later | Planned |
| 5 | The default tenant timezone and business date set a new office's default opening date | `GET /offices/template` uses today's UTC date | Business date arrives with ecb_platform part 2 | Planned |
| 6 | `orderBy=nameDecorated` on offices sorts by the decorated name | Sorts by the plain name | Same order for every real hierarchy of names; rarely used | Planned |
| 7 | The permission lists are ordered by the database collation | Sorted in byte (C) order explicitly | Makes the order identical on every PostgreSQL installation | Fixture test |
| 8 | A create or update of an office or fund whose name is in use answers a generic data-integrity error when Fineract runs on PostgreSQL (its constraint-name check expects MySQL names) | The specific message (`error.msg.office.duplicate.name`, `...duplicate.externalId`, `error.msg.fund.duplicate.name`) | That is what Fineract intends and what it answers on MySQL; clients can show the real reason | `ReferenceWriteTest`, `OfficeWriteTest` |
| 9 | Moving an office rewrites only that office's hierarchy path, leaving its sub-offices pointing at the old path; it also lets an office be moved under its own sub-office | Every sub-office's path is rewritten, and a move under one's own sub-office is refused (`error.msg.office.parentId.is.descendant`) | The hierarchy decides who sees what; a stale or circular path would leak or hide data | `OfficeWriteTest` |
| 10 | Payment types and staff are written with Fineract 1.16's typed requests: a request without a name, or with an unknown parameter, answers HTTP 500 (payment types), and an update replaces every field | A validation error (HTTP 400, Fineract's shape) for those requests; an update changes only the fields sent | A 500 for a mistake in the request is a defect, and a partial update is the only form Fineract's own clients send | `ReferenceWriteTest` |
| 11 | A holiday created without `reschedulingType` fails with HTTP 500 | It is created as "reschedule to a specified date" (2), the form Fineract's own client sends | The same defect | Planned |
| 12 | A number that is not a number (`"parentId": "abc"`) answers HTTP 500 | A validation error (`validation.msg.invalid.number.format`) | Same reason | `ParamsTest` |
| 13 | The text of errors that come from Fineract's libraries (a JSON syntax error from Gson, a recurrence-rule error from ical4j) | Our own text under the same message code, so a client keyed on the code behaves the same | The text is not part of the contract and cannot be matched without those libraries | Not compared in recorded scenarios |
| 14 | Dates are read in any locale | Month and day names are English only; a locale is accepted when it has the form `en` or `en_US` | Other locales arrive when a client needs them | `ParamsTest` |
| 15 | Creating a role with a name in use answers a generic data-integrity error when Fineract runs on PostgreSQL | `error.msg.role.duplicate.name` | As row 8 | `AdministrationWriteTest` |
| 16 | A role-permissions update with no `permissions` answers HTTP 500 | HTTP 400 with the "invalid body" error | As row 10 | `AdministrationWriteTest` |
| 17 | A new user without a password fails with a null pointer (HTTP 500) once everything else is valid; `sendPasswordToEmail: true` mails a generated password | HTTP 400 for the missing password; `sendPasswordToEmail: true` is refused as a mail that cannot be sent, because no mail server is configured | A password must exist, and a password nobody can receive is worse than none | `AdministrationWriteTest` |
| 18 | The password-reuse check compares the new password's salted hash with stored hashes, which never match | The new password is verified against each stored previous hash, so reuse is really refused | The setting `password-reuse-check-history-count` is meant to work | `AdministrationWriteTest` |
| 19 | A user's roles are listed in the order of a Java hash set | Listed by role id | Order carries no meaning; ids are stable | Scenario recorded with one role |
| 20 | `POST /roles/{id}?command=` with a command other than `enable` or `disable` answers HTTP 204 | The same | Kept so a client written against Fineract behaves the same | `AdministrationWriteTest` |
| 21 | The names of clients, groups, loans and savings accounts appear on audit and maker-checker entries | Left out until those modules exist | They need tables that are not built | Planned |
| 22 | A command waiting for approval is answered HTTP 200 with `rollbackTransaction: true`; the stored row says 200 | The same (E-CoreBank first answered 202, which is what the older pipeline tests assumed) | Recorded from Fineract | `ScenariosTest` (makerchecker) |
| 23 | Approving, rejecting or deleting a command checks the checker permission before looking at anything else | The same | Recorded from Fineract | `ScenariosTest` (makerchecker) |

**Security note:** the seeded users (`mifos`, `system`, `interopUser`) and the password `password` are Fineract's published defaults. They exist so the compatible API and Fineract's own tests work out of the box. A real deployment must change those passwords, or remove the users, before it holds real data. A password can now be changed with `PUT /users/{id}` or `POST /users/{id}/pwd`; the active password policy applies (the default policy asks for 12 to 50 characters with upper and lower case, a digit and a symbol).

