"""Collect every dispatch's instruction count and every encoder's GPU duration.

Run inside the caller's GPU lease. Load or embed a replay profile, collect the
command cost fractions used by readout.py, and retain raw replies in target.jsonl.
The tool prints two list documents; kids() retains the larger one.
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


stem = os.path.basename(trace).rsplit(".", 1)[0]
sid = None


def open_session():
    rc, _ = gd(["-t", trace, "--timeout", "900", "-c", "status"], timeout=90)
    _, so = gd(["--list-sessions"])
    found = next((line.split()[0] for line in so.splitlines() if stem + ".gputrace" in line), None)
    if not found:
        raise RuntimeError(f"no gpudebug session found for {trace} (open rc {rc})")
    return found


try:
    sid = open_session()
    print(f"session {sid}", flush=True)
    rc, so = gd(["-s", sid, "-c", "profile load"], timeout=240)
    print(f"profile load rc {rc}: {so.strip()[-200:]}", flush=True)
    if "loaded" not in so.lower():
        rc, so = gd(["-s", sid, "-c", "profile run --embed"], timeout=240)
        print(f"profile run rc {rc}: {so.strip()[-200:]}", flush=True)
        if rc != 0 or "collected" not in so.lower():
            raise RuntimeError("counter profile collection failed")
        gd(["-s", sid, "-c", "wait"], timeout=120)
        gd(["--terminate", sid], timeout=15)
        sid = open_session()
        rc, so = gd(["-s", sid, "-c", "profile load"], timeout=120)
        print(f"reopened profile load rc {rc}: {so.strip()[-200:]}", flush=True)
        if rc != 0 or "loaded" not in so.lower():
            raise RuntimeError("embedded profile did not load")
    gd(["-s", sid, "-c", "profile"])
    info(sid, "/performance")
    info(sid, "/performance/timeline")
    for c in kids(sid, "/performance/shaders"):
        info(sid, f"/performance/shaders/{c['name']}")
    wanted = [c["name"] for c in kids(sid, "/performance/commands")]
    if not wanted:
        raise RuntimeError("profile has no dispatches")
    for name in wanted:
        info(sid, f"/performance/commands/{name}")

    for c in kids(sid, "/performance/encoders"):
        base = f"/performance/encoders/{c['name']}"
        kids(sid, base + "/commands")

    kids(sid, "/performance/timeline/encoders")
    for c in kids(sid, "/performance/timeline/counters"):
        kids(sid, f"/performance/timeline/counters/{c['name']}")
    print(f"target walk: {len(wanted)} dispatches, {time.time() - start:.0f} s", flush=True)
finally:
    if sid is not None:
        gd(["--terminate", sid], timeout=15)
    embedded = os.path.join(trace, stem + "_stream_0.gpuprofiler_raw")
    raw = os.path.join("/private/tmp/com.apple.gputools.profiling", stem + "_stream.gpuprofiler_raw")
    if os.path.isdir(raw) and os.path.isdir(embedded) and any(
        name.startswith("Counters") and name.endswith(".raw") for name in os.listdir(embedded)
    ):
        shutil.rmtree(raw)
