# MIT 8103 Advanced Database Systems - Database Portfolio

**Case study: NairaLink FX** - a *simulated* Nigerian fintech FX platform (multi-currency wallets, FX conversion, immutable double-entry ledger),
modelled on the publicly visible features of FX/investment apps such as Bamboo and Cowrywise. I have no access to those companies' systems; all data is synthetic.
Users: retail customers, operations, compliance, treasury, finance/audit. Same case study in all five portfolios.

Stack: PostgreSQL 16 (system of record), MongoDB 7.0 (documents), Python 3 (psycopg, pymongo), Mermaid (diagrams).

| Portfolio | Folder | What it contains |
|---|---|---|
| 1 Design and modelling | `portfolio-1-database-design/` | case study, ER diagram, schema, constraints/triggers, normalisation, 13 constraint tests |
| 2 Query optimisation | `portfolio-2-query-optimisation/` | 1.44M-row data generator, 9 queries, execution plans before/after, indexes, materialised view, `analysis.md` |
| 3 Transactions and concurrency | `portfolio-3-transactions-concurrency/` | atomic FX conversion, commit/rollback/savepoint, lost update, isolation anomalies, write skew, deadlock, stress test |
| 4 NoSQL | `portfolio-4-nosql/` | MongoDB model (embedding, bucket, polymorphic), aggregation, `$lookup`, explain, multi-document transaction, cross-checks vs PostgreSQL |
| 5 Distributed and cloud | `portfolio-5-distributed-cloud/` | streaming replication, sync vs async, failover, partitioning, hash-sharding, MongoDB replica set failover, CAP/PACELC, cloud mapping |

Each folder has its own `README.md` explaining what was implemented, how to run it and what the evidence shows. Evidence (plans, outputs, charts) is in each `evidence/` folder.

## How To Reproduce
See **`SETUP.md`** for installation on Windows/macOS/Linux. Short version:
```bash
export PGHOST=localhost PGUSER=<you> PGPASSWORD=<pw>
export MONGO_URI="mongodb://localhost:27017/?replicaSet=rs0"
pip install "psycopg[binary]" pymongo
./scripts/run_portfolios_1_to_4.sh        # ~2-3 minutes, regenerates all evidence for Portfolios 1-4
# Portfolio 5 has its own scripts (they stop/kill servers on purpose): portfolio-5-distributed-cloud/README.md
```

## Key results
* Q1b/Q2/Q3/Q4b: 11-250 ms -> <0.1 ms with composite indexes, a LATERAL rewrite and a materialised view; two honest "no gain" results explained from the plans.
* Concurrency: lost update, write skew and deadlock reproduced and fixed; stress test 15 -> 678 requests/s after finding a lock-holding slow read; all invariants (ledger = wallets, balanced, no negatives) hold.
* MongoDB: every aggregate matches PostgreSQL exactly; index cut a 210,000-document scan to 11 keys examined.
* Distributed: 0 acknowledged commits lost when the primary was killed under synchronous replication; MongoDB `w=majority` lost 0 writes in step-down and `kill -9`.

## AI use declaration
Tool: Claude. Used for drafting documentation and running experiments in a sandbox.


## References
PostgreSQL 16 documentation; MongoDB Manual 7.0; Kleppmann, *Designing Data-Intensive Applications* (2017); Gilbert & Lynch (2002) CAP; Abadi (2012) PACELC.
