# Portfolio 2 - Query Processing and Optimisation

Uses the **NairaLink FX** schema from Portfolio 1 loaded with about 2.6M synthetic rows (1.44M FX rate ticks, 720k ledger lines, 210k transactions, 150k orders, 80k wallets).

| File | Purpose |
|---|---|
| `01_seed_data.sql` | Deterministic bulk data generator (balanced double-entry ledger) |
| `queries/q01..q09*.sql` | 9 business queries: joins, aggregation, CTE, `RANK()`, moving-average window, `LATERAL`, reconciliation |
| `bench.py` | Runs `EXPLAIN (ANALYZE, BUFFERS)` 5 times per query, stores the plan and the median time |
| `04_optimisation_indexes.sql` / `05_drop_optimisation_indexes.sql` | Composite, covering (`INCLUDE`) and FK-support indexes / rollback script |
| `06_materialised_view.sql` | Pre-aggregated daily volume |
| `analysis.md` | **Performance analysis** (read this first) |
| `evidence/` | Execution plans before/after (`plans/`), benchmark JSON and console output, seed, index and view creation output |

## Reproduce (PowerShell, from the repository root, after `. .\env.ps1`)
```powershell
psql -d nairalink -f .\portfolio-2-query-optimisation\01_seed_data.sql
psql -d nairalink -c "VACUUM (ANALYZE)"                      # fresh planner statistics before measuring
cd .\portfolio-2-query-optimisation
python bench.py before
cd ..
psql -d nairalink -f .\portfolio-2-query-optimisation\04_optimisation_indexes.sql
psql -d nairalink -f .\portfolio-2-query-optimisation\06_materialised_view.sql
psql -d nairalink -c "VACUUM (ANALYZE)"
cd .\portfolio-2-query-optimisation; python bench.py after; cd ..
```
Headline: indexes and rewrites cut Q1b, Q2, Q3 and Q4b from 18-580 ms to 0.02-0.11 ms. Q1a, Q5, Q7 and Q8 gain little, and `analysis.md` explains why from the plans.
