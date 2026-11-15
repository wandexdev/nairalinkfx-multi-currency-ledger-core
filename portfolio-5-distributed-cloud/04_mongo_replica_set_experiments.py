#!/usr/bin/env python3
"""Portfolio 5 - MongoDB replica set (rs0, 3 nodes): write concern, read preference/consistency, election/failover, loss of majority.
usage: python3 04_mongo_replica_set_experiments.py   (node start/stop commands at the top are for my workspace; see ../SETUP.md for yours)"""
import time, statistics, threading, subprocess, signal, os, pymongo
from pymongo import WriteConcern, ReadPreference
from pymongo.read_concern import ReadConcern
import os
DOCKER = os.environ.get("MODE") == "docker"     # MODE=docker -> nodes are the containers mongo1..mongo3 (add them to your hosts file, see ../SETUP.md)
URI = os.environ.get("MONGO_URI", "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0" if DOCKER else "mongodb://127.0.0.1:27017,127.0.0.1:27018,127.0.0.1:27019/?replicaSet=rs0")
MONGOD = "/opt/mambaroot/envs/mongo/bin/mongod"
NODES = {27017: "n1", 27018: "n2", 27019: "n3"}
RUN = str(int(time.time()))
def start_node(port):
    if DOCKER: subprocess.run(["docker", "start", "mongo" + str(port - 27016)], capture_output=True); return
    subprocess.run(["su", "pguser", "-c", f"{MONGOD} --replSet rs0 --port {port} --dbpath /var/mongo/{NODES[port]} --bind_ip 127.0.0.1 --fork --logpath /var/mongo/{NODES[port]}.log --logappend --wiredTigerCacheSizeGB 0.25"], capture_output=True)
def kill_node(port):
    if DOCKER: subprocess.run(["docker", "kill", "mongo" + str(port - 27016)], capture_output=True); return
    out = subprocess.run(["pgrep", "-f", f"mongod --replSet rs0 --port {port} "], capture_output=True, text=True).stdout.split()
    for pid in out: os.kill(int(pid), signal.SIGKILL)
def node_host(p): return f"mongo{p - 27016}" if DOCKER else "127.0.0.1"
def H(t): print(f"\n{'='*78}\n{t}\n{'='*78}", flush=True)
def status():
    for _ in range(40):
        try:
            c = pymongo.MongoClient(URI, serverSelectionTimeoutMS=2000)
            s = c.admin.command("replSetGetStatus"); return {m["name"]: m["stateStr"] for m in s["members"]}
        except Exception: time.sleep(1)
    return {}
def per_node_states():
    out = {}
    for p in NODES:
        try: out[p] = pymongo.MongoClient(f"mongodb://{node_host(p)}:{p}/?directConnection=true", serverSelectionTimeoutMS=1500).admin.command("hello")
        except Exception: out[p] = None
    return {p: ("DOWN" if h is None else "PRIMARY" if h.get("isWritablePrimary") else "SECONDARY" if h.get("secondary") else "OTHER") for p, h in out.items()}
def wait_primary(timeout=60):
    t = time.time()
    while time.time() - t < timeout:
        st = per_node_states()
        if "PRIMARY" in st.values(): return st
        time.sleep(0.25)
    return per_node_states()

client = pymongo.MongoClient(URI); db = client["nairalink_nosql"]; db.drop_collection("p5_probe"); coll = db["p5_probe"]

H("M1  Topology")
print("members:", status()); print("write concern default / majority commit point available:", client.admin.command("hello")["setName"])

H("M2  Write-concern cost: 400 inserts each (median / p95 ms)")
def lat(wc, n=400):
    c = coll.with_options(write_concern=wc); xs = []
    for i in range(n):
        t = time.perf_counter(); c.insert_one({"run": RUN, "k": "wc", "i": i}); xs.append((time.perf_counter() - t) * 1000)
    xs.sort(); return statistics.median(xs), xs[int(.95 * n)]
for label, wc in [("w=1 (primary only)", WriteConcern(w=1)), ("w=1, j=True (journaled on primary)", WriteConcern(w=1, j=True)), ("w=majority (2 of 3 nodes)", WriteConcern(w="majority")), ("w=3 (all nodes)", WriteConcern(w=3))]:
    m, p = lat(wc); print(f"  {label:38} p50 {m:6.2f} ms  p95 {p:6.2f} ms")

H("M3  Read-your-writes when reading from a SECONDARY (300 trials each)")
sec = coll.with_options(read_preference=ReadPreference.SECONDARY)
def stale_test(write_wc, causal):
    stale = 0
    for i in range(300):
        c = coll.with_options(write_concern=write_wc)
        if causal:
            with client.start_session(causal_consistency=True) as s:
                _id = c.insert_one({"run": RUN, "k": "ryw"}, session=s).inserted_id
                if not sec.with_options(read_concern=ReadConcern("majority")).find_one({"_id": _id}, session=s): stale += 1
        else:
            _id = c.insert_one({"run": RUN, "k": "ryw"}).inserted_id
            if not sec.find_one({"_id": _id}): stale += 1
    return stale
