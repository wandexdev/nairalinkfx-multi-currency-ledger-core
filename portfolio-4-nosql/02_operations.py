#!/usr/bin/env python3
"""Portfolio 4 - MongoDB operations on the NairaLink FX document model, with timings, explain("executionStats")
output and cross-checks against the relational database (PostgreSQL = source of truth).
usage: python3 02_operations.py [mongo_uri] [pg_dsn]      Tested on MongoDB 7.0 (3-node replica set)."""
import sys, time, statistics, json, datetime as dt, pymongo, psycopg
import os
MG = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("MONGO_URI", "mongodb://127.0.0.1:27017,127.0.0.1:27018,127.0.0.1:27019/?replicaSet=rs0")
PG = sys.argv[2] if len(sys.argv) > 2 else "dbname=nairalink"
client = pymongo.MongoClient(MG); db = client["nairalink_nosql"]; pg = psycopg.connect(PG, autocommit=True)
print("Connected to MongoDB", client.server_info()["version"], "| replica set primary:", client.primary)
def H(t): print(f"\n{'='*78}\n{t}\n{'='*78}", flush=True)
def med(fn, n=7):
    ts = []
    for _ in range(n):
        t = time.perf_counter(); r = fn(); ts.append((time.perf_counter() - t) * 1000)
    return round(statistics.median(ts), 2), r
def stage(plan):                       # walk winningPlan and return the stage chain, e.g. LIMIT > FETCH > IXSCAN
    out = []
    while plan:
        out.append(plan["stage"]); plan = plan.get("inputStage") or (plan.get("inputStages") or [None])[0]
    return " > ".join(out)
def explain(coll, flt, sort=None, limit=0):
    cmd = {"find": coll, "filter": flt}
    if sort: cmd["sort"] = dict(sort)
    if limit: cmd["limit"] = limit
    e = db.command({"explain": cmd, "verbosity": "executionStats"}); es = e["executionStats"]
    return f"{stage(e['queryPlanner']['winningPlan'])} | docsExamined={es['totalDocsExamined']} keysExamined={es['totalKeysExamined']} returned={es['nReturned']} serverTime={es['executionTimeMillis']}ms"

H("0. Collection sizes")
for c in ("customer_profiles", "rate_buckets", "trade_events", "price_alerts"): print(f"{c:20}", db[c].count_documents({}))

H("1. Profile screen: ONE document read replaces joins over customers + kyc + devices + prefs + wallets")
t, doc = med(lambda: db.customer_profiles.find_one({"_id": 4}))
print(f"find_one(_id=4) median {t} ms (primary-key lookup)")
print(json.dumps({"_id": doc["_id"], "full_name": doc["full_name"], "kyc_tier": doc["kyc"]["tier"], "kyc_documents": [(d["type"], d["status"]) for d in doc["kyc"]["documents"]],
                  "devices": len(doc["devices"]), "notification_prefs": doc["notification_prefs"], "wallets_cache": doc["wallets_cache"]["wallets"]}, default=str))

H("2. Compliance: queries INTO embedded arrays ($elemMatch = both conditions on the SAME array element)")
f = {"kyc.documents": {"$elemMatch": {"status": {"$in": ["REJECTED", "PENDING"]}}}}
t, n = med(lambda: db.customer_profiles.count_documents(f), 3)
truth = sum(1 for d in db.customer_profiles.find({}, {"kyc.documents.status": 1}) if any(x["status"] in ("REJECTED", "PENDING") for x in d["kyc"]["documents"]))
print(f"profiles with a REJECTED/PENDING document: {n}  (brute-force Python check = {truth} -> {'MATCH' if n == truth else 'MISMATCH'}; {t} ms)")
now = dt.datetime.now(dt.timezone.utc)
f2 = {"kyc.tier": {"$gte": 2}, "kyc.documents": {"$elemMatch": {"type": "NIN", "expires_at": {"$lt": now}}}}
n2 = db.customer_profiles.count_documents(f2)
truth2 = sum(1 for d in db.customer_profiles.find({"kyc.tier": {"$gte": 2}}) if any(x["type"] == "NIN" and x["expires_at"] and x["expires_at"].replace(tzinfo=dt.timezone.utc) < now for x in d["kyc"]["documents"]))
print(f"tier>=2 customers whose NIN document has EXPIRED: {n2}  (brute force = {truth2} -> {'MATCH' if n2 == truth2 else 'MISMATCH'})")

H("3. Market data: daily OHLC-style summary from hourly buckets (aggregation) - verified against PostgreSQL")
pipe = [{"$match": {"pair": "USD/NGN"}},
        {"$group": {"_id": "$day", "high": {"$max": "$high"}, "low": {"$min": "$low"}, "ticks": {"$sum": "$n"}, "avg_close": {"$avg": "$close"}}},
        {"$sort": {"_id": -1}}, {"$limit": 5}]
