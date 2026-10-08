"""Profile one .gputrace with gpudebug and dump its performance subtree, all inside the caller's GPU hold.

Opens a gpudebug session on <trace>, runs `profile run --embed` (replays the capture with counters on this GPU),
then walks /performance breadth-first: for every node, `go <path>` (children, JSON) and `info --all` (JSON),
up to MAX_NODES nodes or DEADLINE seconds. Counter time-series under performance/timeline/counters are fetched
to <out>/fetch. Every raw reply goes to <out>/walk.jsonl as {"path", "cmd", "rc", "out", "err"}; the analysis
reads that file after the hold. The session is terminated at the end.
usage: python gdwalk.py <trace.gputrace> <out dir> (GDWALK_LOAD=1: reuse the embedded profile)
"""
import json
import os
import shutil
import subprocess
import sys
import time

MAX_NODES = 600
DEADLINE = 420  # whole script, open and profile included
trace, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.makedirs(out, exist_ok=True)
log = open(os.path.join(out, "walk.jsonl"), "w")
start = time.time()


def gd(args, path="", timeout=30):
    try:
        p = subprocess.run(["gpudebug", "-q"] + args, capture_output=True, text=True, timeout=timeout)
        rc, so, se = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        rc, so, se = "timeout", e.stdout or "", e.stderr or ""
        so = so.decode() if isinstance(so, bytes) else so
        se = se.decode() if isinstance(se, bytes) else se
    log.write(json.dumps({"t": round(time.time() - start, 1), "path": path, "cmd": args, "rc": rc, "out": so, "err": se}) + "\n")
    log.flush()
    return rc, so


def session_id():
    _, so = gd(["--list-sessions", "--json"])
    try:
        data = json.loads(so)
    except ValueError:
        data = None
    items = data if isinstance(data, list) else (data or {}).get("sessions", []) if isinstance(data, dict) else []
    for s in items:
        if isinstance(s, dict) and os.path.basename(trace).rsplit(".", 1)[0] in json.dumps(s):
            return str(s.get("id") or s.get("session") or s.get("sessionID") or s.get("ID"))
    for line in so.splitlines():  # text fallback: first token of the line naming the trace
        if os.path.basename(trace).rsplit(".", 1)[0] in line:
            return line.split()[0]
    return None


def children(reply):
    """Child node names from a `go` reply in JSON, whatever the key layout."""
    try:  # `go` prints the node's children and `list --all` prints them again: take the first JSON document
        data = json.JSONDecoder().raw_decode(reply.lstrip())[0]
    except ValueError:
        return []
    found = []

    def visit(x, depth):
        if depth > 4:
            return
        if isinstance(x, dict):
            for key in ("children", "items", "rows", "entries", "nodes"):
                if isinstance(x.get(key), list):
                    for c in x[key]:
                        if isinstance(c, dict):
                            name = c.get("name") or c.get("id") or c.get("url")
                            if isinstance(name, str):
                                found.append((name, c))
            for v in x.values():
                visit(v, depth + 1)
        elif isinstance(x, list):
            for v in x:
                visit(v, depth + 1)
    visit(data, 0)
    seen, result = set(), []
    for name, c in found:
        if name not in seen:
            seen.add(name)
            result.append((name, c))
    return result


rc, _ = gd(["-t", trace, "--timeout", "900", "-c", "status"], timeout=90)
sid = session_id()
print(f"session {sid} (open rc {rc})", flush=True)
if not sid:
    sys.exit("no gpudebug session found for the trace")
try:
    gd(["-s", sid, "-c", "help"])
    gd(["-s", sid, "-c", "profile ?"])
    # GDWALK_LOAD=1 walks the profile already embedded in the trace (profile load) instead of collecting a new one.
    command = "profile load" if os.environ.get("GDWALK_LOAD") else "profile run --embed"
    rc, so = gd(["-s", sid, "-c", command], timeout=max(30, DEADLINE - 120 - int(time.time() - start)))
    print(f"profile run rc {rc}: {so.strip()[-300:]}", flush=True)
    gd(["-s", sid, "-c", "profile"])
    gd(["-s", sid, "--json", "-c", "profile list"])
    queue, done = ["/performance"], 0
    while queue and done < MAX_NODES and time.time() - start < DEADLINE:
        path = queue.pop(0)
        rc, so = gd(["-s", sid, "--json", "-c", f"go {path}", "-c", "list --all"], path)
        gd(["-s", sid, "--json", "-c", f"go {path}", "-c", "info --all"], path)
        done += 1
        for name, c in children(so):
            child = name if name.startswith("/") else path.rstrip("/") + "/" + name
            if child.count("/") <= 6:
                queue.append(child)
        if "/timeline/counters/" in path:
            gd(["-s", sid, "-o", os.path.join(out, "fetch"), "-c", f"go {path}", "-c", "fetch"], path)
    print(f"walked {done} nodes, {len(queue)} left, {time.time() - start:.0f} s", flush=True)
    for path in ("/performance/shaders", "/performance/commands", "/performance/encoders", "/performance/timeline/counters"):
        gd(["-s", sid, "-c", f"go {path}", "-c", "list --all"], path + " (text)")
finally:
    gd(["--terminate", sid], timeout=15)
    # gpudebug leaves <stem>_stream.gpuprofiler_raw (0.6-1.6 GB) in /private/tmp/com.apple.gputools.profiling; the
    # profile is embedded in the trace by now, so the raw stream is dead weight.
    shutil.rmtree(f"/private/tmp/com.apple.gputools.profiling/{os.path.basename(trace).rsplit('.', 1)[0]}_stream.gpuprofiler_raw", ignore_errors=True)
