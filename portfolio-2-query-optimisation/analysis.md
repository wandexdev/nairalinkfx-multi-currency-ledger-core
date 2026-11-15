# Portfolio 2 - Query performance analysis

**Environment:** PostgreSQL 16 in Docker on a Windows host, single node, `jit=off`, 2 parallel workers. Data: about 20,000 customers, 80,007 wallets,
**1,440,000** FX rate ticks, 150,000 FX orders, **720,000** ledger lines (synthetic, `01_seed_data.sql`).
**Method:** `bench.py` runs `EXPLAIN (ANALYZE, BUFFERS)` 5 times per query and records the **median** execution time. *Before* = only PK/UNIQUE indexes.
*After* = `04_optimisation_indexes.sql` plus `06_materialised_view.sql` (for Q4b). `VACUUM (ANALYZE)` was run before each phase.
Full plans: `evidence/plans/qNN_before.txt` and `qNN_after.txt`; console summaries: `evidence/bench_*_console.txt`.

| Query | Business purpose | Before (ms) | After (ms) | Change |
|---|---|---:|---:|---|
| Q1a `DISTINCT ON` latest rate per LP | Quote screen | 700.9 | 504.1 | small gain only |
| Q1b `LATERAL ... LIMIT 1` rewrite | same answer | 579.8 | **0.10** | about 5,000x |
| Q2 wallet statement (last 20 lines) | Mobile app | 45.7 | **0.11** | about 400x |
| Q3 customer order history | App / support | 17.4 | **0.02** | about 800x |
| Q4a daily volume (live aggregate) | Treasury dashboard | 110.8 | 62.9 | 1.8x |
| Q4b daily volume from materialised view | same dashboard | 110.8 (vs Q4a) | **0.10** | about 1,100x |
| Q5 top-5 per KYC tier (CTE + RANK) | Compliance/marketing | 168.6 | 131.2 | 1.3x |
| Q6 7-day moving average of rate | Analytics | 120.2 | 51.8 | 2.3x |
| Q7 ledger reconciliation | Finance audit | 477.4 | 417.1 | little (expected) |
| Q8 customers near daily limit | Compliance | 95.6 | 86.9 | 1.1x |
| Q9 lookup by `reference` (control) | Idempotency | 0.03 | 0.03 | already indexed (UNIQUE) |

## What the execution plans show
* **Q2 / Q3 (big wins).** Before: a parallel sequential scan of the ledger / orders table and then a sort. After: an index scan. For Q2 the index
  `idx_ledger_wallet_time` matches `WHERE wallet_id = ? ORDER BY created_at DESC LIMIT 20`, so rows come out already sorted and the scan stops after 20,
  with **no Sort node**. Cost no longer grows with the table size.
* **Q1a (an index that did not help).** The index on `(base_ccy, quote_ccy, lp_id, captured_at DESC)` changed the plan to a Bitmap Heap Scan, but time only
  fell from 701 to 504 ms. PostgreSQL 16 has no *skip scan*, so `DISTINCT ON` still reads every row for the currency pair. The index changed *how* the rows were
  fetched, not *how many*. See `evidence/plans/q01a_after.txt`.
* **Q1b (the fix).** Rewriting as one `LIMIT 1` probe per liquidity provider (`CROSS JOIN LATERAL`) lets the planner use the index once per provider. Before the index
  the rewrite was no better (580 ms, still a sequential scan), after the index it takes 0.10 ms. **An index is necessary, but the query shape must let the engine use it;
  here both were needed.** Q1a and Q1b both return the latest tick per liquidity provider for the pair.
* **Q4 / Q8 (small gains).** The plan switches to an *Index Only Scan* on the covering index (`INCLUDE ...`), avoiding heap fetches, but the time is dominated by aggregating many rows,
  so the gain is modest. For a dashboard read constantly the better fix is to **pre-aggregate**: Q4b reads a small materialised view in 0.10 ms. Trade-off: the view is stale until
  `REFRESH MATERIALIZED VIEW CONCURRENTLY` runs (a unique index makes that possible). Q4a is live; Q4b includes the whole boundary day, so they differ slightly on the partial first day.
* **Q5 (modest gain).** The plan uses an Index Only Scan on orders but still scans `customers` sequentially; a query that touches a large share of a table gains little from indexes.
* **Q7 (reconciliation, expected to scan).** It must read every ledger line to total every wallet. A full-table audit is inherently O(n); production would run it as a scheduled batch or incrementally by day.
* **Q6.** A range scan on `idx_fx_rates_pair_lp_time` reads only recent rows for one pair/provider instead of the whole 1.44M-row table.

## Measurement note (a lesson from my first run)
My first benchmark (before running `VACUUM ANALYZE` after the seed) showed some queries **slower** after indexing (for example Q7 365 -> 706 ms, Q4a 119 -> 180 ms). Q7 uses a sequential scan in both phases, so
that difference is noise or background maintenance rather than the index. I re-ran both phases after `VACUUM (ANALYZE)` (fresh statistics and a visibility map for index-only scans) and the table above
is that second run. Lesson: check statistics and background activity before trusting a before/after comparison.

## Index cost
Every extra index slows each `INSERT` slightly and uses memory and disk. `fx_rates` and `ledger_entries` are append-only, so there is no update penalty and indexing them is a good trade. Sizes can be listed with `\di+ fx.*`.
Indexes on rarely queried columns were deliberately not added.

## Conclusions
1. Measure before indexing, use fresh stats. Confirm by looking at the plan (not guessing) (Q1a).
2. Match index column order to equality-then-sort/range (Q1, Q2, Q3).
3. Rewrite the query if the engine can't find an access path. Use `LATERAL` to imitate a loose index scan.
4. Pre-aggregate hot read-mostly dashboards and tolerate staleness.
5. Leave full-table audits as batch jobs.

*Note* that this is single machine, synthetic data, cache warmed up and Docker on windows so actual figures will be different but it is the shape of the plan and relative ratios that are important..
