"""GPU clock and power sampler tied to lease holds and benchmark runs (infra-owned, singleton).

usage: bg.sh <log> /tmp/openmm-metal-bench/env/bin/python /tmp/openmm-metal-bench/ultra-tools/gpuclock.py
stop:  touch /tmp/openmm-metal-bench/ultra-lead/gpuclock.stop (ends within CHUNK s), or kill the pid in
       ultra-lead/gpuclock.pid (its root powermetrics child then dies on the next write, within 1 s).

Runs one root `powermetrics --samplers cpu_power,gpu_power -i 1000` at a time, in CHUNK-sample runs, with the password piped
from Keychain and the credential dropped after each run. Every 1 s sample is tagged with the lease hold running at
that moment (/tmp/openmm-lease pid, owner and correctness marker) and with the benchmark.py run in progress (tree,
platform, precision, test, from its command line), and appended to ultra-lead/gpuclock.log:
    <UTC> freq=<MHz> active=<%> top=<% of active time at TOP_MHZ> power=<mW> pkg=<mW> hold=<pid|none> <kind> run=<run|-> <owner>
power is the GPU, pkg is powermetrics' "Combined Power (CPU + GPU + ANE)" for the same second. Since 2026-09-28 23:30Z
<UTC> carries the date and pkg is there; summarize.py joins these samples to ab.sh runs for watts per run.
Three summaries, each line naming the span it covers:
- ultra-lead/gpuclock-holds.log, one line per finished hold, and ultra-lead/gpuclock-current.txt for the running one.
- ultra-lead/gpuclock-runs.log, one line per benchmark.py run (a stretch of seconds with the same run): mean and peak
  GPU watts and mean package watts, so power per test and precision can be compared across holds. Mean power and
  frequency use busy seconds only, which leaves out Context creation and teardown. Back-to-back runs of one
  tree, platform, precision and test can share a line.
A sample is busy when active residency is at least BUSY_PERCENT. A timing hold (no correctness
marker) is FLAGged on a sustained drop (busy samples' mean frequency under FLAG_MHZ) or a deep one (any busy sample
under DEEP_MHZ); "low" counts busy samples under FLAG_MHZ either way. Correctness holds report the same numbers
without a flag, since light loads drop the clock by design (a correctness hold at 6.4 W read 1329 MHz on 2026-09-27).
"""
import os
import re
import signal
import statistics
import subprocess
import sys
import time

LEAD = "/tmp/openmm-metal-bench/ultra-lead"
LEASE = "/tmp/openmm-lease"
PIDFILE = f"{LEAD}/gpuclock.pid"
STOP = f"{LEAD}/gpuclock.stop"
SAMPLES = f"{LEAD}/gpuclock.log"
HOLDS = f"{LEAD}/gpuclock-holds.log"
RUNS = f"{LEAD}/gpuclock-runs.log"
CURRENT = f"{LEAD}/gpuclock-current.txt"
TOP_MHZ = 1380
# powermetrics reports 1379 for a busy second spent wholly at 1380 (seen at 95-99% active, 2026-09-27), so the
# flag line sits just under the top state. A real drop reads 1329 at 62% of active time on top.
FLAG_MHZ = 1375
# One busy second at 1373 (88% of active time on top) came at a run boundary inside an ab.sh hold; a deep drop is
# one state or more below the top, like the 1329 seen at light load.
DEEP_MHZ = 1330
BUSY_PERCENT = 90.0
CHUNK = 300
POWERMETRICS = (f"security find-generic-password -s sudo-password -w | sudo -S -p '' /usr/bin/powermetrics "
                f"--samplers cpu_power,gpu_power -i 1000 -n {CHUNK}; sudo -k")
BENCH = re.compile(r"bench\.noindex/([^/ ]+)/venv/bin/python.* benchmark\.py (.*)")


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def hold_now():
    pid = read(f"{LEASE}/pid")
    if not pid:
        return ("none", "", "")
    kind = "correctness" if os.path.exists(f"{LEASE}/correctness") else "timing"
    return (pid, kind, read(f"{LEASE}/owner"))


def run_now():
    """tree:platform:precision:test of the benchmark.py runs alive now, joined by '+', or '-'."""
    ps = subprocess.run(["/bin/ps", "-A", "-o", "command="], capture_output=True, text=True).stdout
    runs = []
    for line in ps.splitlines():
        if not (m := BENCH.search(line.replace("/tmp/openmm-metal-bench/", "bench.noindex/"))):
            continue
        args = dict(re.findall(r"--(platform|precision|test)[ =](\S+)", m.group(2)))
        runs.append(f"{m.group(1).removeprefix('ultra-')}:{args.get('platform', '?')}:"
                    f"{args.get('precision', 'single')}:{args.get('test', '?')}")
    return "+".join(sorted(runs)) or "-"


def utc():
    return time.strftime("%H:%M:%SZ", time.gmtime())


