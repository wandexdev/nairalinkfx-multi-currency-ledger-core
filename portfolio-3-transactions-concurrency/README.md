# Portfolio 3 - Transactions and Concurrency

**Evidence file: `evidence/scenarios_output.txt`** (output of `python scenarios.py`, PostgreSQL 16 in Docker).

| File | Purpose |
|---|---|
| `01_convert_currency.sql` | `fx.convert_currency()` (atomic FX conversion) and `fx.reverse_conversion()` |
| `scenarios.py` | Runs every scenario below with real concurrent sessions (threads) and prints the outcome |
| `02_manual_two_terminal_demo.md` | The same anomalies step by step in two `psql` terminals |
| `evidence/scenarios_output.txt` | Raw output of the run |

## Reproduce (PowerShell, after `. .\env.ps1` and Portfolios 1-2)
```powershell
psql -d nairalink -v ON_ERROR_STOP=1 -f .\portfolio-3-transactions-concurrency\01_convert_currency.sql
cd .\portfolio-3-transactions-concurrency
python scenarios.py
```

## What is demonstrated (all from my run)
| ID | Concept | Result observed |
|---|---|---|
| A1 | **COMMIT**: one conversion is one atomic unit (4 wallet updates, order, transaction, **4 ledger legs**) | NGN -100,000; USD +62.5137; legs balanced per currency |
| A2 | **ROLLBACK** on failure (insufficient funds) | balances identical, **no** transaction row left |
| A3 | Manual `ROLLBACK`, `SAVEPOINT` / `ROLLBACK TO` | uncommitted +500 invisible to another session, then undone; CHECK violation blocked the bad update |
| A4 | **Idempotency** (same reference twice) | same `txn_id`, charged once |
| A5 | **Reversal** (compensating entries, history never edited) | balances restored, original `REVERSED`, second reversal rejected |
| A6 | Business rules (KYC tier 0, daily limit, bad currency/amount) | all rejected with clear errors |
| B1 | **Lost update** under READ COMMITTED | naive read-modify-write ends at **900 (wrong)**; `FOR UPDATE`, atomic `balance = balance - 100`, or an optimistic version check give 800 |
| B2 | **Non-repeatable read** | READ COMMITTED reads 1000 then 1250; REPEATABLE READ is stable |
| B3 | **Phantom read** | READ COMMITTED count 3 then 4; REPEATABLE READ stable (snapshot isolation) |
| B4 | **Write skew** on a daily limit | REPEATABLE READ **breaches** the limit (6,000,000 > 5,000,000); SERIALIZABLE aborts one transaction with `40001`, the retry refuses it, total 3,000,000 |
| B5 | **Deadlock** | opposite lock order: one session aborted (`40P01`); ascending-id ordering: both commit |
| C | **Stress test**: 8 workers, 4,000 requests (10% duplicate retries) | **414 req/s**, p50 7.6 ms, p95 93.6 ms; exactly-once **PASS**: 3,601 distinct references requested, accepted and created |
| Inv. | Invariants afterwards | 0 wallet/ledger mismatches, 0 unbalanced transactions, 0 negative customer balances, net of all ledger legs = 0 |

## Isolation level cheat-sheet (PostgreSQL)
| Level | Dirty read | Non-repeatable | Phantom | Write skew |
|---|---|---|---|---|
| READ UNCOMMITTED (treated as READ COMMITTED) | no | **yes** | **yes** | **yes** |
| READ COMMITTED (default) | no | **yes** | **yes** | **yes** |
| REPEATABLE READ | no | no | no (in PG) | **yes** |
| SERIALIZABLE (SSI) | no | no | no | **no** (aborts with 40001; the application must retry) |

## Concurrency-control mechanisms used
* **Atomicity** through a single PL/pgSQL function body (one transaction); constraints plus the deferred ledger trigger give **consistency**.
* **Pessimistic locking** `SELECT ... FOR UPDATE` on wallets, always in ascending `wallet_id` (deadlock avoidance); it also serialises each customer's limit check.
* **Optimistic locking** with a `version` column (B1 fix 3).
* **MVCC** snapshots (B2, B3), **SSI** for write skew (B4), and an **idempotency key** (`transactions.reference` is UNIQUE and is re-checked under lock).
* **The latest quote is read before locks are taken**, so a slow read never holds the house-wallet lock.
* **Durability:** WAL plus commit; replication is covered in Portfolio 5.

## Design constraints
All conversions will be sent to a single hot wallet for NGN settlements. This will cause a bottleneck. The solution in production would be to divide the settlement into N wallets (e.g. based on hash of customer) and then periodically consolidate. There is a tradeoff between performance and simplicity.

## Note on the daily-limit monitoring line
The last line of `evidence/scenarios_output.txt` ("customers over their daily limit today") reports 37, although the block is labelled "expect 0". The seed script (`01_seed_data.sql`) bulk-inserts orders directly and does not go through `fx.convert_currency()`, so its same-day orders are not subject to the limit check. To test this I queried a day that contains only seeded orders (13 Nov, on the rebuilt Portfolio 5 database, where no stress test was run): **123 customers** exceed their tier limit (`evidence/daily_limit_diagnostic.txt`), so breaches arise from the bulk load rather than from the procedure. The procedure's own limit check is shown in A6 (rejection). The stress-test customers (KYC tier 2, limit 5,000,000 NGN, about 18 requests each of at most 149,000 NGN) would need roughly three times their average request count to exceed it, which the random draw makes extremely unlikely. I could not re-run the original query on the original database because Portfolio 5 replaced it; with more time I would exclude seeded orders from this monitor.
