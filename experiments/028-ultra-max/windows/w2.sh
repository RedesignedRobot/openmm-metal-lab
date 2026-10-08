#!/bin/sh
# Window 2 on the M3 Ultra at nice 0, in one timing hold (the lead's plan of 2026-09-25): the window flag, a
# preflight, workloads' agg.py rf cases in 2 rounds (f1 f4 b1 b4 o4, then reversed), then window.sh nested
# in the same hold with window 1's arms, 3x30 s, and the CPU arm. It queues like window.sh: just before the
# oldest normal ticket, behind merge-path tickets and the current hold. The cap is 9000 s (the lead's call):
# window 1 took 108 minutes against its 104 minute estimate, and a cap hit would lose the whole window.
#   /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-infra/w2.sh > /tmp/openmm-metal-bench/ultra-infra/w2.out 2>&1 < /dev/null &'
set -eu
export LC_ALL=C
B=/tmp/openmm-metal-bench
TOOLS=$B/ultra-tools
QUEUE=/tmp/openmm-lease-queue
WINDOW=/tmp/openmm-window
TICKET='[0-9]+-[A-Za-z0-9_.-]+-[0-9]+'
OUT=$B/ultra-infra/w2
AGG=$B/ultra-infra/w2-agg
BASE=$B/ultra-base/venv/bin/python
FINAL=$B/ultra-integrated/venv/bin/python
ARMS="base=$B/ultra-base:single,mixed,opencl int=$B/ultra-integrated:single,mixed"
LOAD_MAX=3
BUILDS='clang|clang\+\+|ninja|cc1plus'
PREFLIGHT_MAX_SECONDS=600
AGG_WINDOW_SECONDS=10
CAP_SECONDS=9000

nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; exit 2; }

if [ -z "${OPENMM_WINDOW:-}" ]; then
    [ ! -e "$OUT" ] || { echo "$OUT exists; window 2 already ran or is running" >&2; exit 2; }
    window_minutes="$($TOOLS/window.sh --estimate --cpu "$OUT" all $ARMS | sed -n 's/.*about \([0-9]*\) minutes$/\1/p')"
    [ -n "$window_minutes" ] || { echo "window.sh --estimate gave no minutes" >&2; exit 2; }
    oldest="$(ls "$QUEUE" 2>/dev/null | grep -xE "$TICKET" | grep -v '^0' | sort | head -1 | cut -d- -f1)"
    ticket_us="$(perl -MTime::HiRes=gettimeofday -e '($s, $us) = gettimeofday; printf "%d%06d\n", $s, $us')"
    [ -n "$oldest" ] && ticket_us=$((oldest - 1))
    echo "$(date -u +%H:%M:%SZ) window 2: cap $CAP_SECONDS s, window.sh estimate $window_minutes min plus about 10 min of agg; $("$TOOLS/lease.sh" --status | head -1)"
    OPENMM_WINDOW=1 LEASE_TICKET_US=$ticket_us exec "$TOOLS/lease.sh" --cap $CAP_SECONDS window \
        "window 2: agg rf 2 rounds, then window.sh 3x30 s + CPU on $OUT; lanes wait, build.sh waits" "$0"
fi

echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ) $OUT" > "$WINDOW"
trap '[ "$(cut -d" " -f1 "$WINDOW" 2>/dev/null)" = $$ ] && rm -f "$WINDOW" || true' EXIT
echo "$(date -u +%H:%M:%SZ) holding the lease; /tmp/openmm-window is up"
waited=0
while :; do
    load="$(sysctl -n vm.loadavg | awk '{ print $2 }')"
    builds="$(pgrep -x "$BUILDS" | wc -l | tr -d ' ')"
    [ "$(awk -v l="$load" -v m=$LOAD_MAX 'BEGIN { print (l < m) }')" = 1 ] && [ "$builds" = 0 ] && break
    if [ $waited -ge $PREFLIGHT_MAX_SECONDS ]; then
        echo "agg preflight: not quiet after $waited s (load $load, $builds build processes); starting anyway"
        break
    fi
    sleep 10
    waited=$((waited + 10))
done
echo "$(date -u +%H:%M:%SZ) agg start after $waited s of preflight, load $(sysctl -n vm.loadavg)"
{ echo "final $(grep -m1 '^commit' $B/ultra-integrated/BUILT)"; echo "base $(grep -m1 '^commit' $B/ultra-base/BUILT)"; } | tee -a "$AGG/built.txt"
cd "$AGG"
for round in 1 2; do
    cases="f1 f4 b1 b4 o4"
    [ $round = 2 ] && cases="o4 b4 b1 f4 f1"
    for c in $cases; do
        case $c in
        f1) py=$FINAL; n=1; platform=Metal ;;
        f4) py=$FINAL; n=4; platform=Metal ;;
        b1) py=$BASE; n=1; platform=Metal ;;
        b4) py=$BASE; n=4; platform=Metal ;;
        o4) py=$BASE; n=4; platform=OpenCL ;;
        esac
        echo "$(date -u +%H:%M:%SZ) agg $c-r$round"
        "$py" "$AGG/agg.py" case "$AGG" $AGG_WINDOW_SECONDS "$c-r$round" $n $platform single rf || echo "agg $c-r$round FAILED"
    done
done
echo "$(date -u +%H:%M:%SZ) agg done; window.sh next"
cd /
mkdir "$OUT"
# Nested in this hold (OPENMM_WINDOW=1): window.sh rewrites the flag with this same pid and removes it at exit.
exec "$TOOLS/window.sh" --cpu "$OUT" all $ARMS
