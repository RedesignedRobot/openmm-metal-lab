#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
B=/tmp/openmm-metal-bench/ultra-int028
T=/tmp/openmm-metal-bench/ultra-tools
stage=wait-for-cpu
finish() {
    code=$?
    echo "exit=$code stage=$stage" > "$D/screen-dhfr-quiet.verdict"
}
trap finish EXIT
test "$(cat "$D/smoke.exit")" = 0
python3 - <<'PY'
import datetime
import os
import subprocess
import time
quiet=0
print('Waiting outside GPU queue for Node/Bun/build CPU below 150% (reduced contention) across two 30 s samples',flush=True)
while quiet < 2:
    rows=subprocess.check_output(['ps','-A','-o','pcpu=,comm='],text=True)
    total=0.
    for row in rows.splitlines():
        fields=row.strip().split(None,1)
        if len(fields)==2 and os.path.basename(fields[1]) in {'node','bun','clang','clang++','ninja','cc1plus'}:
            total+=float(fields[0])
    quiet=quiet+1 if total<150 else 0
    if quiet:
        print(datetime.datetime.now(datetime.timezone.utc).isoformat(),f'reduced-contention sample {quiet}: watched CPU {total:.1f}%',flush=True)
    if quiet < 2:
        time.sleep(30)
PY
stage=ab
"$T/ab.sh" "$D/screen-dhfr-quiet" 2 15 amber20-dhfr \
    base-s="$B/venv/bin/python:Metal:single" \
    cpu-s="$D/venv/bin/python:Metal:single" \
    base-m="$B/venv/bin/python:Metal:mixed" \
    cpu-m="$D/venv/bin/python:Metal:mixed" \
    opencl="$B/venv/bin/python:OpenCL:single"
"$B/venv/bin/python" "$T/summarize.py" "$D/screen-dhfr-quiet" cpu-s/base-s cpu-m/base-m cpu-s/opencl cpu-m/opencl > "$D/screen-dhfr-quiet/summary.txt"
stage=complete
cat "$D/screen-dhfr-quiet/summary.txt"