t, res = med(lambda: list(db.rate_buckets.aggregate(pipe))); print(f"pipeline median {t} ms (scans 4,312 bucket docs instead of 80,000 tick rows)")
bad = 0
for r in res:
    h, l, c = pg.execute("""SELECT max((bid+ask)/2)::float8, min((bid+ask)/2)::float8, count(*) FROM fx.fx_rates
                           WHERE base_ccy='USD' AND quote_ccy='NGN' AND lp_id=1 AND date_trunc('day',captured_at AT TIME ZONE 'UTC')=%s::date""", (r["_id"],)).fetchone()
    ok = abs(h - r["high"]) < 1e-6 and abs(l - r["low"]) < 1e-6 and c == r["ticks"]; bad += (not ok)
    print(f"  {r['_id']}  mongo high={r['high']:.4f} low={r['low']:.4f} ticks={r['ticks']} | postgres high={h:.4f} low={l:.4f} ticks={c} -> {'MATCH' if ok else 'MISMATCH'}")
print("cross-check:", "ALL MATCH" if not bad else f"{bad} MISMATCH")

H("4. Customer trade history (latest 20): COLLSCAN vs compound index {customer_id:1, ts:-1}  (explain executionStats)")
q = lambda: list(db.trade_events.find({"customer_id": 777}, {"details": 1, "type": 1, "ts": 1}).sort("ts", -1).limit(20))
db.trade_events.drop_indexes(); t0, _ = med(q); p0 = explain("trade_events", {"customer_id": 777}, [("ts", -1)], 20)
db.trade_events.create_index([("customer_id", 1), ("ts", -1)], name="cust_ts"); t1, r1 = med(q); p1 = explain("trade_events", {"customer_id": 777}, [("ts", -1)], 20)
print(f"BEFORE index: {t0} ms\n   plan: {p0}\nAFTER  index: {t1} ms\n   plan: {p1}\nspeed-up x{round(t0 / max(t1, 0.01))}")
nm = db.trade_events.count_documents({"customer_id": 777})
npg = pg.execute("SELECT count(*) FROM fx.transactions WHERE customer_id=777 AND txn_type IN ('FX_CONVERSION','FUNDING','WITHDRAWAL') AND reference NOT LIKE 'STRESS%%' AND reference NOT LIKE 'A%%-%%'").fetchone()[0]
print(f"events for customer 777: mongo={nm} postgres={npg} -> {'MATCH' if nm == npg else 'MISMATCH'}")

H("5. Polymorphic documents: monthly FX volume per bought currency ($group on nested `details` fields) vs PostgreSQL")
pipe = [{"$match": {"type": "FX_CONVERSION", "month": "2026-10"}},
        {"$group": {"_id": "$details.buy_ccy", "orders": {"$sum": 1}, "ngn_volume": {"$sum": "$details.sell_amount"}, "fees": {"$sum": "$details.fee"}}}, {"$sort": {"_id": 1}}]
t, res = med(lambda: list(db.trade_events.aggregate(pipe))); print(f"median {t} ms")
for r in res:
    c, v = pg.execute("""SELECT count(*), sum(o.sell_amount)::float8 FROM fx.fx_orders o JOIN fx.wallets w ON w.wallet_id=o.buy_wallet
                         JOIN fx.transactions t ON t.txn_id=o.txn_id WHERE w.currency_code=%s AND to_char(t.created_at,'YYYY-MM')='2026-10' AND t.reference LIKE 'FXC-%%'""", (r["_id"],)).fetchone()
    print(f"  {r['_id']}: mongo orders={r['orders']} volume={r['ngn_volume']:,.0f} | postgres orders={c} volume={v:,.0f} -> {'MATCH' if c == r['orders'] and abs(v - r['ngn_volume']) < 1 else 'MISMATCH'}")

H("6. $lookup (join) + $unwind: top 5 customers by NGN converted, enriched with name and KYC tier from customer_profiles")
pipe = [{"$match": {"type": "FX_CONVERSION"}}, {"$group": {"_id": "$customer_id", "ngn": {"$sum": "$details.sell_amount"}, "n": {"$sum": 1}}},
        {"$sort": {"ngn": -1}}, {"$limit": 5},
        {"$lookup": {"from": "customer_profiles", "localField": "_id", "foreignField": "_id", "as": "p"}}, {"$unwind": "$p"},
        {"$project": {"ngn": 1, "n": 1, "name": "$p.full_name", "tier": "$p.kyc.tier"}}]
t, res = med(lambda: list(db.trade_events.aggregate(pipe)), 3); print(f"median {t} ms")
top_pg = pg.execute("SELECT o.customer_id, sum(o.sell_amount)::float8, count(*) FROM fx.fx_orders o JOIN fx.transactions t USING(txn_id) WHERE t.reference LIKE 'FXC-%%' GROUP BY 1 ORDER BY 2 DESC LIMIT 5").fetchall()
for r, p in zip(res, top_pg): print(f"  mongo {r['_id']:>6} {r['name']:<18} tier {r['tier']} {r['ngn']:>14,.0f} ({r['n']} orders) | postgres {p[0]:>6} {p[1]:>14,.0f} ({p[2]}) -> {'MATCH' if r['_id']==p[0] and abs(r['ngn']-p[1])<1 else 'MISMATCH'}")

