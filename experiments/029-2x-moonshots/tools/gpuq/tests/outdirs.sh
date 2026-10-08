#!/bin/sh
# covers: gpuq/gpuq gpuq/gpuqd.py window.sh ab.sh holdout.sh   (install.sh runs this test when one of these changes)
# Dry check of the round 3 outdir rules and window.sh's cap check, no GPU work. The scripts run from a test
# tools dir whose lease.sh only prints its arguments, so a script that passes its checks ends there.
# 1. window.sh, ab.sh and holdout.sh start in an outdir that holds an unrelated file (a launcher's log),
#    and refuse one that holds their own earlier outputs.
# 2. window.sh under a gpuq window job (isolated instance) exits 2 at once when the job's cap is under its
#    estimate plus preflight, and passes when the cap covers it.
# usage: outdirs.sh <build.sh tree>   (read only: its venv python, BUILT and src hash)
. "$(dirname "$0")/env.sh"
unset OPENMM_LEASE_PID GPUQ_JOB LEASE_TICKET_US OPENMM_WINDOW AB_HELD HOLDOUT_HELD
tree=${1:?usage: outdirs.sh <build.sh tree>}
TOOLS_SRC=$D/..
TT=$T/tools
OUT=$T/out
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }

rm -rf $TT $OUT $GPUQ_DIR $GPUQ_SOCK
mkdir -p $TT/gpuq $OUT
for f in $TOOLS_SRC/*; do [ -f "$f" ] && ln -s "$f" "$TT/"; done
ln -s $D/gpuq $TT/gpuq/gpuq
for s in window.sh ab.sh holdout.sh; do
    rm $TT/$s
    sed "s|^TOOLS=.*|TOOLS=$TT|" $TOOLS_SRC/$s > $TT/$s
    chmod +x $TT/$s
done
printf '#!/bin/sh\necho "fake lease.sh $*"\n' > $TT/lease.sh
chmod +x $TT/lease.sh

# expect <name> <pass|refuse> <outdir> <command...>
expect() {
    name=$1 want=$2; shift 2
    out="$("$@" 2>&1)"; code=$?
    last="$(echo "$out" | tail -1)"
    case "$want:$code:$last" in
    pass:0:"fake lease.sh"*) ok "$name: reached lease.sh" ;;
    refuse:2:*) ok "$name: refused: $last" ;;
    *) bad "$name: exit $code: $last" ;;
    esac
}

echo "== 1: an unrelated file doesn't block an outdir; the script's own outputs do"
for s in window ab holdout; do mkdir -p $OUT/$s; echo launcher > $OUT/$s/launch.log; done
expect "window.sh beside launch.log" pass $TT/window.sh $OUT/window gbsa t=$tree:single
expect "ab.sh beside launch.log" pass $TT/ab.sh $OUT/ab 1 5 gbsa t=$tree/venv/bin/python:Metal:single
expect "holdout.sh beside launch.log" pass $TT/holdout.sh $tree $tree $OUT/holdout
touch $OUT/window/summary.txt; mkdir -p $OUT/window/ab
expect "window.sh over an earlier window" refuse $TT/window.sh $OUT/window gbsa t=$tree:single
touch $OUT/ab/loads.txt
expect "ab.sh over an earlier screen" refuse $TT/ab.sh $OUT/ab 1 5 gbsa t=$tree/venv/bin/python:Metal:single
expect "holdout.sh over an earlier holdout (its configs.txt)" refuse $TT/holdout.sh $tree $tree $OUT/holdout

echo "== 2: window.sh refuses a gpuq job whose cap is under its estimate plus preflight"
start_daemon
estimate=$($TT/window.sh --estimate $OUT/w2 all t=$tree:single,mixed | sed -n 's/.*about \([0-9]*\) minutes/\1/p')
echo "  window.sh --estimate: about $estimate min, plus 10 min of preflight"
for cap in 30m 2h; do
    # --no-preflight: the submit's preflight (preflight.sh) would refuse the 30m cap before the job starts.
    jid=$($Q submit --class window --lane lead --est 20m --cap $cap --no-preflight -- $TT/window.sh $OUT/w-$cap all t=$tree:single,mixed \
        | sed -n 's/^job \([0-9]*\) queued.*/\1/p')
    code=$($Q wait $jid > /dev/null; echo $?)
    last="$(tail -1 $GPUQ_DIR/jobs/$jid/out.log)"
    case "$cap:$code:$last" in
    30m:2:*"cap left"*) ok "cap $cap: exit 2 at once: $last" ;;
    2h:0:"fake lease.sh"*) ok "cap $cap: passed the check and reached lease.sh" ;;
    *) bad "cap $cap: exit $code: $last" ;;
    esac
done
kill $daemon 2>/dev/null
rm -rf $TT $OUT
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
