#!/usr/bin/env python3
"""Run every queries/qNN_*.sql with EXPLAIN (ANALYZE, BUFFERS); save plan + median time.
usage: python3 bench.py <before|after> [dsn]"""
import sys, glob, json, re, statistics, os, psycopg
phase = sys.argv[1]
dsn = sys.argv[2] if len(sys.argv) > 2 else "dbname=nairalink"
os.makedirs("evidence/plans", exist_ok=True)
summary = {}
with psycopg.connect(dsn, autocommit=True) as conn, conn.cursor() as cur:
    cur.execute("SET max_parallel_workers_per_gather = 2; SET jit = off;")
    for path in sorted(glob.glob("queries/q*.sql")):
        qid = os.path.basename(path).split("_")[0]
        raw = open(path).read()
        if phase == "before" and "AFTER_ONLY" in raw: continue
        sql = raw.rstrip().rstrip(";")
        times = []
        for _ in range(5):                       # 1st run warms cache; take median of 5
            cur.execute("EXPLAIN (ANALYZE, BUFFERS) " + sql)
            plan = "\n".join(r[0] for r in cur.fetchall())
            times.append(float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1)))
        open(f"evidence/plans/{qid}_{phase}.txt", "w").write(open(path).read() + "\n" + plan + "\n")
        node = re.findall(r"(Seq Scan|Index Only Scan|Index Scan|Bitmap Heap Scan|Parallel Seq Scan)[^\n]*?on (\S+)", plan)
        summary[qid] = {"median_ms": round(statistics.median(times), 2), "runs_ms": times,
                        "scans": sorted({f"{a} on {b}" for a, b in node})}
        print(f"{qid} {phase:6} median {summary[qid]['median_ms']:>9} ms   {summary[qid]['scans']}")
json.dump(summary, open(f"evidence/bench_{phase}.json", "w"), indent=1)
