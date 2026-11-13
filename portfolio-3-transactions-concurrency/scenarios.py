#!/usr/bin/env python3
"""Portfolio 3 - transactions & concurrency demonstrations on the NairaLink FX database.
Run:  python3 scenarios.py [dsn]        Output is narrated so it can be saved as evidence.
Sandbox customers/wallets are created for the anomaly demos and deleted afterwards, so the
real ledger stays reconciled."""
import sys, time, threading, psycopg
from psycopg import errors
from psycopg import IsolationLevel as IL
DSN = sys.argv[1] if len(sys.argv) > 1 else "dbname=nairalink"

def H(t): print(f"\n{'='*78}\n{t}\n{'='*78}", flush=True)
def P(*a): print(*a, flush=True)
def conn(iso=None, autocommit=False):
    c = psycopg.connect(DSN, autocommit=autocommit)
    if iso: c.isolation_level = iso
    return c
def q1(c, sql, args=()):
    return c.execute(sql, args).fetchone()[0]
def rows(c, sql, args=()):
    return c.execute(sql, args).fetchall()

# --------------------------------------------------------------------- setup
adm = conn(autocommit=True)
adm.execute("SET search_path = fx, public")
CUST = q1(adm, "SELECT customer_id FROM fx.customers WHERE kyc_tier=2 AND status='ACTIVE' ORDER BY customer_id LIMIT 1")
def bal(c, cust, ccy):
    return q1(c, "SELECT balance FROM fx.wallets WHERE customer_id=%s AND currency_code=%s", (cust, ccy))
RUN = str(int(time.time()))

# ===================================================================== A. ATOMICITY
H("A1  COMMIT: successful FX conversion (sell 100,000 NGN for USD) - customer %d" % CUST)
b = (bal(adm, CUST, 'NGN'), bal(adm, CUST, 'USD'))
P("before : NGN %s | USD %s" % b)
txn = q1(adm, "SELECT fx.convert_currency(%s,'USD',100000,%s)", (CUST, f"A1-{RUN}"))
a = (bal(adm, CUST, 'NGN'), bal(adm, CUST, 'USD'))
P("after  : NGN %s | USD %s   (txn_id=%s)" % (a + (txn,)))
P("ledger legs posted:")
for r in rows(adm, "SELECT le.direction, w.customer_id, w.currency_code, w.wallet_type, le.amount, le.balance_after FROM fx.ledger_entries le JOIN fx.wallets w USING(wallet_id) WHERE txn_id=%s ORDER BY entry_id", (txn,)):
    P("   ", r)
P("order  :", rows(adm, "SELECT sell_amount, buy_amount, rate_applied, fee_amount FROM fx.fx_orders WHERE txn_id=%s", (txn,))[0])

H("A2  ROLLBACK: conversion that fails (insufficient funds) leaves NO trace")
b = (bal(adm, CUST, 'NGN'), bal(adm, CUST, 'USD'))
try:
    adm.execute("SELECT fx.convert_currency(%s,'USD',99999999999,%s)", (CUST, f"A2-{RUN}"))
except Exception as e:
    P("error  :", str(e).splitlines()[0])
a = (bal(adm, CUST, 'NGN'), bal(adm, CUST, 'USD'))
P("balances unchanged:", a == b, a)
P("txn row exists for failed reference:", q1(adm, "SELECT count(*) FROM fx.transactions WHERE reference=%s", (f"A2-{RUN}",)) > 0)

H("A3  Manual transaction: ROLLBACK mid-way, then SAVEPOINT partial rollback")
c = conn(); wid = q1(c, "SELECT wallet_id FROM fx.wallets WHERE customer_id=%s AND currency_code='GBP'", (CUST,))
start = q1(c, "SELECT balance FROM fx.wallets WHERE wallet_id=%s", (wid,))
c.execute("UPDATE fx.wallets SET balance = balance + 500 WHERE wallet_id=%s", (wid,))
P("inside txn (uncommitted) GBP balance:", q1(c, "SELECT balance FROM fx.wallets WHERE wallet_id=%s", (wid,)), "| other session sees:", bal(adm, CUST, 'GBP'))
c.rollback()
P("after ROLLBACK GBP balance:", bal(adm, CUST, 'GBP'), "(was", start, ")")
c.execute("SAVEPOINT s1")
c.execute("UPDATE fx.wallets SET balance = balance + 1 WHERE wallet_id=%s", (wid,))
c.execute("SAVEPOINT s2")
try:
    c.execute("UPDATE fx.wallets SET balance = -5 WHERE wallet_id=%s", (wid,))     # violates chk_no_overdraft
