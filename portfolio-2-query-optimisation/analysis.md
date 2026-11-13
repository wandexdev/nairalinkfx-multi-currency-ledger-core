# Portfolio 2 - Query performance analysis

**Environment:** PostgreSQL 16, single node, `jit=off`, 2 parallel workers. Data: 20,001 customers, 80,007 wallets,
**1,440,000** FX rate ticks, 150,000 FX orders, **720,000** ledger lines (synthetic; `01_seed_data.sql`).
**Method:** `bench.py` runs `EXPLAIN (ANALYZE, BUFFERS)` 5 times per query and records the **median** execution time.
*Before* = only PK/UNIQUE indexes. *After* = `04_optimisation_indexes.sql` (+ `06_materialised_view.sql` for Q4b).
Full plans: `evidence/plans/qNN_before.txt` / `qNN_after.txt`. Chart: `evidence/performance_before_after.png`.

| Query | Business purpose | Before (ms) | After (ms) | Change |
|---|---|---:|---:|---|
| Q1a `DISTINCT ON` latest rate per LP | Quote screen | 250.0 | 253.2 | **no gain** |
| Q1b `LATERAL ... LIMIT 1` rewrite | same answer | 250.0 | **0.05** | ~5,000x |
| Q2 wallet statement (last 20 lines) | Mobile app | 22.1 | **0.08** | ~275x |
| Q3 customer order history | App / support | 11.1 | **0.02** | ~550x |
| Q4a daily volume (live aggregate) | Treasury dashboard | 76.5 | 50.9 | 1.5x |
| Q4b daily volume from materialised view | same dashboard | 76.5 | **0.09** | ~850x |
| Q5 top-5 per KYC tier (CTE + RANK) | Compliance/marketing | 134.9 | 131.1 | none |
| Q6 7-day moving average of rate | Analytics | 101.9 | 35.3 | 2.9x |
| Q7 ledger reconciliation | Finance audit | 338.7 | 318.9 | none (expected) |
| Q8 customers near daily limit | Compliance | 64.6 | 55.3 | 1.2x |
| Q9 lookup by `reference` (control) | Idempotency | 0.01 | 0.01 | already indexed (UNIQUE) |

## What the execution plans show
* **Q2 / Q3 (big wins).** Before: parallel sequential scan of 720k ledger rows / 150k orders then sort. After: a single
  index range scan; `idx_ledger_wallet_time (wallet_id, created_at DESC)` matches `WHERE wallet_id=? ORDER BY created_at DESC LIMIT 20`,
  so rows come out already sorted and the scan stops after 20 - **no Sort node**. Cost no longer grows with table size.
* **Q1a (honest negative result - an index that did not help).** My first attempt indexed `(base_ccy, quote_ccy, lp_id, captured_at DESC)`
  and the time stayed ~250 ms. The plan (`evidence/plans/q01a_after.txt`) shows a Bitmap scan of **all 240,000** USD/NGN rows
  followed by an on-disk **external merge Sort** and `Unique`. PostgreSQL 16 has no *skip scan*, so `DISTINCT ON` must read every row for
  the pair. The index only changed *how* the 240k rows were fetched, not *how many*.
* **Q1b (the fix).** Rewriting as one `LIMIT 1` probe per liquidity provider (`CROSS JOIN LATERAL`) lets the planner use the
  index three times (one descent per LP). 250 ms -> 0.05 ms. `evidence/equivalence_checks.txt` proves Q1a and Q1b return identical rows.
  **Lesson: an index is necessary but the query shape must let the engine use it.**
* **Q4 / Q8 (small gains).** The plan switches to an *Index Only Scan* using the covering index
  (`INCLUDE (customer_id, buy_wallet, sell_amount, fee_amount)`), avoiding heap fetches, but the time is dominated by the
  aggregation of ~25k-50k rows, so the gain is modest (1.2-1.5x). The real fix for a dashboard that is read constantly is to
  **pre-aggregate**: Q4b reads a 474-row materialised view, 0.09 ms. Trade-off: the MV is stale until
  `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_volume` runs (a unique index makes the concurrent refresh possible); the build
  took ~0.4 s. Q4a and Q4b agree on every full day; they differ only on the partial boundary day (live query counts part of that day,
  the MV counts all of it) - verified in `evidence/equivalence_checks.txt`.
* **Q5 (no gain, and why).** A 90-day window covers about half of all orders. When a query needs a large fraction of a table, a
  sequential/ordered full scan is as cheap as random index access, and the planner correctly keeps the cheaper plan. Differences
  (134.9 vs 131.1 ms) are within run-to-run noise. Not every query should be "fixed" with an index.
* **Q7 (reconciliation, expected to scan).** It must read every ledger line to total every wallet. It returned **0 mismatches**, which is the
  actual evidence of correctness (wallet balances equal the ledger). A full-table audit is inherently O(n); a production system would run
  it as a scheduled batch or incrementally by day, not on the request path.
* **Q6.** Range scan on `idx_fx_rates_pair_lp_time` reads only the last 60 days of one pair/LP instead of the whole 1.44M-row table (2.9x).

## Index cost (writes, storage)
`evidence/index_sizes.txt`: the rate index is ~56 MB (largest, on the biggest table), ledger indexes 21 MB + 9.6 MB, order indexes ~13 MB.
Every extra index slows each INSERT slightly and uses memory/disk; `fx_rates` and `ledger_entries` are append-only so there is no
update/HOT-pruning penalty, which is why indexing them is a good trade. Indexes on rarely-queried columns were deliberately **not** added.

## Conclusions
1. Measure first, then index; verify with the plan, not intuition (Q1a).
2. Match index column order to equality-then-sort/range (Q1, Q2, Q3).
3. Rewrite the query when the engine lacks an access path (LATERAL emulates loose index scan).
4. Pre-aggregate hot read-mostly dashboards (materialised view) and accept bounded staleness.
5. Leave full-table audits as batch jobs.

*Run-to-run variation:* a full re-run of the pipeline (`scripts/run_portfolios_1_to_4.sh`) on a different PostgreSQL instance reproduced the same plan shapes and ratios with timings within roughly +-30% (e.g. Q1b 0.05-0.06 ms, Q2 0.08-0.09 ms); the table above is the recorded run. Q4a/Q8 sometimes switch between Index-Only and Bitmap scans, which is why their gain is small and unstable.

*Caveat:* single-machine, synthetic data, warm cache - absolute numbers will differ on other hardware; the plan shapes and ratios are what matter.
