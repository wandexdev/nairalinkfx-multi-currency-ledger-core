# Portfolio 2 - Query Processing and Optimisation (7 marks)

Uses the **NairaLink FX** schema from Portfolio 1 loaded with ~2.7M synthetic rows.

| File | Purpose |
|---|---|
| `01_seed_data.sql` | Deterministic bulk data generator (balanced double-entry ledger) |
| `queries/q01..q09*.sql` | 9 business queries: joins, aggregation, CTE, `RANK()`, moving-average window, `LATERAL`, reconciliation |
| `bench.py` | Runs `EXPLAIN (ANALYZE, BUFFERS)` x5 per query, stores plan + median time |
| `04_optimisation_indexes.sql` / `05_drop...` | Composite, covering (`INCLUDE`) and FK-support indexes / rollback script |
| `06_materialised_view.sql` | Pre-aggregated daily volume |
| `analysis.md` | **Performance analysis** (read this first) |
| `evidence/` | Plans (before/after), query results, equivalence checks, index sizes, chart, benchmark JSON |

## Reproduce
```bash
psql -d nairalink -f ../portfolio-1-database-design/01_schema.sql -f ../portfolio-1-database-design/02_integrity_triggers.sql
psql -d nairalink -f 01_seed_data.sql                 # ~30 s
psql -d nairalink -f 05_drop_optimisation_indexes.sql # ensure baseline
pip install "psycopg[binary]"
python3 bench.py before "host=localhost dbname=nairalink user=$USER"
psql -d nairalink -f 04_optimisation_indexes.sql -f 06_materialised_view.sql
python3 bench.py after  "host=localhost dbname=nairalink user=$USER"
```
Headline: indexes/rewrites cut Q1b, Q2, Q3, Q4b from 11-250 ms to <0.1 ms. Two honest negative results (Q1a, Q5) are explained in `analysis.md`.
