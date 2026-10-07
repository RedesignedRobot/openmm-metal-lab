#!/bin/sh
# Runs inside one lease.sh timing hold on the M3 Ultra: an A/A of rf Metal single on ultra-base, 15 s per run, a and
# b per round. Round 1 quiet. Round 2 while one build.sh build (taskpolicy -b, -j8) compiles a scratch copy of
# ultra-base's src. Round 3 after the queued build.sh waiters are let go, the pileup that follows a window.
# /tmp/openmm-window, with this script's pid, holds build.sh waiters off through rounds 1 and 2, the way window.sh
# does. The round 2 build runs a copy of build.sh that doesn't wait on the flag (build-aa.sh, only WINDOW differs).
# usage: aa-build.sh [ignored]   (lease.sh 65447 was queued passing ultra-tools/build.sh, which would wait on our flag)
set -u
B=/tmp/openmm-metal-bench
AA=$B/ultra-infra/aa-build
S=$B/ultra-infra-aa
PY=$B/ultra-base/venv/bin/python
WINDOW=/tmp/openmm-window
build_sh=$B/ultra-infra/build-aa.sh
echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ) infra build.sh A/A, rounds 1 and 2 (not a window)" > "$WINDOW"
trap '[ "$(cut -d" " -f1 "$WINDOW" 2>/dev/null)" = $$ ] && rm -f "$WINDOW" || true' EXIT
echo "$(date -u +%H:%M:%SZ) /tmp/openmm-window is up"
builds() { pgrep -x 'clang|clang\+\+|ninja|cc1plus' | wc -l | tr -d ' '; }
cpu() {
    echo "$(date -u +%H:%M:%SZ) load $(sysctl -n vm.loadavg); build processes $(builds); build group $1 $(ps -A -o pgid=,%cpu= | awk -v g="$1" '$1 == g {n++; s += $2} END {printf "%%cpu %.0f, processes %d", s, n}'); all build processes %cpu $(ps -A -o %cpu=,comm= | awk '$2 ~ /(^|\/)(clang|clang\+\+|ninja|cc1plus)$/ {s += $1} END {printf "%.0f", s}')"
}
# Round 1 waits for no build at all: a background build in both rounds would make them agree for the wrong reason.
until [ "$(builds)" = 0 ]; do
    [ -n "${told:-}" ] || echo "$(date -u +%H:%M:%SZ) waiting for $(builds) build processes to finish"
    told=1
    sleep 5
done
echo "$(date -u +%H:%M:%SZ) round 1, quiet (0 build processes)"
$B/ultra-tools/ab.sh $AA/r1 1 15 rf a=$PY:Metal:single b=$PY:Metal:single
# job control gives the build its own process group, so its compilers can be counted by it
set -m
$build_sh $S > $S/build.out 2>&1 < /dev/null &
bpid=$!
set +m
echo "build $bpid"
until [ "$(grep -c '^\[' $S/logs/build.log 2>/dev/null || echo 0)" -ge 200 ]; do
    kill -0 $bpid 2>/dev/null || { echo "build exited before compiling"; tail -20 $S/build.out; exit 1; }
    sleep 2
done
cpu $bpid
echo "$(date -u +%H:%M:%SZ) round 2, one build compiling"
$B/ultra-tools/ab.sh $AA/r2 1 15 rf a=$PY:Metal:single b=$PY:Metal:single &
abpid=$!
sleep 10
cpu $bpid
wait $abpid
cpu $bpid
[ "$(cut -d" " -f1 "$WINDOW" 2>/dev/null)" = $$ ] && rm -f "$WINDOW"
echo "$(date -u +%H:%M:%SZ) /tmp/openmm-window is down; build.sh waiters poll every 30 s"
sleep 60
cpu $bpid
echo "$(date -u +%H:%M:%SZ) round 3, the waiters' builds and ours"
$B/ultra-tools/ab.sh $AA/r3 1 15 rf a=$PY:Metal:single b=$PY:Metal:single &
abpid=$!
sleep 10
cpu $bpid
wait $abpid
cpu $bpid
echo "$(date -u +%H:%M:%SZ) AA DONE; the builds keep going outside the hold"
