# Portfolio 3 - Transactions and Concurrency (7 marks)

**Evidence file: `evidence/scenarios_output.txt`** (output of `python3 scenarios.py`, run on PostgreSQL 16).

| File | Purpose |
|---|---|
| `01_convert_currency.sql` | `fx.convert_currency()` (atomic FX conversion) and `fx.reverse_conversion()` |
| `scenarios.py` | Runs every scenario below with real concurrent sessions (threads) and prints the outcome |
| `02_manual_two_terminal_demo.md` | Same anomalies step-by-step in two `psql` terminals |
| `evidence/` | `scenarios_output.txt`, stress test before/after the fix, quote-lookup plan |

## What is demonstrated
| ID | Concept | Result observed |
|---|---|---|
| A1 | **COMMIT** - one conversion is one atomic unit: 4 wallet updates, order, transaction, **4 ledger legs** | NGN -100,000; USD +62.5137; legs balanced per currency |
| A2 | **ROLLBACK** on failure (insufficient funds) | balances identical, **no** transaction row left |
| A3 | Manual `ROLLBACK`, `SAVEPOINT` / `ROLLBACK TO` | uncommitted +500 invisible to other session, then undone; CHECK violation rolled back to savepoint |
| A4 | **Idempotency** (same reference twice) | same `txn_id`, charged once |
| A5 | **Reversal** (compensating entries, never UPDATE history) | balances restored, original `REVERSED`, 2nd reversal rejected |
| A6 | Business rules (KYC tier 0, daily limit, bad currency/amount) | all rejected with clear errors |
| B1 | **Lost update** under READ COMMITTED | naive read-modify-write ends at **900 (wrong)**; fixed (800) by `FOR UPDATE`, atomic `balance=balance-100`, or optimistic version check |
| B2 | **Non-repeatable read** | READ COMMITTED sees 1000 -> 1250; REPEATABLE READ stable |
| B3 | **Phantom read** | READ COMMITTED count 3 -> 4; REPEATABLE READ stable (PostgreSQL snapshot isolation) |
| B4 | **Write skew** on a daily limit | REPEATABLE READ **breaches** limit (6,000,000 > 5,000,000); SERIALIZABLE aborts one txn with `40001`, retry refuses it -> 3,000,000 |
| B5 | **Deadlock** | opposite lock order -> one session aborted (`40P01`); ascending-id ordering -> both commit |
| C | **Stress test**, 8 workers x 4,000 requests (10% duplicate retries) | exactly-once: 3,601 distinct refs requested, 3,599 accepted, 3,599 created; 2 correctly rejected by the daily limit under concurrency |
| Inv. | Invariants after everything | 0 wallet/ledger mismatches, 0 unbalanced txns, 0 negative customer balances, net ledger = 0, 0 customers over limit |

## Isolation level cheat-sheet (PostgreSQL)
| Level | Dirty read | Non-repeatable | Phantom | Write skew |
|---|---|---|---|---|
| READ UNCOMMITTED (treated as RC) | no | **yes** | **yes** | **yes** |
| READ COMMITTED (default) | no | **yes** | **yes** | **yes** |
| REPEATABLE READ | no | no | no (PG) | **yes** |
| SERIALIZABLE (SSI) | no | no | no | **no** (aborts with 40001 -> must retry) |

## Concurrency-control mechanisms used
* **ACID atomicity** via a single PL/pgSQL function body (one transaction); constraints + deferred ledger trigger give **consistency**.
* **Pessimistic locking** `SELECT ... FOR UPDATE` on wallets, always in ascending `wallet_id` (deadlock avoidance) - also serialises each customer's limit check.
* **Optimistic locking** `version` column (B1 fix 3).
* **MVCC** snapshots (B2/B3), **SSI** for write skew (B4), **idempotency key** (`transactions.reference` UNIQUE + re-check under lock).
* **Durability:** WAL + commit; see Portfolio 5 for replication.

## A real performance finding from the stress test
First stress run was **correct but slow: 15 req/s, p50 229 ms, p95 1.7 s** (`evidence/stress_before_quote_fix.txt`).
Cause: the "latest quote" lookup (`ORDER BY captured_at DESC LIMIT 1` across all LPs) read **240,000 rows** per call
(`evidence/quote_lookup_plan_before.txt`) *while holding the house-wallet lock*, so all conversions queued behind it - exactly the
anti-pattern found in Portfolio 2 (Q1a). Fix: per-LP `LATERAL ... LIMIT 1` probe (Portfolio 2 Q1b) and move the read **before** taking locks.
Result: **678 req/s (~45x), p50 8.6 ms, p95 31.6 ms**, still 100% correct.
Remaining limit: every conversion updates the single house NGN wallet row, a **hot row**. Production remedy: split settlement into N sub-wallets
(by hash of customer) and aggregate periodically - a trade-off between throughput and simplicity.

## Bugs found while building (kept honest)
1. Function relied on the caller's `search_path` -> failed from a new connection; fixed with `SET search_path` on the function.
2. A reversal left the original order `FILLED`, which would keep counting against the daily limit; reversal now sets it `CANCELLED`.
