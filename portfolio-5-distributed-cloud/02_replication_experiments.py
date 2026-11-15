#!/usr/bin/env python3
"""Portfolio 5 - replication, consistency and availability experiments on the NairaLink FX PostgreSQL primary + standby.
usage: python3 02_replication_experiments.py   (edit the constants / REPLICA_CTL for your machine)"""
import time, statistics, threading, subprocess, random, psycopg
from psycopg import errors
import os
# Connection strings (libpq also honours PGPASSWORD). Override with env vars on your machine.
P = os.environ.get("PRIMARY_DSN", "port=5432 dbname=nairalink"); R = os.environ.get("REPLICA_DSN", "port=5433 dbname=nairalink")
# How to stop/start the standby. Native default = my workspace. Docker mode: MODE=docker  (uses `docker stop/start pg-replica`).
def REPLICA_CTL(action):
    if os.environ.get("MODE") == "docker":
        cmd = ["docker", "stop", "pg-replica"] if action.startswith("stop") else ["docker", "start", "pg-replica"]
        return subprocess.run(cmd, capture_output=True, text=True)
    return subprocess.run(["su", "pguser", "-c", f"/usr/lib/postgresql/16/bin/pg_ctl -D /var/pgdata/replica -o '-p 5433 -c hot_standby=on' -l /var/pgdata/replica.log -w {action}"], capture_output=True, text=True)
def H(t): print(f"\n{'='*78}\n{t}\n{'='*78}", flush=True)
def q1(c, sql, a=()): return c.execute(sql, a).fetchone()[0]
pri = psycopg.connect(P, autocommit=True); rep = psycopg.connect(R, autocommit=True)
pri.execute("CREATE TABLE IF NOT EXISTS fx.repl_probe(id bigserial PRIMARY KEY, payload text, ts timestamptz DEFAULT clock_timestamp())")
pri.execute("ALTER SYSTEM SET synchronous_standby_names = ''"); pri.execute("SELECT pg_reload_conf()")
pri.execute("SET synchronous_commit = on")

H("E1  Standby is read-only: writes are rejected, reads work")
print("primary pg_is_in_recovery():", q1(pri, "SELECT pg_is_in_recovery()"), "| standby:", q1(rep, "SELECT pg_is_in_recovery()"))
print("standby read  -> customers:", q1(rep, "SELECT count(*) FROM fx.customers"), "| primary:", q1(pri, "SELECT count(*) FROM fx.customers"))
try: rep.execute("INSERT INTO fx.repl_probe(payload) VALUES ('x')")
except Exception as e: print("standby write -> ERROR:", str(e).splitlines()[0])

def wait_visible(marker, timeout=5):
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < timeout:
        if q1(rep, "SELECT count(*) FROM fx.repl_probe WHERE id=%s", (marker,)): return (time.perf_counter() - t0) * 1000
    return None

H("E2  Asynchronous replication: time until a committed row becomes visible on the standby (60 trials, idle system)")
lat = []
for _ in range(60):
    mk = q1(pri, "INSERT INTO fx.repl_probe(payload) VALUES ('async') RETURNING id"); lat.append(wait_visible(mk))
lat.sort(); print(f"visible after: min {lat[0]:.2f} ms | median {statistics.median(lat):.2f} ms | p95 {lat[int(.95*len(lat))]:.2f} ms | max {lat[-1]:.2f} ms")

H("E3  Stale reads (read-your-writes violation) under ASYNC: write on primary, read IMMEDIATELY from standby (300 trials)")
stale = 0
for _ in range(300):
    mk = q1(pri, "INSERT INTO fx.repl_probe(payload) VALUES ('stale-test') RETURNING id")
    if not q1(rep, "SELECT count(*) FROM fx.repl_probe WHERE id=%s", (mk,)): stale += 1
print(f"stale reads: {stale} / 300 ({stale/3:.1f}%)  -> async replication is eventually consistent for reads on the standby")

H("E4  Replication lag under a write burst (8 workers x 300 FX conversions on the primary)")
custs = [r[0] for r in pri.execute("SELECT customer_id FROM fx.customers WHERE kyc_tier=2 AND status='ACTIVE' AND customer_id>300 ORDER BY 1 LIMIT 300").fetchall()]
stop = threading.Event(); samples = []
def sampler():
    c = psycopg.connect(P, autocommit=True)
    while not stop.is_set():
        r = c.execute("SELECT pg_wal_lsn_diff(sent_lsn, replay_lsn), COALESCE(extract(epoch FROM replay_lag)*1000,0) FROM pg_stat_replication").fetchone()
        samples.append((float(r[0]), float(r[1]))); time.sleep(0.02)
