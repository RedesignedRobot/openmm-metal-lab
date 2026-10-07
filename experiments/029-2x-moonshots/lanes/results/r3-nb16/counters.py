"""One paired capture on fixed coordinates. Run under a timing lease."""
import datetime
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time

here = Path(__file__).resolve().parent
tree = Path("/tmp/openmm-metal-bench/ultra-r3-nb16")
if datetime.datetime.now(datetime.timezone.utc).hour < 7:
    raise SystemExit("quiet hours")
# Stop with forty seconds left for our runner and profiler to release GPU resources.
now = datetime.datetime.now(datetime.timezone.utc)
midnight = (now+datetime.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
def quiet_deadline(signum, frame):
    raise TimeoutError("quiet-hours deadline: stopping this lane's GPU children")
signal.signal(signal.SIGALRM, quiet_deadline)
remaining = int((midnight-now).total_seconds())-40
if remaining <= 0: raise SystemExit("too close to quiet hours")
signal.alarm(remaining)
env = dict(os.environ, MTL_CAPTURE_ENABLED="1", DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer")
for label in (sys.argv[1:] or ["control", "compact"]):
    out = here/"counters"/label
    out.mkdir(parents=True, exist_ok=True)
    trace = out.parent/("r3-nb16-"+label+".gputrace")
    if trace.exists(): raise RuntimeError("refuse to overwrite trace: "+str(trace))
    cmd = [str(tree/"venv/bin/python"), str(here/"replay.py"), "--tree", str(tree),
           "--bench", "/tmp/openmm-metal-bench/ultra-base/benchmarks", "--capture", label,
           "--seconds", "180"]
    runner = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    (out/"pid").write_text(str(runner.pid))
    try:
        with (out/"replay.log").open("w") as log:
            selector = selectors.DefaultSelector()
            selector.register(runner.stdout, selectors.EVENT_READ)
            deadline = time.monotonic()+120
            while True:
                ready = selector.select(max(0, deadline-time.monotonic()))
                if not ready: raise TimeoutError("replay readiness")
                line = runner.stdout.read1(65536).decode()
                if not line: raise RuntimeError("replay exited before READY")
                log.write(line); log.flush()
                print(label+": "+line, end="", flush=True)
                if any(part.startswith("READY ") for part in line.splitlines()): break
        for name, args in [("list", ["list"]), ("boundaries", ["boundaries", "--pid", str(runner.pid)]),
            ("capture", ["start", "--pid", str(runner.pid), "--count", "12", "--output", str(trace)])]:
            with (out/(name+".txt")).open("w") as log:
                subprocess.run(["gpucapture"]+args, env=env, stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=120 if name == "capture" else 15)
    finally:
        if runner.poll() is None: runner.terminate()
        runner.wait(timeout=15)
    print(label+": trace captured", flush=True)
    profiler = subprocess.Popen([sys.executable, str(here/"gdtarget.py"), str(trace), str(out)], env=env)
    try:
        if profiler.wait() != 0: raise RuntimeError("counter profiler failed")
    finally:
        if profiler.poll() is None:
            profiler.terminate()
            try: profiler.wait(timeout=25)
            except subprocess.TimeoutExpired:
                profiler.kill(); profiler.wait()
signal.alarm(0)
