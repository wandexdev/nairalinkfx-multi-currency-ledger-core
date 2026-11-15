#!/usr/bin/env python3
"""Portfolio 5 - PostgreSQL failover with SYNCHRONOUS replication: kill the primary mid-write-stream, promote the standby,
verify that no acknowledged commit was lost (RPO = 0) and measure how long writes were unavailable (RTO).
Run AFTER 01_pg_streaming_replication.sh and 02_replication_experiments.py.  WARNING: destroys the primary (that is the point)."""
import time, threading, subprocess, psycopg
import os
P = os.environ.get("PRIMARY_DSN", "port=5432 dbname=nairalink") + " connect_timeout=2"; R = os.environ.get("REPLICA_DSN", "port=5433 dbname=nairalink")
PGCTL = "/usr/lib/postgresql/16/bin/pg_ctl"
DOCKER = os.environ.get("MODE") == "docker"
def kill_primary():     # abrupt stop, no shutdown checkpoint (power-cut simulation)
    r = subprocess.run(["docker", "kill", "pg-primary"], capture_output=True, text=True) if DOCKER else subprocess.run(["su", "pguser", "-c", f"{PGCTL} -D /var/pgdata/primary stop -m immediate"], capture_output=True, text=True)
    return r.returncode == 0
def promote_standby():
    if DOCKER: subprocess.run(["docker", "exec", "-u", "postgres", "pg-replica", "pg_ctl", "promote", "-D", "/var/lib/postgresql/data", "-w"], capture_output=True, text=True)
    else: subprocess.run(["su", "pguser", "-c", f"{PGCTL} -D /var/pgdata/replica promote -w"], capture_output=True, text=True)
def H(t): print(f"\n{'='*78}\n{t}\n{'='*78}", flush=True)
q1 = lambda c, s, a=(): c.execute(s, a).fetchone()[0]
pri = psycopg.connect(P, autocommit=True); rep = psycopg.connect(R, autocommit=True)

H("F0  Setup: synchronous replication ON (a commit is acknowledged only after the standby has the WAL)")
pri.execute("ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (replica1)'"); pri.execute("SELECT pg_reload_conf()"); time.sleep(1)
print("primary replication state:", pri.execute("SELECT application_name, state, sync_state FROM pg_stat_replication").fetchall())
print("WAL timeline before:", int(q1(pri, "SELECT substr(pg_walfile_name(pg_current_wal_lsn()),1,8)"), 16))

H("F1  A writer inserts continuously; the primary is killed with `pg_ctl stop -m immediate` (like a power cut: no shutdown checkpoint)")
acked, stop, t_fail = [], threading.Event(), {}
def writer():
    c = psycopg.connect(P, autocommit=True); i = 0
    while not stop.is_set():
        try: mk = q1(c, "INSERT INTO fx.repl_probe(payload) VALUES (%s) RETURNING id", (f"failover-{i}",)); acked.append(mk); i += 1
        except Exception: t_fail.setdefault("t", time.perf_counter()); break
th = threading.Thread(target=writer); th.start(); time.sleep(2)
t_kill = time.perf_counter(); ok = kill_primary(); print("primary stopped:", ok, f"| {len(acked)} commits had been ACKNOWLEDGED to the client")
th.join(); stop.set()

H("F2  Promote the standby (`pg_ctl promote`) and measure time until it accepts writes")
t_p = time.perf_counter(); promote_standby()
rep = psycopg.connect(R, autocommit=True)
while q1(rep, "SELECT pg_is_in_recovery()"): time.sleep(0.05)
new_id = q1(rep, "INSERT INTO fx.repl_probe(payload) VALUES ('first-write-on-new-primary') RETURNING id")
t_ok = time.perf_counter()
print(f"standby promoted; first successful write on the NEW primary after {t_ok - t_kill:.2f} s from the failure (promotion step itself {t_ok - t_p:.2f} s)")
print("new primary: pg_is_in_recovery() =", q1(rep, "SELECT pg_is_in_recovery()"), "| WAL timeline now =", int(q1(rep, "SELECT substr(pg_walfile_name(pg_current_wal_lsn()),1,8)"), 16), "(was 1: the timeline increments at promotion, so the old primary's history cannot be confused with the new one)")

H("F3  Did we lose any acknowledged commit? (RPO check)")
present = {r[0] for r in rep.execute("SELECT id FROM fx.repl_probe WHERE payload LIKE 'failover-%'").fetchall()}
lost = [a for a in acked if a not in present]
print(f"acknowledged commits: {len(acked)} | present on promoted standby: {len(present)} | LOST: {len(lost)} -> {'RPO = 0 (synchronous replication)' if not lost else 'DATA LOSS'}")
print(f"commits present but never acknowledged to the client: {len(present - set(acked))} (the standby had it when the primary died, before the ack reached the app - safe, but the app must treat it as 'unknown' and retry idempotently, exactly like our idempotency key design)")
print("business data intact on the new primary: ledger lines =", q1(rep, "SELECT count(*) FROM fx.ledger_entries"), "| wallets/ledger reconcile mismatches =",
      q1(rep, """SELECT count(*) FROM fx.wallets w JOIN (SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) s FROM fx.ledger_entries GROUP BY 1) l USING (wallet_id) WHERE w.balance<>l.s"""))
print("conversion on the new primary:", q1(rep, "SELECT fx.convert_currency(4,'USD',10000,%s)", (f'POST-FAILOVER-{int(time.time())}',)), "(FX conversion committed on the promoted node)")
