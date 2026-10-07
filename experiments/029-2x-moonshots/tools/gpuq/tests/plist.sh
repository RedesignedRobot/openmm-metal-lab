#!/bin/sh
# covers: gpuq/com.openmm.gpuqd.plist install.sh   (install.sh runs this test when one of these changes)
# The launch agent's reboot rules, from the 2026-09-29 18:45Z reboot: launchd creates WorkingDirectory
# and the log directories before the command runs, so a /tmp/openmm-metal-bench path there becomes a
# real folder that blocks the symlink, and gpuqd loops on a missing python. The plist must keep those
# keys under the real bench path and recreate the symlink before it starts gpuqd. Read only, no daemon.
# usage: plist.sh   (checks the lab plist beside this test; the installed launch agent is install.sh's note)
plist=$(cd "$(dirname "$0")/.." && pwd)/com.openmm.gpuqd.plist
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }
key() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null; }

echo "== 1: WorkingDirectory and the log paths are real paths, not /tmp"
for k in WorkingDirectory StandardOutPath StandardErrorPath; do
    v=$(key $k)
    case "$v" in
    "") bad "$k is missing" ;;
    /tmp/*|/private/tmp/*) bad "$k is under /tmp: $v" ;;
    /*) ok "$k = $v" ;;
    *) bad "$k is not absolute: $v" ;;
    esac
done

echo "== 2: the paths sit under the bench the /tmp symlink points at"
wd=$(key WorkingDirectory)
real=$(cd /tmp/openmm-metal-bench 2>/dev/null && pwd -P)
if [ -z "$real" ]; then
    ok "no /tmp/openmm-metal-bench on this machine; skipped"
elif [ "$wd" = "$real" ]; then
    ok "WorkingDirectory is the symlink's target $real"
else
    bad "WorkingDirectory $wd is not the symlink's target $real"
fi
for k in StandardOutPath StandardErrorPath; do
    v=$(key $k)
    case "$v" in
    "$wd"/*) ok "$k is under WorkingDirectory" ;;
    *) bad "$k $v is outside WorkingDirectory $wd" ;;
    esac
done

echo "== 3: the command recreates the symlink to WorkingDirectory before it starts gpuqd"
cmd=$(key ProgramArguments.2)
case "$cmd" in
*"ln -sfn $wd /tmp/openmm-metal-bench"*"gpuqd.py"*) ok "ln -sfn $wd, then gpuqd.py" ;;
*) bad "command: $cmd" ;;
esac
[ "$(key ProgramArguments.0)" = /bin/sh ] && [ "$(key ProgramArguments.1)" = -c ] \
    && ok "runs through /bin/sh -c" || bad "ProgramArguments does not start with /bin/sh -c"

echo "== 4: a restart never kills a job, and the agent restarts on its own"
[ "$(key AbandonProcessGroup)" = true ] && ok "AbandonProcessGroup true" || bad "AbandonProcessGroup is not true"
[ "$(key KeepAlive)" = true ] && ok "KeepAlive true" || bad "KeepAlive is not true"
[ "$(key RunAtLoad)" = true ] && ok "RunAtLoad true" || bad "RunAtLoad is not true"

echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