H("7. Price alerts: which ACTIVE alerts fire at the latest USD/NGN level? (compound index pair/active/direction/target)")
lvl = db.rate_buckets.find({"pair": "USD/NGN"}).sort("hour", -1).limit(1)[0]["close"]; print(f"latest USD/NGN level = {lvl:.2f}")
fire = {"pair": "USD/NGN", "active": True, "$or": [{"direction": "ABOVE", "target": {"$lte": lvl}}, {"direction": "BELOW", "target": {"$gte": lvl}}]}
db.price_alerts.drop_indexes(); t0, n0 = med(lambda: db.price_alerts.count_documents(fire)); p0 = explain("price_alerts", fire)
db.price_alerts.create_index([("pair", 1), ("active", 1), ("direction", 1), ("target", 1)], name="alert_match"); t1, n1 = med(lambda: db.price_alerts.count_documents(fire)); p1 = explain("price_alerts", fire)
print(f"{n1} alerts fire (same before/after: {n0 == n1})\nBEFORE: {t0} ms  {p0}\nAFTER : {t1} ms  {p1}")

H("8. Atomic single-document update: approve a PENDING KYC document + upgrade tier + audit entry in ONE write")
target = db.customer_profiles.find_one({"kyc.tier": 1, "kyc.documents": {"$elemMatch": {"status": "PENDING"}}})
print("before:", target["_id"], "tier", target["kyc"]["tier"], [(d["type"], d["status"]) for d in target["kyc"]["documents"]])
pend = next(d["type"] for d in target["kyc"]["documents"] if d["status"] == "PENDING")
r = db.customer_profiles.update_one({"_id": target["_id"], "kyc.documents.type": pend},
        {"$set": {"kyc.documents.$.status": "VERIFIED", "kyc.documents.$.verified_at": now, "kyc.tier": 2},
         "$push": {"audit": {"at": now, "action": "KYC_UPGRADE", "by": "ops.agent.01"}}})
a = db.customer_profiles.find_one({"_id": target["_id"]})
print("matched/modified:", r.matched_count, r.modified_count, "\nafter :", a["_id"], "tier", a["kyc"]["tier"], [(d["type"], d["status"]) for d in a["kyc"]["documents"]], "| audit:", a["audit"][0]["action"])
db.customer_profiles.replace_one({"_id": target["_id"]}, target)       # restore so Mongo still agrees with PostgreSQL

H("9. Multi-document ACID transaction (replica set): upgrade profile AND write a compliance event together - commit vs abort")
cid = target["_id"]
def upgrade(fail):
    with client.start_session() as s:
        try:
            with s.start_transaction(read_concern=pymongo.read_concern.ReadConcern("snapshot"), write_concern=pymongo.WriteConcern("majority")):
                db.customer_profiles.update_one({"_id": cid}, {"$set": {"kyc.tier": 3}}, session=s)
                db.trade_events.insert_one({"_id": f"KYC-{cid}-{int(time.time())}", "customer_id": cid, "type": "KYC_UPGRADE", "status": "SUCCESS", "ts": now, "month": f"{now:%Y-%m}", "details": {"to_tier": 3}}, session=s)
                if fail: raise RuntimeError("simulated failure after both writes")
            return "COMMITTED"
        except RuntimeError as e:
            return f"ABORTED ({e})"
def snap(): return db.customer_profiles.find_one({"_id": cid})["kyc"]["tier"], db.trade_events.count_documents({"customer_id": cid, "type": "KYC_UPGRADE"})
print("start (tier, kyc events):", snap()); print("with failure ->", upgrade(True), "| state:", snap(), "(nothing changed: atomic rollback across 2 collections)")
print("without failure ->", upgrade(False), "| state:", snap())
db.customer_profiles.replace_one({"_id": cid}, target); db.trade_events.delete_many({"customer_id": cid, "type": "KYC_UPGRADE"})

H("10. Schema flexibility: add a field to only some documents - no migration, no downtime")
db.customer_profiles.update_many({"_id": {"$in": [4, 5, 9]}}, {"$set": {"preferences.theme": "dark"}})
print("profiles with preferences.theme:", db.customer_profiles.count_documents({"preferences.theme": {"$exists": True}}), "of", db.customer_profiles.count_documents({}))
db.customer_profiles.update_many({}, {"$unset": {"preferences": ""}})

H("11. Storage and indexes")
for c in ("customer_profiles", "rate_buckets", "trade_events", "price_alerts"):
    s = db.command("collStats", c); print(f"{c:18} docs={s['count']:>7} dataSize={s['size']/1e6:7.1f} MB indexSize={s['totalIndexSize']/1e6:6.1f} MB indexes={[i['name'] for i in db[c].list_indexes()]}")
