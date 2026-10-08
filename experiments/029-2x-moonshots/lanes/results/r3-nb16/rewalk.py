"""Load existing embedded profiles without GPU replay. No lease needed (head confirmed)."""
import datetime
import os
from pathlib import Path
import shutil
import subprocess
import sys

here = Path(__file__).resolve().parent
env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer")
for label in ("control", "compact"):
    now = datetime.datetime.now(datetime.timezone.utc)
    if now.hour < 7 or (now.hour == 23 and now.minute >= 50):
        raise SystemExit("quiet hours or insufficient cleanup margin")
    out = here/"counters"/label
    previous = out/"target-empty.jsonl"
    if not previous.exists():
        shutil.copy2(out/"target.jsonl", previous)
    trace = out.parent/("r3-nb16-"+label+".gputrace")
    print(label+": loading embedded profile", flush=True)
    profiler = subprocess.Popen([sys.executable, str(here/"gdtarget.py"),
                                str(trace), str(out), "--load-only"], env=env)
    try:
        if profiler.wait(timeout=300) != 0:
            raise RuntimeError("profile walk failed")
    finally:
        if profiler.poll() is None:
            profiler.terminate()
            try:
                profiler.wait(timeout=25)
            except subprocess.TimeoutExpired:
                profiler.kill()
                profiler.wait()
print("paired profile walk complete", flush=True)
