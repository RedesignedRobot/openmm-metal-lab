#!/bin/sh
# Workloads lane driver for workloads.py: <rounds> rounds over the given argument sets, each run a fresh
# process at nice 0, one lease.sh call per round (wl-round.sh); wrap the whole call in one lease.sh so the
# per-round calls run at once. Each run logs the load to <out>.top, and a round that ends with a build
# running is marked BUILD RUNNING. JSON lines go to <out>.
# usage: wl-run.sh <out.jsonl> <rounds> "<workloads.py args>"...
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-workloads
unset PYTHONPATH
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "not at nice 0" >&2; exit 2; }
out="$1"; rounds="$2"; shift 2
cd /tmp/openmm-metal-bench/ultra-base/benchmarks
r=1
while [ "$r" -le "$rounds" ]; do
    export WL_OUT="$out" WL_ROUND="$r"
    "$TOOLS/lease.sh" ultra-workloads "wl-run.sh $out round $r" "$D/wl-round.sh" "$@"
    pgrep -x 'clang|clang\+\+|ninja|cc1plus' >/dev/null && echo "$(date -u +%H:%M:%SZ) BUILD RUNNING at end of round $r" >> "$out.top"
    r=$((r+1))
done
echo "done $out"
