# Portfolio 4 - NoSQL and Advanced Data Models

**Model type:** document store (MongoDB 7.0.48, 3-node replica set) for the *same* NairaLink FX case study. Design reasoning: **`data_model.md`**.

| File | Purpose |
|---|---|
| `data_model.md` | Why NoSQL here, collection designs, embedding vs referencing, indexes, SQL-vs-document comparison |
| `01_etl_postgres_to_mongo.py` | Builds the 4 collections from PostgreSQL (embedding, bucket and polymorphic patterns) |
| `02_operations.py` | 11 demonstrations: queries, aggregation, `$lookup`, explain plans, atomic update, **multi-document transaction**, schema flexibility, each **cross-checked against PostgreSQL** |
| `03_mongosh_examples.js` | Key operations in native `mongosh` syntax |
| `evidence/` | `etl_output.txt`, `operations_output.txt`, `mongosh_output.txt` |

## Run it (PowerShell, after `. .\env.ps1`; the three Mongo containers must be up and `mongo1 mongo2 mongo3` mapped to 127.0.0.1 in the hosts file)
```powershell
cd .\portfolio-4-nosql
python 01_etl_postgres_to_mongo.py
python 02_operations.py
Get-Content .\03_mongosh_examples.js -Raw | docker exec -i mongo1 mongosh "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0" --quiet
```

## Collections
| Collection | Documents | Pattern |
|---|---:|---|
| `customer_profiles` | 20,000 | **embedding** (KYC documents, devices, preferences in one document) |
| `rate_buckets` | 8,624 | **bucket pattern** (hourly buckets instead of 80,000 raw ticks) |
| `trade_events` | 210,000 | **polymorphic** events with type-specific `details` |
| `price_alerts` | 30,000 | compound index for alert matching |

## Key results (all in `evidence/operations_output.txt`)
* Profile read = **one document**, 1.94 ms.
* `$elemMatch`: 6,232 profiles with a REJECTED/PENDING document, and the brute-force Python check gives the same count (MATCH); 452 tier >= 2 customers with an expired NIN also MATCH.
* Bucketed rate aggregation: daily high/low/tick count **identical to PostgreSQL** over the raw ticks (27.8 ms, 4,312 bucket documents scanned).
* Index on `{customer_id, ts}`: `explain("executionStats")` shows `SORT > COLLSCAN (210,000 docs examined)`, 186.8 ms, becoming `LIMIT > FETCH > IXSCAN (11 docs examined)`, 2.15 ms.
* Monthly FX volume by currency and the `$lookup` top-5 customers **match PostgreSQL exactly**.
* **ACID across two collections:** a transaction that fails after both writes leaves nothing behind; the committed one changes both.
* Alert index: 111.7 -> 9.8 ms; a smaller win because about 14% of alerts match (indexes pay off with selectivity).
* `$lookup` (join) took 716 ms, which is why relational joins stay in PostgreSQL.

## Summary
Use MongoDB for storing user profiles/KYC, bucketing market data, events and alerts (schema-flexible, read-heavy, hierarchical). Store financial transactions in PostgreSQL (declarative constraint, double entry integrity). They are reconciled via shared keys.