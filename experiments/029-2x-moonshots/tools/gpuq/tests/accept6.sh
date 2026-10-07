#!/bin/sh
# gpuq acceptance check 6: ab.sh and window.sh, unchanged apart from their paths, run through the lease.sh
# shim against an isolated gpuqd. It times on the GPU, so run it inside a real lease.sh ticket:
#   /tmp/openmm-metal-bench/ultra-tools/lease.sh infra "gpuq check 6, about 4 min" <this file>
# The test copies differ from ultra-tools only in TOOLS (a test dir: the shim, ab.sh, window.sh, this
# tree's build-policy.py, links to the rest), window.sh's /tmp/openmm-window and queue dir, and the shim's
# gpuq path. 6a and 6d check the build witness, ab.sh's last line: a gpuq build job the screen paused is
# named there, and a build outside gpuq that ran during the timed runs marks them BUILD RUNNING.
. "$(dirname "$0")/env.sh"
unset OPENMM_LEASE_PID GPUQ_JOB LEASE_TICKET_US OPENMM_WINDOW AB_HELD
U=/tmp/openmm-metal-bench/ultra-tools
TT=$T/tools
OUT=/tmp/openmm-metal-bench/ultra-infra/gpuq6
BASE=/tmp/openmm-metal-bench/ultra-base
DB=$GPUQ_DIR/state.db
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }
check() { if [ "$1" = "$2" ]; then ok "$3: $1"; else bad "$3: got '$1', want '$2'"; fi; }
sql() { $PY -c "import sqlite3,sys; c=sqlite3.connect('$DB'); [print(*r) for r in c.execute(sys.argv[1])]" "$1"; }
# A released hold ends on gpuqd's next tick, once its process group is gone, so wait for that before reading it.
ended() { while [ -n "$(sql "select id from jobs where cls = '$1' and state != 'ended'")" ]; do sleep 0.2; done; }