except errors.CheckViolation as e:
    P("constraint blocked bad update ->", str(e).splitlines()[0]); c.execute("ROLLBACK TO SAVEPOINT s2")
c.rollback(); c.close()

H("A4  IDEMPOTENCY: retrying the same request reference does not double-charge")
r1 = q1(adm, "SELECT fx.convert_currency(%s,'EUR',50000,%s)", (CUST, f"A4-{RUN}"))
n1 = bal(adm, CUST, 'NGN')
r2 = q1(adm, "SELECT fx.convert_currency(%s,'EUR',50000,%s)", (CUST, f"A4-{RUN}"))
n2 = bal(adm, CUST, 'NGN')
P(f"first call txn={r1}, retry txn={r2}, same={r1==r2}; NGN balance after 1st={n1}, after retry={n2}, charged once={n1==n2}")

H("A5  REVERSAL: undo the A1 conversion with offsetting entries (history never edited)")
b = (bal(adm, CUST, 'NGN'), bal(adm, CUST, 'USD'))
rev = q1(adm, "SELECT fx.reverse_conversion(%s,%s)", (txn, f"A5-{RUN}"))
a = (bal(adm, CUST, 'NGN'), bal(adm, CUST, 'USD'))
P("before reversal NGN/USD:", b, "| after:", a)
P("original txn status:", rows(adm, "SELECT txn_id,status FROM fx.transactions WHERE txn_id=%s", (txn,))[0],
  "| reversal txn:", rows(adm, "SELECT txn_id,txn_type,reversal_of FROM fx.transactions WHERE txn_id=%s", (rev,))[0])
try:
    adm.execute("SELECT fx.reverse_conversion(%s,%s)", (txn, f"A5b-{RUN}"))
except Exception as e:
    P("second reversal rejected ->", str(e).splitlines()[0])

H("A6  Business-rule rejections inside the procedure")
tier0 = q1(adm, "SELECT customer_id FROM fx.customers WHERE kyc_tier=0 AND status='ACTIVE' LIMIT 1")
for label, args in [("KYC tier 0 customer", (tier0, 'USD', 1000, f"A6a-{RUN}")),
                    ("daily limit (tier 2: 5,000,000/day)", (CUST, 'USD', 6000000, f"A6b-{RUN}")),
                    ("unsupported currency", (CUST, 'JPY', 1000, f"A6c-{RUN}")),
                    ("negative amount", (CUST, 'USD', -5, f"A6d-{RUN}"))]:
    try:
        adm.execute("SELECT fx.convert_currency(%s,%s,%s,%s)", args); P(label, "-> UNEXPECTEDLY accepted")
    except Exception as e:
        P(f"{label:42} -> rejected: {str(e).splitlines()[0]}")

# ===================================================================== sandbox
adm.execute("INSERT INTO fx.customers(email,phone,full_name,kyc_tier) VALUES (%s,%s,'Sandbox A',2),(%s,%s,'Sandbox B',2)",
            (f"sbx1-{RUN}@x.example", f"+2349{RUN[-9:]}", f"sbx2-{RUN}@x.example", f"+2348{RUN[-9:]}"))
SB = [r[0] for r in rows(adm, "SELECT customer_id FROM fx.customers WHERE email LIKE %s ORDER BY 1", (f"sbx_-{RUN}@x.example",))]
for s in SB:
    adm.execute("INSERT INTO fx.wallets(customer_id,currency_code,balance) VALUES (%s,'NGN',1000),(%s,'USD',1000)", (s, s))
W1, W2 = [q1(adm, "SELECT wallet_id FROM fx.wallets WHERE customer_id=%s AND currency_code='NGN'", (s,)) for s in SB]
def reset(): adm.execute("UPDATE fx.wallets SET balance=1000 WHERE wallet_id IN (%s,%s)", (W1, W2))

