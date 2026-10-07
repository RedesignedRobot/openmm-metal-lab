#!/bin/sh
# covers: rmcheck.sh gpuq/gpuq   (install.sh runs this test when one of these changes)
# rmcheck.sh against an isolated gpuq instance, no GPU work: a path named in a queued job's argv or cwd,
# in either bench form, or held by a process is refused; a name that only shares a prefix, or an
# unrelated path, is removed; arguments are refused; a silent gpuqd removes nothing.
. "$(dirname "$0")/env.sh"
unset GPUQ_JOB OPENMM_LEASE_PID DRY
RM="$D/../rmcheck.sh"
BREAL=$(cd /tmp/openmm-metal-bench && pwd -P)
W=$T/rmcheck
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }

rm -rf $W $GPUQ_DIR $GPUQ_SOCK
mkdir -p $W/argv $W/cwd $W/alias $W/pre $W/pre-b $W/free $W/proc $W/dry $W/down
start_daemon
LATER="--not-before +2h"
# check <name> <want: kept|removed> <path as given to rmcheck> [path that must be gone or kept]
check() {
    name=$1 want=$2 given=$3 target=${4:-$3}
    out=$(printf '%s\n' "$given" | $RM 2>&1); code=$?
    if [ $want = kept ] && [ -e "$target" ] && [ $code = 1 ] && echo "$out" | grep -q '^SKIP'; then
        ok "$name: $out"
    elif [ $want = removed ] && [ ! -e "$target" ] && [ $code = 0 ]; then
        ok "$name: $out"
    else
        bad "$name: exit $code, $(/bin/ls -d "$target" 2>&1): $out"
    fi
}

echo "== 1: arguments are refused"
$RM $W/free > /dev/null 2>&1; code=$?
[ $code = 2 ] && [ -e $W/free ] && ok "exit 2, nothing removed" || bad "exit $code"

echo "== 2: gpuq jobs"
$Q submit --lane r3-tools $LATER --no-preflight -- /bin/sh -c "ls $W/argv/sub > /dev/null" > /dev/null
check "a queued job's argv names a path under it" kept $W/argv
(cd $W/cwd && $Q submit --lane r3-tools $LATER -- /bin/true > /dev/null)
check "a queued job's cwd" kept $W/cwd
alias_real=$BREAL/${W#/tmp/openmm-metal-bench/}/alias
$Q submit --lane r3-tools $LATER -- /bin/ls $alias_real > /dev/null
check "a job names the real bench path, rmcheck gets the /tmp form" kept $W/alias
$Q submit --lane r3-tools $LATER -- /bin/ls $W/pre-b > /dev/null
check "a job names pre-b, rmcheck gets pre" removed $W/pre
check "an unrelated path" removed $W/free

echo "== 3: a process's cwd, then gone after its recorded pid is killed"
(cd $W/proc && exec sleep 300) &
sleeper=$!
sleep 0.5
check "a process with its cwd inside" kept $W/proc
kill $sleeper
wait $sleeper 2>/dev/null
check "the same path after the process ended" removed $W/proc

$PY -c 'import time; time.sleep(300)' $W/cmd &
named=$!
mkdir -p $W/cmd
sleep 0.5
check "a process whose command line names it" kept $W/cmd
kill $named
wait $named 2>/dev/null
out=$(/bin/sh -c "printf '%s\\n' $W/cmd | $RM"); code=$?
[ $code = 0 ] && [ ! -e $W/cmd ] && ok "the caller's own command line names it: $out" || bad "exit $code: $out"

echo "== 4: DRY=1 and a missing path"
out=$(printf '%s\n' $W/dry $W/no-such | DRY=1 $RM); code=$?
echo "$out" | grep -q "^would rm $W/dry" && echo "$out" | grep -q "^SKIP $W/no-such: missing" && [ -e $W/dry ] && [ $code = 0 ] \
    && ok "DRY=1 keeps it; a missing path is reported" || bad "exit $code: $out"

echo "== 5: gpuqd down: nothing is removed"
kill $daemon
wait $daemon 2>/dev/null
check "gpuqd not answering" kept $W/down

rm -rf $W $GPUQ_DIR $GPUQ_SOCK
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
