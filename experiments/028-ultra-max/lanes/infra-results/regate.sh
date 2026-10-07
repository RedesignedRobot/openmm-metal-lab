#!/bin/sh
# Restarts one waiting full gate on the one-hold gate.sh with its current ticket's time.
# usage: regate.sh <gate.sh pid> <dir> <new log>
set -eu
T=/tmp/openmm-metal-bench/ultra-tools
gate="$1"; dir="$2"; log="$3"
ps -o command= -p "$gate" | grep -q "ultra-tools/gate.sh $dir\$" || { echo "pid $gate is not gate.sh $dir" >&2; exit 1; }
child="$(pgrep -P "$gate" -f lease.sh)"
ticket="$(ls /tmp/openmm-lease-queue | grep -- "-$child\$")" || { echo "no queued ticket for $child: holding or between steps, not restarting" >&2; exit 1; }
[ "$(sed -n 's/^src //p' "$dir/BUILT")" = "$("$T/srchash.sh" "$dir")" ] || { echo "$dir/src changed after build.sh, not restarting" >&2; exit 1; }
us="${ticket%%-*}"
kill -TERM "$gate"
kill -TERM "$child"
n=0; while kill -0 "$child" 2>/dev/null && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
[ ! -e "/tmp/openmm-lease-queue/$ticket" ] || rm -f "/tmp/openmm-lease-queue/$ticket"
LEASE_TICKET_US="$us" nohup "$T/gate.sh" "$dir" > "$log" 2>&1 < /dev/null &
sleep 1
echo "$dir: killed gate $gate and lease.sh $child (ticket $ticket), relaunched as pid $!, log $log, new ticket $(ls /tmp/openmm-lease-queue | grep -- "-$!\$")"
