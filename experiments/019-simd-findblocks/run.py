"""Time the Metal platform before and after the SIMD-group findBlocksWithInteractions, interleaved.

usage: python run.py <before-python> <after-python> <benchmarks-dir> <fah-wu-dir> <out-dir> [fah]
  <before-python>  interpreter whose `openmm` is branch metal (361452c5c)
  <after-python>   interpreter whose `openmm` is branch metal-simd-findblocks
  <benchmarks-dir> copy of examples/benchmarks from 361452c5c, benchmark.py unmodified
Launch detached from sh at nice 0:  sh -c "nohup python3 run.py ... > run.log 2>&1 &"

Clocks: benchmark.py's own (host wall, datetime.now, over whole steps, 60 s after its warm-up)
and fahwu.py's (host wall, time.perf_counter, whole steps, 60 s after a 200-step warm-up).
Three rounds.  Within a round every (test, precision) pair runs both installs back to back, and
which install goes first alternates, so drift over the session spreads across both.  The machine is
shared: each pair holds the lease /tmp/openmm-lease while it runs, so other agents' builds and GPU
jobs can fall between pairs but never inside one.
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import time

TESTS = ["pme", "apoa1rf", "apoa1pme", "amber20-cellulose"]
WUS = ["dhfr", "nav"]
PRECISIONS = ["single", "mixed"]
ROUNDS = 3
TIMEOUT_S = 900  # a pair holds the shared lease, which must stay under 30 minutes
FAHWU = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fahwu.py")
LEASE = "/tmp/openmm-lease"
LEASE_OWNER = "simd-findblocks-019"


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout


def snapshot(out, label):
    with open(f"{out}/host.txt", "a") as f:
        f.write(f"== {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {label}\n")
        f.write(sh("uptime; pmset -g therm | tail -3; pmset -g batt | head -1; top -l 2 -o cpu -n 6 -stats command,cpu | tail -6"))


def lease(what):
    while True:
        try:
            os.mkdir(LEASE)
            break
        except FileExistsError:
            time.sleep(20)
    with open(f"{LEASE}/owner", "w") as f:
        f.write(f"{LEASE_OWNER} {time.strftime('%H:%MZ', time.gmtime())} {what}\n")


def unlease():
    try:
        with open(f"{LEASE}/owner") as f:
            mine = f.read().startswith(LEASE_OWNER + " ")
    except FileNotFoundError:
        return
    if mine:
        shutil.rmtree(LEASE)


def pair(out, label, runs):
    """Run the before and after commands of one pair back to back under the lease."""
    lease(f"benchmark {label}")
    try:
        snapshot(out, label)
        for args in runs:
            run(out, *args)
    finally:
        unlease()


def run(out, name, cmd, stdout_file=None):
    start = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S, cwd=os.path.dirname(cmd[1]))
        status = "ok" if r.returncode == 0 else f"exit {r.returncode}"
        log = r.stdout + r.stderr
        if stdout_file is not None and r.returncode == 0:
            with open(stdout_file, "a") as f:
                f.write(r.stdout.strip().splitlines()[-1] + "\n")
    except subprocess.TimeoutExpired as e:
        status, log = f"timeout {TIMEOUT_S} s", (e.stdout or b"").decode() + (e.stderr or b"").decode()
    with open(f"{out}/runs.jsonl", "a") as f:
        f.write(json.dumps({"name": name, "status": status, "wall_s": round(time.time() - start, 1)}) + "\n")
    with open(f"{out}/log.txt", "a") as f:
        f.write(f"=== {name}: {status}\n{log}\n")


def main():
    before, after, bench, wus, out = sys.argv[1:6]
    with_fah = len(sys.argv) > 6 and sys.argv[6] == "fah"
    if os.getpriority(os.PRIO_PROCESS, 0) != 0:
        sys.exit("not at nice 0; launch from sh, not zsh with &")
    if "Battery Power" in sh("pmset -g batt"):
        sys.exit("on battery power; plug in")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("terminated"))
    os.makedirs(f"{out}/json")  # fails if the directory exists, so two runs never share one
    installs = {"before": before, "after": after}
    with open(f"{out}/host.txt", "w") as f:
        f.write(sh("uname -a; sw_vers; sysctl -n machdep.cpu.brand_string hw.memsize hw.ncpu; "
                   "system_profiler SPDisplaysDataType | grep -E 'Chipset|Total Number of Cores'"))
        for label, py in installs.items():
            f.write(label + ": " + sh(f"{py} -c \"import openmm as m; print(m.__version__, m.__file__)\""))
        f.write(sh(f"shasum -a 256 {bench}/benchmark.py {FAHWU}"))
    turn = 0
    for rnd in range(1, ROUNDS + 1):
        for test in TESTS:
            for precision in PRECISIONS:
                order = ["before", "after"] if turn % 2 == 0 else ["after", "before"]
                turn += 1
                runs = []
                for label in order:
                    name = f"{test}-{precision}-{label}-r{rnd}"
                    runs.append((name, [installs[label], f"{bench}/benchmark.py", "--platform=Metal", f"--precision={precision}",
                                        f"--test={test}", f"--outfile={out}/json/{name}.json"]))
                pair(out, f"round {rnd} {test} {precision}", runs)
        if not with_fah:
            continue
        for wu in WUS:
            for precision in PRECISIONS:
                order = ["before", "after"] if turn % 2 == 0 else ["after", "before"]
                turn += 1
                runs = []
                for label in order:
                    name = f"fah-{wu}-{precision}-{label}-r{rnd}"
                    runs.append((name, [installs[label], FAHWU, f"{wus}/{wu}", "Metal", precision, "60"], f"{out}/fah-{label}.jsonl"))
                pair(out, f"round {rnd} fah {wu} {precision}", runs)
    lease("host snapshot")
    try:
        snapshot(out, "end")
    finally:
        unlease()
    open(f"{out}/DONE", "w").write("done\n")


if __name__ == "__main__":
    main()
