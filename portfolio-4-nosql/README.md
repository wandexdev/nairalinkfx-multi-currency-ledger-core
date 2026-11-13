# Portfolio 4 - NoSQL and Advanced Data Models (7 marks)

**Model type:** document store (MongoDB 7.0, 3-node replica set) for the *same* NairaLink FX case study. Design reasoning: **`data_model.md`**.

| File | Purpose |
|---|---|
| `data_model.md` | Why NoSQL here, collection designs, embedding vs referencing, indexes, SQL-vs-document comparison |
| `01_etl_postgres_to_mongo.py` | Builds the 4 collections from PostgreSQL (embedding, bucket and polymorphic patterns) |
| `02_operations.py` | 11 demonstrations: queries, aggregation, `$lookup`, explain plans, atomic update, **multi-document transaction**, schema flexibility - each **cross-checked against PostgreSQL** |
| `03_mongosh_examples.js` | Key operations in native `mongosh` syntax |
| `evidence/` | `operations_output.txt`, `mongosh_output.txt`, `etl_output.txt`, `sample_documents.json` |

## Run it
```bash
# MongoDB must be running (see ../portfolio-5-distributed-cloud/SETUP.md or the docker-compose file)
pip install "psycopg[binary]" pymongo
python3 01_etl_postgres_to_mongo.py "host=localhost dbname=nairalink user=$USER" "mongodb://localhost:27017/?replicaSet=rs0"
python3 02_operations.py "mongodb://localhost:27017/?replicaSet=rs0" "host=localhost dbname=nairalink user=$USER"
mongosh "mongodb://localhost:27017/?replicaSet=rs0" --quiet 03_mongosh_examples.js
```

## Key results (all in `evidence/operations_output.txt`)
* Profile read = **one document**, 0.64 ms.
* Embedded-array query `$elemMatch`: 6,232 profiles with a REJECTED/PENDING document; **brute-force Python check equals** the database answer. 452 tier>=2 customers with an expired NIN, also verified.
* Bucketed rate aggregation: daily high/low/tick-count **identical to PostgreSQL** over the raw 80,000 ticks.
* Index on `{customer_id, ts}`: `explain("executionStats")` shows `SORT > COLLSCAN (210,000 docs examined)` -> `LIMIT > FETCH > IXSCAN (11 docs examined)`.
* Monthly FX volume by currency and the `$lookup` top-5 customers **match PostgreSQL to the naira**.
* **ACID across two collections:** a transaction that fails after both writes leaves nothing behind; the committed one changes both.
* Honest observation: the alert index helps less (13.7 -> 4.3 ms) because ~14% of documents match - indexes pay off with selectivity.

## Suitability summary
Use MongoDB for profile/KYC, market-data buckets, event feeds and alerts (flexible, read-heavy, hierarchical).
Keep money movement in PostgreSQL (declarative constraints, double-entry integrity). The two are reconciled by shared keys.
