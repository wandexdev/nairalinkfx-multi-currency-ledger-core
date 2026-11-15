# Portfolio 4 - MongoDB model for NairaLink FX

**Engine:** MongoDB 7.0.34 running as a 3-node replica set (`rs0`). Same case study and same data as Portfolios 1-3: the ETL
(`01_etl_postgres_to_mongo.py`) reads PostgreSQL and loads 20,000 profiles, 8,624 rate buckets, 210,000 trade events, 30,000 alerts.
**PostgreSQL stays the system of record for money** (balances, ledger, ACID postings). MongoDB holds the data that is *read-heavy,
hierarchical or shape-varying* - polyglot persistence, not a replacement.

## Why NoSQL for these parts (and not for the ledger)
| Data | Why a document store fits | Pattern |
|---|---|---|
| Customer profile + KYC documents + devices + notification prefs | Read together on one screen; number/kind of KYC documents differs by tier; new fields appear often (new regulator rules). One read instead of 5 joins. | **Embedding** |
| FX rate ticks | Huge append-only time series read in time windows. Storing 1 hour of ticks in one document cuts documents 18x and gives pre-computed open/high/low/close. | **Bucket pattern** |
| Trade / activity events (funding, FX, withdrawal, KYC, ...) | Each event type has different attributes. Relational needs nullable columns or many tables; here `details` varies per `type`. | **Polymorphic pattern** |
| Price alerts | Simple records matched by range queries against the latest price; no joins. | Indexed matching |
| *Ledger, wallets, orders* | Need multi-row ACID, constraints, double-entry balance, FK integrity | **Stay in PostgreSQL** |

## Collections
Real documents can be inspected with `db.customer_profiles.findOne()` (see `evidence/mongosh_output.txt`).
```
customer_profiles  _id = customer_id (same key as PostgreSQL)
  { email, full_name, country, status, created_at,
    kyc: { tier, risk_score, documents: [ {type, ref(masked), status, verified_at, expires_at}, ... ] },
    devices: [ {device_id, os, app_version, last_seen} ],
    notification_prefs: {push, email, sms, rate_alerts},
    referral: {code, referred_by},
    wallets_cache: { as_of, wallets: [ {ccy, balance} ] }   <- read-optimised copy, NOT the source of truth
  }
rate_buckets       _id = "USDNGN:1:2026111120"  (pair:lp:hour)
  { pair, lp_id, hour, day, n, open, high, low, close, ticks: [ {t, bid, ask}, ... ] }
trade_events       _id = transaction reference (same as PostgreSQL transactions.reference)
  { customer_id, type, status, ts, month, details: {...varies by type...} }
     FX_CONVERSION details: {sell_ccy, sell_amount, buy_ccy, buy_amount, rate, fee}
     FUNDING/WITHDRAWAL details: {channel, amount, currency}
price_alerts
  { customer_id, pair, direction (ABOVE|BELOW), target, active, created_at }
```

## Embedding vs referencing decisions
* KYC documents / devices are **embedded**: bounded size (<=6 documents, <=3 devices), always read with the profile, never queried alone.
* Ticks are embedded in hourly buckets (bounded: ~18 per hour per LP) - avoids the 16 MB document limit risk of one doc per pair per day.
* Events are **referenced** by `customer_id` (unbounded growth - embedding them in the profile would grow forever).
* `_id` values reuse relational keys so the two stores can be reconciled (done in `02_operations.py`).
* `wallets_cache` is denormalised on purpose: fast profile screen, accepted staleness (`as_of`), refreshed from PostgreSQL.

## Relational vs document comparison for this system
| Concern | PostgreSQL | MongoDB |
|---|---|---|
| Money movement, double-entry, constraints | **Strong fit** (ACID, CHECK, FK, deferred triggers) | Possible (transactions) but no declarative constraints |
| Profile with variable KYC documents | 3-5 tables + joins or JSONB | Natural single document |
| Add new attribute | `ALTER TABLE` / migration | Just write it |
| Rate time series | Fine with partitioning (Portfolio 5) | Bucket pattern fast & compact |
| Cross-collection joins | Native, optimised | `$lookup` works but is heavier (Q6: 254 ms for top-5 enrichment) |
| Consistency | Strong, immediate | Tunable (write/read concern) - see Portfolio 5 |

## Indexes created and why
* `trade_events {customer_id:1, ts:-1}` - equality then sort: history query went **COLLSCAN of 210,000 docs -> 11 keys examined** (51.7 ms -> 0.66 ms, ~78x).
* `price_alerts {pair, active, direction, target}` - equality prefix then range on target: 30,000 docs examined -> 4,285 (the exact matches).
* `_id` indexes exist by default. Indexes cost write time and RAM; `trade_events` index = 10.9 MB for 210k docs.