def worker(k):
    c = psycopg.connect(P, autocommit=True); rnd = random.Random(k)
    for i in range(300):
        try: c.execute("SELECT fx.convert_currency(%s,%s,%s,%s)", (rnd.choice(custs), rnd.choice(['USD','GBP','EUR']), rnd.randrange(20000, 80000, 1000), f"P5-{int(time.time())}-{k}-{i}"))
        except Exception: pass
ts = [threading.Thread(target=worker, args=(k,)) for k in range(8)]; sm = threading.Thread(target=sampler); sm.start()
t0 = time.perf_counter(); [t.start() for t in ts]; [t.join() for t in ts]; el = time.perf_counter() - t0; time.sleep(0.5); stop.set(); sm.join()
print(f"2,400 conversions in {el:.1f}s  | peak replay backlog {max(s[0] for s in samples)/1024:.0f} KB | peak replay_lag {max(s[1] for s in samples):.0f} ms | final backlog {samples[-1][0]:.0f} bytes")
print("primary vs standby row counts after burst:", q1(pri, "SELECT count(*) FROM fx.ledger_entries"), "/", q1(rep, "SELECT count(*) FROM fx.ledger_entries"))

H("E5  SYNCHRONOUS replication: commit waits for the standby (synchronous_standby_names='replica1')")
def commit_latency(n=300):
    xs = []
    for _ in range(n):
        t = time.perf_counter(); pri.execute("INSERT INTO fx.repl_probe(payload) VALUES ('lat')"); xs.append((time.perf_counter() - t) * 1000)
    xs.sort(); return statistics.median(xs), xs[int(.95 * n)]
pri.execute("SET synchronous_commit = on"); a50, a95 = commit_latency()
pri.execute("ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)'"); pri.execute("SELECT pg_reload_conf()"); time.sleep(1)
print("sync_state now:", q1(pri, "SELECT sync_state FROM pg_stat_replication"))
pri.execute("SET synchronous_commit = on"); s50, s95 = commit_latency()
pri.execute("SET synchronous_commit = remote_apply"); r50, r95 = commit_latency()
print(f"commit latency  async: p50 {a50:.2f} ms p95 {a95:.2f} ms | sync (remote_write/flush): p50 {s50:.2f} ms p95 {s95:.2f} ms | sync remote_apply: p50 {r50:.2f} ms p95 {r95:.2f} ms")
stale = 0
for _ in range(300):
    mk = q1(pri, "INSERT INTO fx.repl_probe(payload) VALUES ('ra') RETURNING id")
    if not q1(rep, "SELECT count(*) FROM fx.repl_probe WHERE id=%s", (mk,)): stale += 1
print(f"stale reads with synchronous_commit=remote_apply: {stale} / 300  -> read-your-writes guaranteed on the standby (at a latency cost)")

H("E6  CAP in practice: standby goes DOWN while synchronous replication is required")
print("stopping standby ...", REPLICA_CTL("stop -m fast").returncode == 0)
blocked = {}
def blocked_commit():
    c = psycopg.connect(P, autocommit=True); c.execute("SET synchronous_commit = on")
    blocked["conn"] = c; t = time.perf_counter()
    try: c.execute("INSERT INTO fx.repl_probe(payload) VALUES ('while-standby-down')"); blocked["res"] = "returned"
    except Exception as e: blocked["res"] = type(e).__name__
    blocked["secs"] = time.perf_counter() - t
th = threading.Thread(target=blocked_commit); th.start(); time.sleep(3)
print(f"after 3 s the client's COMMIT is still waiting: {th.is_alive()}  (primary refuses to acknowledge until a standby confirms -> consistency over availability)")
blocked["conn"].cancel(); th.join()
print(f"client gave up (cancel). Note: the row IS committed locally but was NOT replicated: visible on primary = {q1(pri, 'SELECT count(*) FROM fx.repl_probe WHERE payload=%s', ('while-standby-down',))}")
pri.execute("ALTER SYSTEM SET synchronous_standby_names = ''"); pri.execute("SELECT pg_reload_conf()"); time.sleep(0.5)
t = time.perf_counter(); pri.execute("INSERT INTO fx.repl_probe(payload) VALUES ('async-fallback')"); print(f"after relaxing to ASYNC the commit returns in {(time.perf_counter()-t)*1000:.1f} ms (availability restored, durability on a single node)")
print("restarting standby ...", REPLICA_CTL("start").returncode == 0); rep = None
for _ in range(30):
    try: rep = psycopg.connect(R, autocommit=True); break
    except Exception: time.sleep(1)
time.sleep(2)
print("standby caught up: primary/standby probe rows =", q1(pri, "SELECT count(*) FROM fx.repl_probe"), "/", q1(rep, "SELECT count(*) FROM fx.repl_probe"))
print("final state:", pri.execute("SELECT application_name, state, sync_state FROM pg_stat_replication").fetchall())