# ===================================================================== B. CONCURRENCY
H("B1  LOST UPDATE (READ COMMITTED): two sessions each withdraw 100 from a 1000 balance. Correct final = 800")
def lost_update(mode):
    reset(); bar = threading.Barrier(2, timeout=5); out = {}
    def worker(name):
        c = conn(); 
        try:
            if mode == "naive":      # read in app, compute, write back  (BUG)
                bl = q1(c, "SELECT balance FROM fx.wallets WHERE wallet_id=%s", (W1,)); bar.wait()
                time.sleep(0 if name == "A" else 0.3)
                c.execute("UPDATE fx.wallets SET balance=%s WHERE wallet_id=%s", (bl - 100, W1))
            elif mode == "for_update":   # pessimistic lock
                bl = q1(c, "SELECT balance FROM fx.wallets WHERE wallet_id=%s FOR UPDATE", (W1,)); time.sleep(0.3)
                c.execute("UPDATE fx.wallets SET balance=%s WHERE wallet_id=%s", (bl - 100, W1))
            elif mode == "atomic":       # let the database do the arithmetic
                time.sleep(0.3 if name == "B" else 0)
                c.execute("UPDATE fx.wallets SET balance=balance-100 WHERE wallet_id=%s", (W1,))
            elif mode == "optimistic":   # version check + retry
                for attempt in range(5):
                    bl, v = rows(c, "SELECT balance, version FROM fx.wallets WHERE wallet_id=%s", (W1,))[0]
                    if attempt == 0:
                        try: bar.wait()
                        except threading.BrokenBarrierError: pass
                        time.sleep(0 if name == "A" else 0.3)
                    cur = c.execute("UPDATE fx.wallets SET balance=%s WHERE wallet_id=%s AND version=%s", (bl - 100, W1, v))
                    if cur.rowcount == 1: out[name] = f"ok after {attempt+1} attempt(s)"; break
                    c.rollback()
            c.commit()
        finally: c.close()
    ts = [threading.Thread(target=worker, args=(n,)) for n in "AB"]
    [t.start() for t in ts]; [t.join() for t in ts]
    return bal(adm, SB[0], 'NGN'), out
for mode, label in [("naive", "NAIVE read-modify-write          "), ("for_update", "FIX 1 SELECT ... FOR UPDATE        "),
                    ("atomic", "FIX 2 atomic UPDATE balance=balance-100"), ("optimistic", "FIX 3 optimistic version check + retry")]:
    final, extra = lost_update(mode)
    P(f"{label}: final balance = {final}  -> {'CORRECT' if final == 800 else 'LOST UPDATE (expected 800)'} {extra if extra else ''}")

H("B2  NON-REPEATABLE READ: read a balance twice while another session commits a change in between")
for iso, nm in [(IL.READ_COMMITTED, "READ COMMITTED"), (IL.REPEATABLE_READ, "REPEATABLE READ")]:
    reset(); s1 = conn(iso)
    r1 = q1(s1, "SELECT balance FROM fx.wallets WHERE wallet_id=%s", (W1,))
    adm.execute("UPDATE fx.wallets SET balance=balance+250 WHERE wallet_id=%s", (W1,))     # session 2 commits
    r2 = q1(s1, "SELECT balance FROM fx.wallets WHERE wallet_id=%s", (W1,)); s1.rollback(); s1.close()
    P(f"{nm:16}: first read {r1}, second read {r2}  -> {'NON-REPEATABLE READ' if r1 != r2 else 'stable snapshot'}")

H("B3  PHANTOM READ: count rows twice while another session inserts a matching row")
for iso, nm in [(IL.READ_COMMITTED, "READ COMMITTED"), (IL.REPEATABLE_READ, "REPEATABLE READ")]:
    s1 = conn(iso); c1 = q1(s1, "SELECT count(*) FROM fx.liquidity_providers WHERE is_active")
    adm.execute("INSERT INTO fx.liquidity_providers(lp_name,country) VALUES (%s,'NG')", (f"Demo LP {nm} {RUN}",))
    c2 = q1(s1, "SELECT count(*) FROM fx.liquidity_providers WHERE is_active"); s1.rollback(); s1.close()
    P(f"{nm:16}: first count {c1}, second count {c2}  -> {'PHANTOM' if c1 != c2 else 'no phantom (PostgreSQL snapshot isolation)'}")
adm.execute("DELETE FROM fx.liquidity_providers WHERE lp_name LIKE %s", (f"Demo LP % {RUN}",))

