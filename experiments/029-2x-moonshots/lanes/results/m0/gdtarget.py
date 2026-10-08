"""Targeted gpudebug walk of one .gputrace with an embedded profile, inside the caller's GPU hold.

gdwalk.py walks /performance breadth-first and ran out of its 600-node budget before the per-dispatch counters.
This walk asks only for what the M0(2) comparison needs: every shader's static stats, every computeNonbonded and
findBlocksWithInteractions dispatch (info plus counters/compute_kernel), every encoder's command list and its
performance_limiters, memory and compute_kernel counter groups, and the whole-trace timeline counter groups.
`go X -c list --all` prints two JSON documents, the first capped at 20 children; kids() keeps the largest.
Raw replies go to <out>/target.jsonl in gdwalk's format. If `profile load` fails, it runs `profile run --embed`.
usage: python gdtarget.py <trace.gputrace> <out dir>
"""
import json
import os
import shutil
import subprocess
import sys
import time

trace, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
os.makedirs(out, exist_ok=True)
log = open(os.path.join(out, "target.jsonl"), "w")
start = time.time()
WANTED = ("computeNonbonded", "findBlocksWithInteractions")


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


def docs(s):
    dec, i, found = json.JSONDecoder(), 0, []
    while i < len(s):
        if s[i] in " \r\n\t":
            i += 1
            continue
        try:
            obj, i = dec.raw_decode(s, i)
            found.append(obj)
        except ValueError:
            nl = s.find("\n", i)
            if nl < 0:
                break
            i = nl + 1
    return found


def kids(sid, path):
    _, so = gd(["-s", sid, "--json", "-c", f"go {path}", "-c", "list --all"], path)
    lists = [d for d in docs(so) if isinstance(d, dict) and isinstance(d.get("children"), list)]
    return max(lists, key=lambda d: len(d["children"]))["children"] if lists else []


def info(sid, path):
    gd(["-s", sid, "--json", "-c", f"go {path}", "-c", "info --all"], path)


def label(child):
    vals = [v.get("value") for v in child.get("values") or [] if isinstance(v, dict)]
    return str(vals[0]).strip('"') if vals else ""


rc, _ = gd(["-t", trace, "--timeout", "900", "-c", "status"], timeout=90)
_, so = gd(["--list-sessions"])
stem = os.path.basename(trace).rsplit(".", 1)[0]
sid = next((line.split()[0] for line in so.splitlines() if stem + ".gputrace" in line), None)
print(f"session {sid} (open rc {rc})", flush=True)
if not sid:
    sys.exit("no gpudebug session found for the trace")
try:
    rc, so = gd(["-s", sid, "-c", "profile load"], timeout=240)
    print(f"profile load rc {rc}: {so.strip()[-200:]}", flush=True)
    if "loaded" not in so.lower():
        rc, so = gd(["-s", sid, "-c", "profile run --embed"], timeout=240)
        print(f"profile run rc {rc}: {so.strip()[-200:]}", flush=True)
        gd(["-s", sid, "-c", "wait"], timeout=120)
    gd(["-s", sid, "-c", "profile"])
    for c in kids(sid, "/performance/shaders"):
        info(sid, f"/performance/shaders/{c['name']}")
    wanted = [c["name"] for c in kids(sid, "/performance/commands") if label(c) in WANTED]
    for name in wanted:
        info(sid, f"/performance/commands/{name}")
        kids(sid, f"/performance/commands/{name}/counters/compute_kernel")
    for c in kids(sid, "/performance/encoders"):
        base = f"/performance/encoders/{c['name']}"
        kids(sid, base + "/commands")
        for group in ("performance_limiters", "memory", "compute_kernel"):
            kids(sid, f"{base}/counters/{group}")
    kids(sid, "/performance/timeline/encoders")
    for c in kids(sid, "/performance/timeline/counters"):
        kids(sid, f"/performance/timeline/counters/{c['name']}")
    print(f"target walk: {len(wanted)} dispatches, {time.time() - start:.0f} s", flush=True)
finally:
    gd(["--terminate", sid], timeout=15)
    # gpudebug leaves <stem>_stream.gpuprofiler_raw (0.6-1.6 GB) in /private/tmp/com.apple.gputools.profiling; the
    # profile is embedded in the trace by now, so the raw stream is dead weight.
    shutil.rmtree(f"/private/tmp/com.apple.gputools.profiling/{os.path.basename(trace).rsplit('.', 1)[0]}_stream.gpuprofiler_raw", ignore_errors=True)
