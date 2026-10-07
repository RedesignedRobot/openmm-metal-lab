#!/bin/sh
# covers: gpuq/gpuq gpuq/gpuqd.py window.sh ab.sh holdout.sh gate.sh check-pin.py srchash.sh   (install.sh runs this test when one of these changes)
# gpuq submit's preflight on an isolated instance, no GPU work: each checked tool in a job runs its own
# checks with GPUQ_PREFLIGHT=1 at submit, so a job that would fail at its start is refused before it
# queues. The tools run from a test tools dir whose lease.sh only prints its arguments.
# usage: preflight.sh <build.sh tree>   (read only: its venv, build, BUILT, src and PINNED)
. "$(dirname "$0")/env.sh"
unset OPENMM_LEASE_PID GPUQ_JOB LEASE_TICKET_US OPENMM_WINDOW AB_HELD HOLDOUT_HELD GATE_HELD GPUQ_PREFLIGHT
tree=${1:?usage: preflight.sh <build.sh tree>}
TOOLS_SRC=$D/..
TT=$T/tools
OUT=$T/out
STALE=$T/stale
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }

rm -rf $TT $OUT $STALE $GPUQ_DIR $GPUQ_SOCK
mkdir -p $TT/gpuq $OUT $STALE/src
for f in $TOOLS_SRC/*; do [ -f "$f" ] && ln -s "$f" "$TT/"; done
ln -s $D/gpuq $TT/gpuq/gpuq
for s in window.sh ab.sh holdout.sh gate.sh; do
    rm $TT/$s
    sed "s|^TOOLS=.*|TOOLS=$TT|" $TOOLS_SRC/$s > $TT/$s
    chmod +x $TT/$s
done
printf '#!/bin/sh\necho "fake lease.sh $*"\n' > $TT/lease.sh
chmod +x $TT/lease.sh
# A tree whose src changed after its build: the real tree's venv and build, its own src and a stale BUILT.
ln -s $tree/venv $STALE/venv
ln -s $tree/build $STALE/build
echo edited > $STALE/src/file.cpp
printf 'commit 0000000\nsrc 0000000000000000000000000000000000000000\n' > $STALE/BUILT

jobs_now() { $Q ls | grep -cE '^ +[0-9]+ ' || true; }

# refused <name> <expected text> <submit args...>: the submit fails with the text and queues nothing.
refused() {
    name=$1 want=$2; shift 2
    before=$(jobs_now)
    out="$($Q submit "$@" 2>&1)"; code=$?
    after=$(jobs_now)
    case "$code:$out" in
    0:*) bad "$name: queued: $(echo "$out" | tail -1)" ;;
    *"$want"*) [ "$after" = "$before" ] && ok "$name: $(echo "$out" | grep -m1 -F "$want" | sed 's/^ *//')" \
        || bad "$name: refused, but the queue changed" ;;
    *) bad "$name: exit $code: $out" ;;
    esac
}

# queued <name> <expected text> <submit args...>: the submit queues a job; prints its id.
queued() {
    name=$1 want=$2; shift 2
    out="$($Q submit "$@" 2>&1)"
    jid=$(echo "$out" | sed -n 's/^job \([0-9]*\) queued.*/\1/p')
    if [ -n "$jid" ] && echo "$out" | grep -qF "$want"; then
        ok "$name: job $jid queued: $(echo "$out" | grep -m1 -F "$want")"
    else
        bad "$name: $out"
    fi
}

start_daemon
LATER="--not-before +2h"

echo "== 1: stale BUILT, a missing path and an outdir with the tool's own outputs are refused at submit"
refused "window.sh over a tree whose src changed" "src changed after build.sh" \
    --class window --lane lead --est 30m $LATER -- $TT/window.sh $OUT/w1 gbsa t=$tree:single s=$STALE:single
mkdir -p $OUT/ab1 && touch $OUT/ab1/loads.txt
refused "ab.sh over an outdir with an earlier screen" "already holds loads.txt" \
    --lane lead $LATER -- $TT/ab.sh $OUT/ab1 1 5 gbsa t=$tree/venv/bin/python:Metal:single
refused "ab.sh with a stale tree's python" "src changed after build.sh" \
    --lane lead $LATER -- $TT/ab.sh $OUT/ab2 1 5 gbsa s=$STALE/venv/bin/python:Metal:single
refused "holdout.sh with a missing candidate tree" "venv/bin/python is missing" \
    --class window --lane lead --est 30m $LATER -- $TT/holdout.sh $tree $T/no-such-tree $OUT/ho1
refused "gate.sh on a missing tree" "has no venv or build" \
    --class correctness --lane lead $LATER -- $TT/gate.sh --quick $T/no-such-tree
refused "a missing tool" "does not exist" \
    --lane lead $LATER -- $T/no-such-dir/ab.sh $OUT/ab3 1 5 gbsa t=$tree/venv/bin/python:Metal:single

echo "== 2: a window whose estimate is over the job's cap is refused at submit"
refused "window.sh, 9 tests x 2 precisions (about 37 min + 10 preflight), --est 5m (cap 30 min)" "cap left" \
    --class window --lane lead --est 5m $LATER -- $TT/window.sh $OUT/w2 all t=$tree:single,mixed

echo "== 3: the w4 launch line (sh -c, \$T, window.sh then holdout.sh) passes and writes nothing"
queued "window and holdout in one sh -c" "preflight ok: holdout.sh" \
    --class window --lane lead --est 110m $LATER -- /bin/sh -c "T=$TT; \$T/window.sh $OUT/w4 all t=$tree:single,mixed; w=\$?; \${T}/holdout.sh $tree $tree $OUT/w4/holdout; h=\$?; exit \$((w | h))"
w4=$jid
[ ! -e $OUT/w4 ] && ok "the preflight left no outdir behind" || bad "the preflight created $OUT/w4"
$Q cancel $w4 --lane lead > /dev/null

echo "== 4: what the preflight can't expand is skipped with a note; --no-preflight skips the check"
queued "gate.sh on \"\$1\"" "job" \
    --class correctness --lane lead $LATER -- /bin/sh -c "$TT/gate.sh --quick \"\$1\"" gate $tree
$Q cancel $jid --lane lead > /dev/null
out="$($Q submit --class correctness --lane lead $LATER -- /bin/sh -c "$TT/gate.sh --quick \"\$1\"" gate $tree 2>&1)"
echo "$out" | grep -q 'preflight skipped for gate.sh' && ok "the skip is reported" || bad "no skip note: $out"
$Q cancel $(echo "$out" | sed -n 's/^job \([0-9]*\) queued.*/\1/p') --lane lead > /dev/null
queued "--no-preflight over the stale tree" "job" \
    --class window --lane lead --est 30m --no-preflight $LATER -- $TT/window.sh $OUT/w5 gbsa s=$STALE:single
$Q cancel $jid --lane lead > /dev/null

echo "== 5: a job that passes runs as before"
out="$($Q submit --lane lead --wait -- $TT/ab.sh $OUT/ab6 1 5 gbsa t=$tree/venv/bin/python:Metal:single 2>&1)"; code=$?
jid=$(echo "$out" | sed -n 's/^job \([0-9]*\) queued.*/\1/p')
if [ $code = 0 ] && grep -q 'fake lease.sh' $GPUQ_DIR/jobs/$jid/out.log; then
    ok "ab.sh passed the preflight, ran and reached lease.sh: $(echo "$out" | tail -1)"
else
    bad "exit $code: $out"
fi

kill $daemon 2>/dev/null
rm -rf $TT $OUT $STALE
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