for label, wc, causal in [("w=1, plain secondary read", WriteConcern(w=1), False), ("w=majority, plain secondary read", WriteConcern(w="majority"), False),
                          ("w=majority + causally-consistent session, readConcern=majority", WriteConcern(w="majority"), True)]:
    print(f"  {label:66} stale reads: {stale_test(wc, causal):3d} / 300")

def writer_thread(stop, acked, gaps, tag):
    """Continuously insert with w=majority + retryable writes; record every acknowledged id and each write's latency."""
    wc = pymongo.MongoClient(URI, retryWrites=True, serverSelectionTimeoutMS=45000, w="majority", wtimeoutMS=45000)["nairalink_nosql"]["p5_probe"]
    i = 0
    while not stop.is_set():
        t = time.perf_counter()
        try: wc.insert_one({"_id": f"{RUN}-{tag}-{i}", "run": RUN, "k": tag, "i": i}); acked.append(f"{RUN}-{tag}-{i}"); gaps.append((time.time(), (time.perf_counter() - t) * 1000))
        except Exception as e: gaps.append((time.time(), -1))
        i += 1; time.sleep(0.005)

def failover(title, action, tag):
    H(title)
    acked, gaps, stop = [], [], threading.Event(); th = threading.Thread(target=writer_thread, args=(stop, acked, gaps, tag)); th.start(); time.sleep(2)
    before = per_node_states(); print("before:", before); t0 = time.time(); action(before); st = wait_primary(60); time.sleep(4); stop.set(); th.join()
    print("after :", st)
    worst = max(g[1] for g in gaps); errs = sum(1 for g in gaps if g[1] < 0)
    print(f"writer: {len(acked)} acknowledged writes, {errs} failed writes, worst single-write latency (= outage as seen by the app) {worst/1000:.2f} s")
    present = set(d["_id"] for d in coll.with_options(read_concern=ReadConcern("majority")).find({"run": RUN, "k": tag}, {"_id": 1}))
    lost = [a for a in acked if a not in present]
    print(f"acknowledged writes missing after failover: {len(lost)}  -> {'NO DATA LOSS' if not lost else 'DATA LOSS!'}")

def step_down(before):
    p = [p for p, s in before.items() if s == "PRIMARY"][0]
    try: pymongo.MongoClient(f"mongodb://{node_host(p)}:{p}/?directConnection=true").admin.command("replSetStepDown", 30, force=True)
    except Exception: pass
failover("M4a  Planned failover: replSetStepDown on the primary while a majority-writer is running", step_down, "stepdown")

def hard_kill(before):
    p = [p for p, s in before.items() if s == "PRIMARY"][0]; print(f"kill -9 the PRIMARY (port {p}) ..."); kill_node(p); hard_kill.port = p
failover("M4b  Unplanned failure: kill -9 the primary process while a majority-writer is running", hard_kill, "kill9")
print("restarting the killed node ..."); start_node(hard_kill.port); time.sleep(6); print("states:", per_node_states())

H("M5  Lose the MAJORITY: kill 2 of 3 nodes (CP behaviour - consistency over availability)")
st = per_node_states(); prim = [p for p, s in st.items() if s == "PRIMARY"][0]; others = [p for p in NODES if p != prim]
print("before:", st); kill_node(others[0]); kill_node(others[1]); time.sleep(14); print("after 14 s:", per_node_states())
try:
    pymongo.MongoClient(f"mongodb://{node_host(prim)}:{prim}/?directConnection=true", serverSelectionTimeoutMS=3000)["nairalink_nosql"]["p5_probe"].insert_one({"k": "no-majority"})
    print("write accepted?!")
except Exception as e: print("write attempt on the surviving node ->", type(e).__name__, "(no primary can be elected without a majority: writes refused)")
try:
    n = pymongo.MongoClient(f"mongodb://{node_host(prim)}:{prim}/?directConnection=true", readPreference="secondaryPreferred", serverSelectionTimeoutMS=3000)["nairalink_nosql"]["p5_probe"].count_documents({"run": RUN})
    print(f"reads from the surviving node with secondaryPreferred still work: {n} documents visible (possibly stale)")
except Exception as e: print("read failed:", type(e).__name__)
for p in others: start_node(p)
st = wait_primary(60); time.sleep(5); print("after restarting both nodes:", per_node_states())
n = coll.with_options(read_concern=ReadConcern("majority")).count_documents({"run": RUN}); print("documents for this run after full recovery:", n)
print("final replica set:", status())
