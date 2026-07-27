#!/usr/bin/env python3
"""M23: differential fuzz for REPLICATION.

M22 proved cold storage against a hot oracle in-process. Replication cannot be
tested that way — a follower is defined by what it can reconstruct *from disk* —
so this drives the real binaries: a primary and a `--follow` server over the same
directory, plus the remote `grange follow` path over /watch.

After every op the follower's FULL state must equal the primary's. The op stream
deliberately includes the transitions that broke replication before: cold
conversion, flushes (which delete the WAL chunks a follower was tracking and
restart chunk numbering), compaction (which bumps the generation and rewrites
every file) and index builds. The follower is also restarted mid-stream, because
a follower that only works while its process stays up is not a follower.

Usage: fuzz_replica.py [ops] [seeds] [--bin ./grange]
"""
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

BIN = os.environ.get("GRANGE_BIN", "./grange")
TOKEN = "fuzztk"
KEYS = 40


def req(port, path, body=None, method=None, ctype="application/json"):
    url = f"http://localhost:{port}{path}"
    data = body.encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method or ("POST" if data else "GET"))
    r.add_header("authorization", f"Bearer {TOKEN}")
    r.add_header("content-type", ctype)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"ok": False, "error": {"type": "http", "message": str(e)}}
    except Exception as e:
        return {"ok": False, "error": {"type": "net", "message": str(e)}}


def start(db, port, follow=False):
    args = [BIN, "serve", "--db", db, "--port", str(port), "--token", TOKEN]
    if follow:
        args.append("--follow")
    p = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        time.sleep(0.1)
        if req(port, "/health").get("ok"):
            return p
    raise RuntimeError(f"server on {port} never came up")


def stop(p):
    if p and p.poll() is None:
        p.send_signal(signal.SIGKILL)
        p.wait()


def state(port, coll):
    """Full visible state, canonicalised so ordering can never mask a divergence."""
    d = req(port, f"/export?coll={coll}")
    if not d.get("ok"):
        return f"ERROR:{d.get('error')}"
    items = sorted((i["id"], json.dumps(i["doc"], sort_keys=True)) for i in d["data"]["items"])
    return f"n={len(items)};" + ";".join(f"{k}={v}" for k, v in items)


def op_stream(rng, ops):
    for i in range(ops):
        r = rng.random()
        if r < 0.45:
            yield ("put", rng.randrange(KEYS), rng.randrange(100))
        elif r < 0.62:
            yield ("del", rng.randrange(KEYS), 0)
        elif r < 0.80:
            yield ("bulk", rng.randrange(KEYS), rng.randrange(100))
        elif r < 0.88:
            yield ("compact", 0, 0)
        elif r < 0.94:
            yield ("index", 0, 0)
        else:
            yield ("restart", 0, 0)


def run_seed(seed, ops, coll, cold):
    rng = random.Random(seed)
    db = tempfile.mkdtemp(prefix="grange-replfuzz-")
    primary = follower = None
    diverged = []
    try:
        primary = start(db, 4461)
        if cold:
            req(4461, f"/cold?coll={coll}", "{}")
        follower = start(db, 4462, follow=True)
        indexed = False
        history = []
        for step, (op, key, val) in enumerate(op_stream(rng, ops)):
            history.append(f"{op}(k{key},{val})")
            if op == "put":
                req(4461, "/put", json.dumps({"coll": coll, "id": f"k{key}",
                                              "doc": {"grp": f"g{val % 5}", "v": val}}))
            elif op == "del":
                req(4461, "/del", json.dumps({"coll": coll, "id": f"k{key}"}))
            elif op == "bulk":
                lines = "\n".join(
                    f"k{(key + j) % KEYS}\t" + json.dumps({"grp": f"g{(val + j) % 5}", "v": val + j})
                    for j in range(rng.randrange(1, 12)))
                req(4461, f"/bulk?coll={coll}", lines, ctype="text/plain")
            elif op == "compact":
                req(4461, "/compact", json.dumps({"coll": coll}))
            elif op == "index" and not indexed:
                req(4461, "/index", json.dumps({"coll": coll, "field": "grp"}))
                indexed = True
            elif op == "restart":
                # a follower must reconstruct from disk, not from memory
                stop(follower)
                follower = start(db, 4462, follow=True)

            p_state, f_state = state(4461, coll), state(4462, coll)
            if p_state != f_state:
                # name the offending keys: a 160-char prefix hides which doc differs
                pk = dict(x.split("=", 1) for x in p_state.split(";")[1:] if "=" in x)
                fk = dict(x.split("=", 1) for x in f_state.split(";")[1:] if "=" in x)
                only_p = sorted(set(pk) - set(fk))
                only_f = sorted(set(fk) - set(pk))
                differ = sorted(k for k in set(pk) & set(fk) if pk[k] != fk[k])
                diverged.append((step, op,
                                 f"primary_only={only_p} follower_only={only_f} value_differs={differ}",
                                 f"n_primary={len(pk)} n_follower={len(fk)} last_ops={' '.join(history[-6:])}"))
                if len(diverged) >= 3:
                    break

        # the remote path: `grange follow --once` into a fresh db must match too
        replica_db = tempfile.mkdtemp(prefix="grange-replfuzz-remote-")
        subprocess.run([BIN, "follow", "--from", "http://localhost:4461", "--rtoken", TOKEN,
                        "--remote-coll", coll, "--db", replica_db, "--coll", coll, "--once"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        out = subprocess.run([BIN, "export", "--db", replica_db, "--coll", coll],
                             capture_output=True, text=True, timeout=120)
        remote_items = sorted((i["id"], json.dumps(i["doc"], sort_keys=True))
                              for i in json.loads(out.stdout)["data"]["items"])
        remote_state = f"n={len(remote_items)};" + ";".join(f"{k}={v}" for k, v in remote_items)
        if remote_state != state(4461, coll):
            diverged.append(("remote", "follow", state(4461, coll)[:160], remote_state[:160]))
        shutil.rmtree(replica_db, ignore_errors=True)
        return diverged
    finally:
        stop(primary)
        stop(follower)
        shutil.rmtree(db, ignore_errors=True)


def main():
    ops = int(sys.argv[1]) if len(sys.argv) > 1 else 120
    seeds = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    failures = 0
    for s in range(seeds):
        seed = 4242 + s * 977
        for cold in (False, True):
            label = "cold" if cold else "hot "
            d = run_seed(seed, ops, "c", cold)
            if d:
                failures += 1
                print(f"seed {seed} [{label}]: DIVERGED")
                for step, op, p, f in d:
                    print(f"  step {step} after {op}: {p} | {f}")
            else:
                print(f"seed {seed} [{label}]: ok ({ops} ops)")
    print(json.dumps({"ok": failures == 0, "seeds": seeds, "ops": ops, "failures": failures}))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
