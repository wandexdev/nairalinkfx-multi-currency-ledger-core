#!/usr/bin/env python3
"""Portfolio 4 - build the MongoDB data model for NairaLink FX from the relational database.
usage: python3 01_etl_postgres_to_mongo.py [pg_dsn] [mongo_uri]
Collections created (see data_model.md for the reasoning):
  customer_profiles  - one rich document per customer (embedded KYC docs, devices, prefs)        [embedding]
  rate_buckets       - one document per pair/LP/hour holding its ticks + OHLC                      [bucket pattern]
  trade_events       - flexible event log with a type-specific `details` sub-document             [polymorphic pattern]
  price_alerts       - customer rate alerts matched against the latest tick                        [index-driven matching]
"""
import sys, random, datetime as dt, psycopg, pymongo
PG = sys.argv[1] if len(sys.argv) > 1 else "dbname=nairalink"
import os
MG = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("MONGO_URI", "mongodb://127.0.0.1:27017,127.0.0.1:27018,127.0.0.1:27019/?replicaSet=rs0")
mongo = pymongo.MongoClient(MG); db = mongo["nairalink_nosql"]
for n in ("customer_profiles", "rate_buckets", "trade_events", "price_alerts"): db.drop_collection(n)
pg = psycopg.connect(PG)
def flush(coll, buf):
    if buf: db[coll].insert_many(buf, ordered=False); buf.clear()

# ---- 1. customer_profiles ------------------------------------------------------------------
now = dt.datetime.now(dt.timezone.utc)
cur = pg.execute("""SELECT c.customer_id, c.email, c.full_name, c.country_code, c.kyc_tier, c.status, c.created_at,
                           (SELECT json_agg(json_build_object('ccy', w.currency_code, 'balance', w.balance::float8) ORDER BY w.currency_code)
                              FROM fx.wallets w WHERE w.customer_id=c.customer_id) AS wallets
                    FROM fx.customers c WHERE c.customer_id > 1 ORDER BY 1""")
buf = []; n = 0
for cid, email, name, cc, tier, status, created, wallets in cur:
    r = random.Random(cid)
    docs = []
    wanted = {0: [], 1: ["BVN", "PHONE"], 2: ["BVN", "PHONE", "NIN", "SELFIE"], 3: ["BVN", "PHONE", "NIN", "SELFIE", "UTILITY_BILL", "SOURCE_OF_FUNDS"]}[tier]
    for t in wanted:
        st = r.choices(["VERIFIED", "PENDING", "REJECTED"], [0.88, 0.09, 0.03])[0]
        docs.append({"type": t, "ref": f"{t[:3]}-****{r.randrange(1000,9999)}", "status": st,
                     "verified_at": created + dt.timedelta(days=r.randrange(1, 20)) if st == "VERIFIED" else None,
                     "expires_at": now + dt.timedelta(days=r.randrange(-30, 700)) if t in ("NIN", "UTILITY_BILL") else None})
    buf.append({"_id": cid, "email": email, "full_name": name, "country": cc, "status": status, "created_at": created,
                "kyc": {"tier": tier, "documents": docs, "risk_score": r.randrange(1, 100)},
                "devices": [{"device_id": f"dev-{cid}-{k}", "os": r.choice(["Android", "iOS"]), "app_version": f"{r.randrange(3,6)}.{r.randrange(0,9)}",
                             "last_seen": now - dt.timedelta(hours=r.randrange(1, 900))} for k in range(r.randrange(1, 4))],
                "notification_prefs": {"push": r.random() < .8, "email": r.random() < .5, "sms": r.random() < .3, "rate_alerts": r.random() < .6},
                "referral": {"code": f"NL{cid:06d}", "referred_by": r.randrange(2, cid) if cid > 3 and r.random() < .25 else None},
                "wallets_cache": {"as_of": now, "wallets": wallets}})   # read-optimised copy; PostgreSQL stays the source of truth
    n += 1
    if len(buf) >= 5000: flush("customer_profiles", buf)
flush("customer_profiles", buf); print("customer_profiles", n)

# ---- 2. rate_buckets (USD/NGN & GBP/NGN, LP 1) : one document per hour ------------------------
cur = pg.execute("""SELECT base_ccy, date_trunc('hour', captured_at) AS hr,
                           json_agg(json_build_object('t', captured_at, 'bid', bid::float8, 'ask', ask::float8) ORDER BY captured_at) AS ticks
                    FROM fx.fx_rates WHERE lp_id=1 AND base_ccy IN ('USD','GBP') GROUP BY 1,2 ORDER BY 2,1""")
buf = []; n = 0
for base, hr, ticks in cur:
    mids = [(t["bid"] + t["ask"]) / 2 for t in ticks]
    buf.append({"_id": f"{base}NGN:1:{hr:%Y%m%d%H}", "pair": f"{base}/NGN", "lp_id": 1, "hour": hr, "day": f"{hr:%Y-%m-%d}", "n": len(ticks),
                "open": mids[0], "high": max(mids), "low": min(mids), "close": mids[-1], "ticks": ticks})
    n += 1
    if len(buf) >= 500: flush("rate_buckets", buf)
flush("rate_buckets", buf); print("rate_buckets", n)

# ---- 3. trade_events (polymorphic `details`) --------------------------------------------------
cur = pg.execute("""SELECT t.reference, t.customer_id, t.txn_type, t.status, t.created_at,
         o.sell_amount::float8, o.buy_amount::float8, o.rate_applied::float8, o.fee_amount::float8, bw.currency_code,
         p.channel, p.amount::float8, p.currency_code
       FROM fx.transactions t
       LEFT JOIN fx.fx_orders o ON o.txn_id=t.txn_id LEFT JOIN fx.wallets bw ON bw.wallet_id=o.buy_wallet
       LEFT JOIN fx.payments p ON p.txn_id=t.txn_id
       WHERE t.txn_type IN ('FX_CONVERSION','FUNDING','WITHDRAWAL') AND t.reference NOT LIKE 'STRESS%%' AND t.reference NOT LIKE 'A%%-%%'
       ORDER BY t.txn_id""")
buf = []; n = 0
for ref, cid, typ, st, ts, sell, buy, rate, fee, bccy, chan, pamt, pccy in cur:
    d = ({"sell_ccy": "NGN", "sell_amount": sell, "buy_ccy": bccy, "buy_amount": buy, "rate": rate, "fee": fee} if typ == "FX_CONVERSION"
         else {"channel": chan, "amount": pamt, "currency": pccy})
    buf.append({"_id": ref, "customer_id": cid, "type": typ, "status": st, "ts": ts, "month": f"{ts:%Y-%m}", "details": d})
    n += 1
    if len(buf) >= 10000: flush("trade_events", buf)
flush("trade_events", buf); print("trade_events", n)

# ---- 4. price_alerts ---------------------------------------------------------------------------
r = random.Random(99); buf = []
mid = {"USD/NGN": 1550, "GBP/NGN": 1960, "EUR/NGN": 1680}
for i in range(30000):
    pair = r.choice(list(mid)); dirn = r.choice(["ABOVE", "BELOW"])
    buf.append({"customer_id": r.randrange(2, 20002), "pair": pair, "direction": dirn,
                "target": round(mid[pair] * (1 + r.uniform(-0.06, 0.06)), 2), "active": r.random() < 0.85,
                "created_at": now - dt.timedelta(days=r.randrange(0, 90))})
db.price_alerts.insert_many(buf); print("price_alerts", len(buf))
