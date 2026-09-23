"""Run OpenMM's own benchmark suite (examples/benchmarks/benchmark.py) on one Mac.

usage: python run.py <python> <benchmark.py> <out-dir>
  <python>        interpreter whose `openmm` is the f9347f6c5 install (Metal, OpenCL, CPU)
  <benchmark.py>  examples/benchmarks/benchmark.py from the same commit, unmodified
Launch detached from sh at nice 0, as in experiment 017:
  sh -c "nohup python3 run.py ... > run.log 2>&1 &"

Clock: benchmark.py's own, host wall (datetime.now) over whole steps, 60 s per test after its
20-step warm-up. Every (test, configuration) pair is a separate process with a timeout, so one
slow minimization or an out-of-memory failure can't stop the rest. The configuration order
rotates from test to test, so drift over the session spreads across configurations.
AMOEBA tests are skipped: the Metal platform has no AMOEBA plugin.
"""
import json
import os
import subprocess
import sys
import time

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme",
         "amber20-dhfr", "amber20-cellulose", "amber20-stmv"]
CONFIGS = [("Metal", "single"), ("Metal", "mixed"), ("OpenCL", "single"), ("CPU", "single")]
TIMEOUT_S = 2400


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout


def snapshot(out, label):
    with open(f"{out}/host.txt", "a") as f:
        f.write(f"== {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {label}\n")
        f.write(sh("uptime; pmset -g batt | head -1; top -l 2 -o cpu -n 6 -stats command,cpu | tail -6"))


def main():
    py, bench, out = sys.argv[1:4]
    if os.getpriority(os.PRIO_PROCESS, 0) != 0:
        sys.exit("not at nice 0; launch from sh, not zsh with &")
    if "Battery Power" in sh("pmset -g batt"):
        sys.exit("on battery power; plug in")
    os.makedirs(f"{out}/json", exist_ok=True)
    with open(f"{out}/host.txt", "w") as f:
        f.write(sh("uname -a; sw_vers; sysctl -n machdep.cpu.brand_string hw.memsize hw.ncpu; "
                   "system_profiler SPDisplaysDataType | grep -E 'Chipset|Total Number of Cores'"))
        f.write(sh(f"{py} -c \"import openmm as m; print('openmm', m.__version__, m.version.git_revision)\""))
        f.write(sh(f"shasum -a 256 {bench}"))
    for i, test in enumerate(TESTS):
        snapshot(out, test)
        for platform, precision in CONFIGS[i % 4:] + CONFIGS[:i % 4]:
            name = f"{test}-{platform}-{precision}"
            cmd = [py, bench, f"--platform={platform}", f"--precision={precision}", f"--test={test}",
                   f"--outfile={out}/json/{name}.json"]
            start = time.time()
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S)
                status = "ok" if r.returncode == 0 else f"exit {r.returncode}"
                log = r.stdout + r.stderr
            except subprocess.TimeoutExpired as e:
                status, log = f"timeout {TIMEOUT_S} s", (e.stdout or b"").decode() + (e.stderr or b"").decode()
            with open(f"{out}/runs.jsonl", "a") as f:
                f.write(json.dumps({"test": test, "platform": platform, "precision": precision,
                                    "status": status, "wall_s": round(time.time() - start, 1)}) + "\n")
            with open(f"{out}/log.txt", "a") as f:
                f.write(f"=== {name}: {status}\n{log}\n")
    snapshot(out, "end")
    open(f"{out}/DONE", "w").write("done\n")


if __name__ == "__main__":
    main()
