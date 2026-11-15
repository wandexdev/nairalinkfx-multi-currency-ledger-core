# Portfolio 1 - Database Design and Modelling (7 marks)

**Case study:** NairaLink FX, a *simulated* multi-currency wallet & FX conversion platform
(see `00_case_study.md`).

| File | Purpose |
|---|---|
| `00_case_study.md` | Organisation, users, data, operations, how an FX conversion works |
| `erd.mmd` / `erd.png` | ER diagram (Mermaid source + rendered image) |
| `01_schema.sql` | Relational schema: tables, PK/FK, CHECK, UNIQUE, reference data |
| `02_integrity_triggers.sql` | Audit trigger, version bump, append-only ledger, deferred double-entry check |
| `03_constraint_tests.sql` | 14 checks: 11 expected rejections and 3 positive checks |
| `normalisation.md` | UNF -> 3NF walkthrough + justified denormalisation |
| `evidence/` | Captured test output, `\d+` descriptions, schema dump |

## How to run
```bash
createdb nairalink
psql -d nairalink -f 01_schema.sql -f 02_integrity_triggers.sql
psql -d nairalink -a -f 03_constraint_tests.sql      # errors are EXPECTED (see comments)
```
Tested on PostgreSQL 16.

## What the evidence shows
`evidence/constraint_tests_output.txt` shows duplicate email, bad email, unknown tier, duplicate wallet,
overdraft, hold>balance, ask<bid, same-currency pair, restricted delete, **unbalanced ledger rejected at
COMMIT**, **append-only ledger**, audit row created, version bumped - and one valid balanced posting accepted.

## Design decisions
* **Double-entry ledger with a house account** so money is never created or destroyed; verified per currency.
* **Immutable history**: corrections are reversals, never UPDATE/DELETE.
* **Frozen price on the order** (deliberate denormalisation, justified in `normalisation.md`).