[ ! -e $OUT ] || { echo "$OUT exists; move it first" >&2; exit 2; }
rm -rf $TT $GPUQ_DIR $GPUQ_LEASE_DIR $GPUQ_QUEUE_DIR $GPUQ_SOCK
mkdir -p $TT
for f in $U/*; do [ -f "$f" ] && ln -s "$f" "$TT/"; done
rm -f $TT/ab.sh $TT/window.sh $TT/lease.sh $TT/build-policy.py
ln -s $D/../build-policy.py $TT/build-policy.py
sed "s|^TOOLS=.*|TOOLS=$TT|" $U/ab.sh > $TT/ab.sh
sed "s|^TOOLS=.*|TOOLS=$TT|; s|^WINDOW=.*|WINDOW=$T/window|; s|^QUEUE=.*|QUEUE=$GPUQ_QUEUE_DIR|" $U/window.sh > $TT/window.sh
sed "s|^TOOLS=.*|TOOLS=$TT|; s|\"\$TOOLS/gpuq/gpuq\"|$D/gpuq|" $D/lease.sh > $TT/lease.sh
chmod +x $TT/ab.sh $TT/window.sh $TT/lease.sh
diff $U/ab.sh $TT/ab.sh | sed 's/^/    /'
diff $U/window.sh $TT/window.sh | sed 's/^/    /'
start_daemon

# A ninja build like build.sh's: two endless jobs, each in its own process group.
B=$T/build6; rm -rf $B; mkdir -p $B
printf 'rule tick\n  command = sh -c "while :; do sleep 1; done"\nbuild j1: tick\nbuild j2: tick\n' > $B/build.ninja

echo "== 6a: ab.sh screen (1 round of 5 s, gbsa, one configuration) through the shim, a gpuq build job running"
(cd $B && $D/gpuq hold --class build --lane build6 --what "build.sh $B" -- /tmp/openmm-metal-bench/env/bin/ninja -j 2 > /dev/null 2>&1) &
client=$!
while [ "$(sql "select pgid is not null from jobs where lane = 'build6'")" != 1 ]; do sleep 0.5; done
sleep 1
/bin/sh -c "$TT/ab.sh $OUT/ab 1 5 gbsa base=$BASE/venv/bin/python:Metal:single" > $T/ab6.out 2>&1
check "$?" 0 "ab.sh exit"
tail -3 $T/ab6.out | sed 's/^/    /'
ended timing
check "$(sql "select cls || ' ' || kind || ' ' || reason || ' ' || exit_code from jobs where cls = 'timing'")" "timing attached exit 0" "one gpuq job for the whole screen"
[ -s $OUT/ab/base-gbsa-round1.json ] && ok "result file written" || bad "no result file in $OUT/ab"
witness=$(grep ' builds: ' $OUT/ab/loads.txt | tail -1)
case "$witness" in
*"builds: none ran during the "*"timing hold of gpuq job "*": 1 builds paused, build6") ok "witness names the paused build: $witness" ;;
*) bad "witness: $witness" ;;
esac
$D/gpuq cancel "$(sql "select id from jobs where lane = 'build6'")" --lane build6 > /dev/null
wait $client

echo "== 6b: window.sh --smoke through the shim"
/bin/sh -c "$TT/window.sh --smoke $OUT/w gbsa base=$BASE:single,opencl" > $T/w6.out 2>&1
check "$?" 0 "window.sh exit"
tail -4 $T/w6.out | sed 's/^/    /'
ended window
check "$(sql "select cls || ' ' || reason || ' ' || exit_code from jobs where cls = 'window'")" "window exit 0" "one gpuq window job, ab.sh inside it without a new ticket"
check "$(sql "select count(*) from jobs where cls in ('timing', 'window')")" 2 "timing and window jobs so far (6a, 6b)"
[ -s $OUT/w/summary.txt ] && ok "summary.txt written" || bad "no $OUT/w/summary.txt"
[ ! -e $T/window ] && ok "the test window file is gone" || bad "$T/window left behind"

echo "== 6d: a build outside gpuq during an ab.sh screen is marked BUILD RUNNING"
(cd $B && exec /tmp/openmm-metal-bench/env/bin/ninja -j 2 > /dev/null 2>&1) &
raw=$!
sleep 1
/bin/sh -c "$TT/ab.sh $OUT/ab-raw 1 5 gbsa base=$BASE/venv/bin/python:Metal:single" > $T/ab6d.out 2>&1
check "$?" 0 "ab.sh exit"
kill $raw; wait $raw 2>/dev/null
sleep 1
check "$(ps -axo command= | grep -c '^sh -c while :; do sleep 1; done$')" 0 "build jobs left after ninja got SIGTERM"
witness=$(grep ' builds: ' $OUT/ab-raw/loads.txt | tail -1)
case "$witness" in
*"builds: BUILD RUNNING on 1 of 1 timed runs"*) ok "witness: $witness" ;;
*) bad "witness: $witness" ;;
esac

echo "== 6c: lease.sh --status through the shim, in the legacy format"
GPUQ_LANE=infra $D/gpuq submit --class timing --est 20 -- sleep 20 > /dev/null
GPUQ_LANE=other $D/gpuq submit --class correctness --est 5 -- sleep 5 > /dev/null
sleep 2
$TT/lease.sh --status > $T/status6.out
sed 's/^/    /' $T/status6.out
grep -Eq '^holder: .*, pid [0-9]+.*, held [0-9]+ s$' $T/status6.out && ok "holder line matches the legacy format" || bad "holder line"
grep -Eq "^build processes: [0-9]+" $T/status6.out && ok "build line matches the legacy format" || bad "build line"
grep -Eq '^  [0-9]+-other-[0-9]+  correctness  waiting [0-9]+ s$' $T/status6.out && ok "queue line matches the legacy format" || bad "queue line"
[ "$(cat $GPUQ_LEASE_DIR/owner 2>/dev/null | cut -c1-5)" = infra ] && ok "mirror owner: $(cat $GPUQ_LEASE_DIR/owner)" || bad "mirror owner: $(cat $GPUQ_LEASE_DIR/owner 2>/dev/null)"
while [ -n "$(sql "select id from jobs where state != 'ended'")" ]; do sleep 0.5; done
kill $daemon
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