def stats(samples):
    busy = [s for s in samples if s["active"] >= BUSY_PERCENT]
    parts = [f"n={len(samples)}", f"busy={len(busy)}"]
    if samples:
        parts.append(f"active={statistics.mean(s['active'] for s in samples):.0f}%")
        parts.append(f"peak={max(s['power'] for s in samples) / 1000:.1f}W")
    if busy:
        parts.append(f"power={statistics.mean(s['power'] for s in busy) / 1000:.1f}W")
        if all("pkg" in s for s in busy):
            parts.append(f"pkg={statistics.mean(s['pkg'] for s in busy) / 1000:.1f}W")
        parts.append(f"freq_med={statistics.median(s['freq'] for s in busy):.0f}")
        parts.append(f"freq_min={min(s['freq'] for s in busy)}")
        parts.append(f"top={statistics.mean(s['top'] for s in busy):.1f}%")
    return busy, parts


def hold_summary(hold, samples, start, end):
    pid, kind, owner = hold
    busy, parts = stats(samples)
    low = [s for s in busy if s["freq"] < FLAG_MHZ]
    parts = [f"{start}-{end}", f"hold={pid}", kind or "-"] + parts + [f"low={len(low)}"]
    if kind == "timing" and busy and (statistics.mean(s["freq"] for s in busy) < FLAG_MHZ
                                      or min(s["freq"] for s in busy) < DEEP_MHZ):
        parts.append("FLAG")
    return " ".join(parts) + f" | {owner}"


def run_summary(run, hold, samples, start, end):
    _, parts = stats(samples)
    return " ".join([f"{start}-{end}", f"run={run}", f"hold={hold[0]}", hold[1] or "-"] + parts)


def append(path, line):
    with open(path, "a") as f:
        f.write(line + "\n")


def write_current(line):
    with open(CURRENT + ".tmp", "w") as f:
        f.write(line + "\n")
    os.replace(CURRENT + ".tmp", CURRENT)


def single_instance():
    old = read(PIDFILE)
    if old.isdigit():
        try:
            os.kill(int(old), 0)
            sys.exit(f"gpuclock.py: already running as pid {old}")
        except ProcessLookupError:
            pass
    with open(PIDFILE, "w") as f:
        f.write(f"{os.getpid()}\n")


def main():
    single_instance()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    hold, samples, start = hold_now(), [], utc()
    run, run_samples, run_start = run_now(), [], start
    sample, pkg = {}, None
    try:
        while not os.path.exists(STOP):
            proc = subprocess.Popen(["/bin/sh", "-c", POWERMETRICS], stdout=subprocess.PIPE, text=True)
            for line in proc.stdout:
                # The cpu_power section (with the combined line) comes before the GPU section of each sample.
                if m := re.match(r"Combined Power \(CPU \+ GPU \+ ANE\): (\d+) mW", line):
                    pkg = int(m.group(1))
                elif m := re.match(r"GPU HW active frequency: (\d+) MHz", line):
                    sample = {"freq": int(m.group(1))}
                elif m := re.match(r"GPU HW active residency:\s+([\d.]+)%", line):
                    sample["active"] = float(m.group(1))
                    top = re.search(rf"{TOP_MHZ} MHz:\s+([\d.]+)%", line)
                    sample["top"] = 100 * float(top.group(1)) / sample["active"] if top and sample["active"] else 0.0
                elif (m := re.match(r"GPU Power: (\d+) mW", line)) and "active" in sample:
                    sample["power"] = int(m.group(1))
                    if pkg is not None:
                        sample["pkg"] = pkg
                    now, current, current_run = utc(), hold_now(), run_now()
                    if current_run != run or current[0] != hold[0]:
                        if run != "-" and run_samples:
                            append(RUNS, run_summary(run, hold, run_samples, run_start, now))
                        run, run_samples, run_start = current_run, [], now
                    if current[0] != hold[0]:
                        append(HOLDS, hold_summary(hold, samples, start, now))
                        hold, samples, start = current, [], now
                    samples.append(sample)
                    run_samples.append(sample)
                    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                    append(SAMPLES, f"{stamp} freq={sample['freq']} active={sample['active']:.0f} top={sample['top']:.0f} "
                                    f"power={sample['power']} pkg={sample.get('pkg', '-')} hold={hold[0]} {hold[1] or '-'} run={run} {hold[2]}")
                    write_current(hold_summary(hold, samples, start, now))
                    sample, pkg = {}, None
            proc.wait()
            if proc.returncode:
                time.sleep(5)
    finally:
        now = utc()
        if run != "-" and run_samples:
            append(RUNS, run_summary(run, hold, run_samples, run_start, now) + " (sampler stopped)")
        append(HOLDS, hold_summary(hold, samples, start, now) + " (sampler stopped)")
        if read(PIDFILE) == str(os.getpid()):
            os.unlink(PIDFILE)


if __name__ == "__main__":
    main()
