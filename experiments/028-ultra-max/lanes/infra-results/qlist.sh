#!/bin/sh
# One line per queue ticket: position, ticket, whether its pid runs lease.sh, the lease.sh args (lane, note),
# and the parent chain's commands, to tell live work from dead tickets.
cd /tmp/openmm-lease-queue || exit 1
n=0
for t in $(ls | sort); do
    n=$((n+1))
    pid="${t##*-}"
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    case "$cmd" in
    *lease.sh*) state=live ;;
    "") state=DEAD ;;
    *) state="DEAD(pid reused)" ;;
    esac
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    pcmd="$( [ -n "$ppid" ] && ps -o command= -p "$ppid" 2>/dev/null | cut -c1-110)"
    gp="$( [ -n "$ppid" ] && ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ')"
    gcmd="$( [ -n "$gp" ] && ps -o command= -p "$gp" 2>/dev/null | cut -c1-110)"
    et="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    echo "$n $t $state age=$et"
    echo "    cmd: $(echo "$cmd" | cut -c1-200)"
    echo "    parent: $pcmd"
    echo "    grandparent: $gcmd"
done
echo "holder: $(cat /tmp/openmm-lease/owner 2>/dev/null) pid $(cat /tmp/openmm-lease/pid 2>/dev/null); members: $(ls /tmp/openmm-lease/members 2>/dev/null | tr '\n' ' ')"