H("B4  WRITE SKEW on a daily withdrawal limit (limit 5,000,000; two concurrent 3,000,000 withdrawals)")
def write_skew(iso, nm):
    adm.execute("DELETE FROM fx.payments WHERE provider_ref LIKE %s", (f"DEMO-{RUN}-%",))
    adm.execute("DELETE FROM fx.transactions WHERE reference LIKE %s", (f"DEMO-{RUN}-%",))
    first_bar = threading.Barrier(2, timeout=5); log = []
    def worker(name):
        for attempt in range(1, 4):
            c = conn(iso)
            try:
                used = q1(c, """SELECT COALESCE(sum(p.amount),0) FROM fx.payments p JOIN fx.transactions t USING(txn_id)
                                WHERE t.customer_id=%s AND t.txn_type='WITHDRAWAL' AND t.created_at >= date_trunc('day', now())""", (SB[1],))
                if attempt == 1:
                    try: first_bar.wait()
                    except threading.BrokenBarrierError: pass
                if used + 3_000_000 > 5_000_000:
                    log.append(f"{name}: saw used={used} -> REFUSED (limit would be exceeded)"); c.rollback(); return
                t = q1(c, "INSERT INTO fx.transactions(reference,txn_type,status,customer_id) VALUES (%s,'WITHDRAWAL','SUCCESS',%s) RETURNING txn_id", (f"DEMO-{RUN}-{name}-{attempt}", SB[1]))
                c.execute("INSERT INTO fx.payments(txn_id,channel,provider_ref,amount,currency_code,status) VALUES (%s,'BANK_TRANSFER',%s,3000000,'NGN','CONFIRMED')", (t, f"DEMO-{RUN}-{name}-{attempt}"))
                c.commit(); log.append(f"{name}: saw used={used} -> withdrawal COMMITTED (attempt {attempt})"); return
            except errors.SerializationFailure as e:
                log.append(f"{name}: SerializationFailure (SQLSTATE {e.sqlstate}) on attempt {attempt} -> retrying"); c.rollback()
            finally: c.close()
    ts = [threading.Thread(target=worker, args=(n,)) for n in "AB"]; [t.start() for t in ts]; [t.join() for t in ts]
    total = q1(adm, "SELECT COALESCE(sum(p.amount),0) FROM fx.payments p WHERE provider_ref LIKE %s", (f"DEMO-{RUN}-%",))
    for l in sorted(log): P("   ", l)
    P(f"  {nm}: total withdrawn today = {total:,.0f} -> {'LIMIT BREACHED (write skew)' if total > 5_000_000 else 'limit respected'}")
write_skew(IL.REPEATABLE_READ, "REPEATABLE READ")
write_skew(IL.SERIALIZABLE,    "SERIALIZABLE (SSI) with retry")
adm.execute("DELETE FROM fx.payments WHERE provider_ref LIKE %s", (f"DEMO-{RUN}-%",))
adm.execute("DELETE FROM fx.transactions WHERE reference LIKE %s", (f"DEMO-{RUN}-%",))

H("B5  DEADLOCK: two transfers lock the same two wallets in opposite order")
def deadlock(ordered):
    reset(); res = {}
    def worker(name, first, second):
        c = conn(); c.execute("SET deadlock_timeout = '300ms'")
        if ordered: first, second = sorted((first, second))
        try:
            c.execute("SELECT 1 FROM fx.wallets WHERE wallet_id=%s FOR UPDATE", (first,)); time.sleep(0.5)
            c.execute("SELECT 1 FROM fx.wallets WHERE wallet_id=%s FOR UPDATE", (second,))
            c.commit(); res[name] = "committed"
        except errors.DeadlockDetected as e:
            res[name] = "ABORTED by deadlock detector (SQLSTATE %s)" % e.sqlstate; c.rollback()
        finally: c.close()
    ts = [threading.Thread(target=worker, args=("A", W1, W2)), threading.Thread(target=worker, args=("B", W2, W1))]
    [t.start() for t in ts]; [t.join() for t in ts]; return res
P("naive (A: W1 then W2, B: W2 then W1):", deadlock(False))
P("fixed (both lock in ascending wallet_id):", deadlock(True))

# ----------------------------------------------------------------- sandbox cleanup
adm.execute("DELETE FROM fx.wallets WHERE customer_id = ANY(%s)", (SB,))
adm.execute("DELETE FROM fx.customers WHERE customer_id = ANY(%s)", (SB,))

# ===================================================================== C. STRESS
H("C  STRESS TEST: 8 concurrent workers, 4,000 conversion requests (10% are duplicate retries) on 200 customers")
custs = [r[0] for r in rows(adm, "SELECT customer_id FROM fx.customers WHERE kyc_tier=2 AND status='ACTIVE' AND customer_id>100 ORDER BY customer_id LIMIT 200")]
import random, collections
random.seed(7)
jobs = []
for i in range(4000):
    if i % 10 == 0 and i:            # every 10th request is a client retry: identical to the previous one
        jobs.append(jobs[-1])
    else:
        jobs.append((random.choice(custs), random.choice(['USD', 'USD', 'GBP', 'EUR']), random.randrange(20000, 150000, 1000), f"STRESS-{RUN}-{i}"))
tot_before = rows(adm, "SELECT count(*) FROM fx.transactions WHERE txn_type='FX_CONVERSION'")[0][0]
stats = collections.Counter(); lock = threading.Lock(); lat = []; accepted_refs = set()
it = iter(jobs)
def worker():
    c = conn(autocommit=True)
    while True:
        with lock:
            job = next(it, None)
        if job is None: break
        t0 = time.perf_counter()
        for attempt in range(6):
            try:
                c.execute("SELECT fx.convert_currency(%s,%s,%s,%s)", job); k = "accepted_or_idempotent"; accepted_refs.add(job[3]); break
            except (errors.SerializationFailure, errors.DeadlockDetected): k = "retry_exhausted"; stats["retries"] += 1
            except psycopg.errors.RaiseException as e: k = "business_rejection"; break
            except Exception as e: k = "other_error:" + type(e).__name__; break
        with lock: stats[k] += 1; lat.append((time.perf_counter() - t0) * 1000)
    c.close()
t0 = time.perf_counter()
ts = [threading.Thread(target=worker) for _ in range(8)]; [t.start() for t in ts]; [t.join() for t in ts]
el = time.perf_counter() - t0; lat.sort()
P(f"elapsed {el:.1f}s  throughput {len(jobs)/el:,.0f} requests/s | latency p50 {lat[len(lat)//2]:.1f} ms, p95 {lat[int(len(lat)*.95)]:.1f} ms, max {lat[-1]:.1f} ms")
P("outcomes:", dict(stats))
created = q1(adm, "SELECT count(*) FROM fx.transactions WHERE reference LIKE %s", (f"STRESS-{RUN}-%",))
uniq = len({j[3] for j in jobs})
P(f"distinct references requested = {uniq}; distinct references accepted = {len(accepted_refs)}; transactions created = {created}")
P("exactly-once check (created == distinct accepted references):", "PASS" if created == len(accepted_refs) else "FAIL")

H("INVARIANT CHECKS after all of the above (expect 0 / true)")
P("wallets whose balance != ledger sum        :", q1(adm, """SELECT count(*) FROM fx.wallets w JOIN (SELECT wallet_id, sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END) s FROM fx.ledger_entries GROUP BY 1) l USING (wallet_id) WHERE w.balance<>l.s"""))
P("transactions unbalanced per currency      :", q1(adm, """SELECT count(*) FROM (SELECT le.txn_id, w.currency_code FROM fx.ledger_entries le JOIN fx.wallets w USING(wallet_id) GROUP BY 1,2 HAVING sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END)<>0) z"""))
P("customer wallets with negative balance    :", q1(adm, "SELECT count(*) FROM fx.wallets WHERE wallet_type='CUSTOMER' AND balance<0"))
P("net of all ledger legs, any currency (=0) :", q1(adm, "SELECT COALESCE(sum(CASE direction WHEN 'CR' THEN amount ELSE -amount END),0) FROM fx.ledger_entries"))
P("customers over their daily limit today    :", q1(adm, """SELECT count(*) FROM (SELECT o.customer_id FROM fx.fx_orders o JOIN fx.customers c USING(customer_id) JOIN fx.kyc_tiers k ON k.tier=c.kyc_tier WHERE o.placed_at>=date_trunc('day',now()) GROUP BY o.customer_id, k.daily_limit_ngn HAVING sum(o.sell_amount)>k.daily_limit_ngn) z"""))
