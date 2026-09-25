#!/bin/sh
# Runs on the M3 Ultra: holds the GPU lease /tmp/openmm-lease around one command, first come, first
# served. Each caller puts a ticket in /tmp/openmm-lease-queue, named <microseconds>-<lane>-<pid>, and
# takes the lease when its ticket is the oldest live one and the lease is free. Files in the queue with
# any other name are ignored. A ticket or lease counts as live only while its pid runs lease.sh, since
# a dead pid can be reused. Dead tickets and leases are cleared, and so is a lease taken by hand (no
# pid file) once it is older than the cap plus a minute. The ticket at the head polls every 0.1 s, the
# rest every second. The command runs in its own process group, which is stopped after 20 minutes, or
# when lease.sh gets INT, TERM or HUP. A lease.sh started under another one (ab.sh or gate.sh inside
# your own lease.sh) runs its command at once, inside the outer hold and its cap.
# The lease never waits for builds. A timing hold that starts while a build (clang, clang++, ninja or
# cc1plus) runs says BUILD RUNNING in the owner line. --correctness marks work whose result doesn't
# depend on timing (forces, ctest, drift); gate.sh uses it. Never use it for a timing or a profile.
# Correctness holds share the GPU: when the ticket at the head is --correctness and the lease is a
# correctness hold with fewer than 6 members, it joins that hold. A timing ticket waits for an empty
# lease, and nothing behind it joins, so timings stay exclusive and FIFO order holds. The lease is
# released when its last member ends; /tmp/openmm-lease/members lists them.
# During a correctness burst (/tmp/openmm-burst exists; the lead or infra creates and removes it), any
# queued --correctness ticket joins a correctness hold with room, even behind a timing ticket. Timing
# tickets then wait until the burst file is gone and the hold empties.
# Lead and infra only, never lanes: LEASE_TICKET_US=<16 digits> dates the ticket instead of the clock,
# so a restarted job keeps its original place (and window.sh goes next), and --cap SECONDS replaces the
# 20 minute cap (window.sh's hold).
# A timing hold carries only timing (RULES.md). When the GPU of an outer timing hold (not nested, not
# the window) reads under 10% for 60 s straight, lease.sh writes one line to the holder's stderr and to
# /tmp/openmm-lease-idle.log, and warns again after the GPU has been busy.
# usage: lease.sh [--correctness] [--cap SECONDS] <lane> <what> <command...>
#        lease.sh --status
set -eu
export LC_ALL=C
LEASE=/tmp/openmm-lease
QUEUE=/tmp/openmm-lease-queue
CAP_SECONDS=1200
HAND_LEASE_MAX_SECONDS=$((CAP_SECONDS + 60))
MAX_MEMBERS=6
BURST=/tmp/openmm-burst
BUILDS='clang|clang\+\+|ninja|cc1plus'
TICKET='[0-9]+-[A-Za-z0-9_.-]+-[0-9]+'
IDLE_LOG=/tmp/openmm-lease-idle.log
IDLE_POLL_SECONDS=5
IDLE_WARN_SECONDS=60
IDLE_BELOW_PERCENT=10

now_us() {
    perl -MTime::HiRes=gettimeofday -e '($s, $us) = gettimeofday; printf "%d%06d\n", $s, $us'
}

# A ticket name matches TICKET. Plain sh with no forks, since the head runs it every 0.1 s.
is_ticket() {
    case "$1" in
    *[!A-Za-z0-9_.-]*) return 1 ;;
    *-*-*) ;;
    *) return 1 ;;
    esac
    ticket_head="${1%%-*}"
    ticket_pid="${1##*-}"
    ticket_lane="${1#*-}"
    ticket_lane="${ticket_lane%-*}"
    case "$ticket_head$ticket_pid" in
    *[!0-9]*) return 1 ;;
    esac
    [ -n "$ticket_head" ] && [ -n "$ticket_pid" ] && [ -n "$ticket_lane" ]
}

is_lease_pid() {
    kill -0 "$1" 2>/dev/null || return 1
    case "$(ps -o command= -p "$1" 2>/dev/null)" in
    *lease.sh*) return 0 ;;
    esac
    return 1
}

# Points the pid and owner files at a live member, for waiters that only read those.
hand_over() {
    for m in "$LEASE/members"/*; do
        [ -f "$m" ] && is_lease_pid "${m##*/}" || continue
        cp "$m" "$LEASE/.owner" && mv -f "$LEASE/.owner" "$LEASE/owner"
        echo "${m##*/}" > "$LEASE/.pid" && mv -f "$LEASE/.pid" "$LEASE/pid"
        return 0
    done
    return 1
}

# Removes dead members, and clears the lease if none is left. Clears an older lease (no members dir)
# if its holder is dead, or if it was taken by hand (no pid file) longer ago than
# HAND_LEASE_MAX_SECONDS.
clear_dead_lease() {
    if [ -d "$LEASE/members" ]; then
        live=0
        for m in "$LEASE/members"/*; do
            [ -f "$m" ] || continue
            if is_lease_pid "${m##*/}"; then
                live=$((live+1))
            else
                echo "$(date -u +%H:%M:%SZ) removing dead member ${m##*/}: $(cat "$m" 2>/dev/null)" >&2
                rm -f "$m"
            fi
        done
        if [ $live = 0 ]; then
            rmdir "$LEASE/members" 2>/dev/null && rm -rf "$LEASE"
        elif ! is_lease_pid "$(cat "$LEASE/pid" 2>/dev/null || echo 0)"; then
            hand_over || true
        fi
        return 0
    fi
    holder="$(cat "$LEASE/pid" 2>/dev/null || true)"
    if [ -n "$holder" ]; then
        is_lease_pid "$holder" && return 0
        [ "$(cat "$LEASE/pid" 2>/dev/null)" = "$holder" ] || return 0
        echo "$(date -u +%H:%M:%SZ) clearing the lease of dead pid $holder: $(cat "$LEASE/owner" 2>/dev/null)" >&2
        rm -rf "$LEASE"
        return 0
    fi
    [ -d "$LEASE" ] || return 0
    age=$(( $(date +%s) - $(stat -f %m "$LEASE" 2>/dev/null || date +%s) ))
    [ $age -gt $HAND_LEASE_MAX_SECONDS ] && [ ! -f "$LEASE/pid" ] || return 0
    echo "$(date -u +%H:%M:%SZ) clearing a lease taken by hand $age s ago: $(cat "$LEASE/owner" 2>/dev/null)" >&2
    rm -rf "$LEASE"
}

# A correctness hold takes the head's correctness job while it has fewer than MAX_MEMBERS members.
can_join() {
    [ -f "$LEASE/correctness" ] || return 1
    members=0
    for m in "$LEASE/members"/*; do
        [ -e "$m" ] && members=$((members+1))
    done
    [ $members -ge 1 ] && [ $members -lt $MAX_MEMBERS ]
}

# Warns once per stretch of IDLE_WARN_SECONDS with the GPU under IDLE_BELOW_PERCENT, the same
# ioreg reading as the lead's sampler.
watch_idle() {
    idle=0
    while sleep $IDLE_POLL_SECONDS; do
        util="$(ioreg -r -d 1 -w 0 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2)"
        if [ "${util:-100}" -ge $IDLE_BELOW_PERCENT ]; then
            idle=0
            continue
        fi
        idle=$((idle + IDLE_POLL_SECONDS))
        [ $idle -eq $IDLE_WARN_SECONDS ] || continue
        line="$(date -u +%H:%M:%SZ) lease.sh: GPU under $IDLE_BELOW_PERCENT% for $IDLE_WARN_SECONDS s in the timing hold of $lane ($what). A timing hold carries only timing: run ctest, drift, checks and gate.sh through their own --correctness tickets."
        echo "$line" >&2
        echo "$line" >> "$IDLE_LOG"
    done
}

# The last member out removes the lease.
leave() {
    [ -z "$watcher" ] || kill "$watcher" 2>/dev/null || true
    rm -f "$LEASE/members/$$"
    if rmdir "$LEASE/members" 2>/dev/null; then
        rm -rf "$LEASE"
    elif [ "$(cat "$LEASE/pid" 2>/dev/null)" = $$ ]; then
        hand_over || true
    fi
}

if [ "${1:-}" = --status ]; then
    if [ -d "$LEASE" ]; then
        echo "holder: $(cat "$LEASE/owner" 2>/dev/null), pid $(cat "$LEASE/pid" 2>/dev/null || echo "none (taken by hand)"), held $(( $(date +%s) - $(stat -f %m "$LEASE") )) s"
        [ -f "$LEASE/correctness" ] && echo "shared correctness hold, members:"
        for m in "$LEASE/members"/*; do
            [ -f "$m" ] && [ -f "$LEASE/correctness" ] && echo "  pid ${m##*/}: $(cat "$m" 2>/dev/null)"
        done
    else
        echo "holder: none"
    fi
    [ -e "$BURST" ] && echo "correctness burst: queued correctness tickets join a correctness hold with room"
    echo "build processes: $(pgrep -x "$BUILDS" | wc -l | tr -d ' ')"
    echo "queue, oldest first:"
    now=$(now_us)
    ignored=0
    for path in "$QUEUE"/*; do
        [ -e "$path" ] || continue
        ticket="${path##*/}"
        is_ticket "$ticket" || { ignored=$((ignored+1)); continue; }
        state="waiting $(( (now - ${ticket%%-*}) / 1000000 )) s"
        is_lease_pid "${ticket##*-}" || state="dead, skipped and removed when it reaches the front"
        echo "  $ticket  $state"
    done
    [ $ignored = 0 ] || echo "ignored: $ignored files in $QUEUE whose names aren't tickets"
    exit 0
fi
timing=1
cap=$CAP_SECONDS
while :; do
    case "${1:-}" in
    --correctness) timing=0; shift ;;
    --cap) cap="${2:-}"; shift 2 ;;
    *) break ;;
    esac
done
case "$cap" in ''|*[!0-9]*|0) echo "--cap takes a number of seconds" >&2; exit 2 ;; esac
[ $# -ge 3 ] || { echo "usage: lease.sh [--correctness] [--cap SECONDS] <lane> <what> <command...> | lease.sh --status" >&2; exit 2; }
lane="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' _)"
[ -n "$lane" ] || { echo "the lane is empty" >&2; exit 2; }
what="$2"
shift 2
if [ -n "${OPENMM_LEASE_PID:-}" ] && { [ "$(cat "$LEASE/pid" 2>/dev/null)" = "$OPENMM_LEASE_PID" ] || [ -f "$LEASE/members/$OPENMM_LEASE_PID" ]; }; then
    exec "$@"
fi
owner_line() {
    echo "$lane $(date -u +%Y-%m-%dT%H:%M:%SZ) $what$build_note"
}

case "${LEASE_TICKET_US:-}" in
'') ticket_us="$(now_us)" ;;
*[!0-9]*) echo "LEASE_TICKET_US must be 16 digits" >&2; exit 2 ;;
*) ticket_us="$LEASE_TICKET_US" ;;
esac
[ ${#ticket_us} -eq 16 ] || { echo "LEASE_TICKET_US must be 16 digits" >&2; exit 2; }
unset LEASE_TICKET_US
mkdir -p "$QUEUE"
ticket="$ticket_us-$lane-$$"
touch "$QUEUE/$ticket"
trap 'rm -f "$QUEUE/$ticket"' EXIT
trap 'exit 1' INT TERM HUP
build_note=""
# Tenths of a second.
waited=0
next_report=0
while :; do
    [ -e "$QUEUE/$ticket" ] || touch "$QUEUE/$ticket"
    first=""
    for path in "$QUEUE"/*; do
        t="${path##*/}"
        is_ticket "$t" || continue
        if [ "$t" = "$ticket" ] || is_lease_pid "${t##*-}"; then
            first="$t"
            break
        fi
        rm -f "$path"
    done
    if [ "$first" = "$ticket" ]; then
        mkdir "$LEASE" 2>/dev/null && { role=primary; break; }
        if [ $timing = 0 ] && can_join && { owner_line > "$LEASE/members/$$"; } 2>/dev/null; then
            role=member
            break
        fi
        [ $((waited % 10)) -eq 0 ] && clear_dead_lease
        step=1
        pause=0.1
    else
        if [ $timing = 0 ] && [ -e "$BURST" ] && can_join && { owner_line > "$LEASE/members/$$"; } 2>/dev/null; then
            role=member
            break
        fi
        step=10
        pause=1
    fi
    if [ $waited -ge $next_report ]; then
        echo "$(date -u +%H:%M:%SZ) waiting for the lease: $(ls "$QUEUE" | grep -xE "$TICKET" | grep -n -x "$ticket" | cut -d: -f1) in the queue," \
            "held by: $(cat "$LEASE/owner" 2>/dev/null || echo nobody), $(pgrep -x "$BUILDS" | wc -l | tr -d ' ') build processes" >&2
        next_report=$((next_report + 3000))
    fi
    sleep $pause
    waited=$((waited + step))
done
if [ $role = primary ]; then
    [ $timing = 1 ] && pgrep -x "$BUILDS" > /dev/null && build_note=" BUILD RUNNING"
    mkdir "$LEASE/members"
    owner_line > "$LEASE/members/$$"
    owner_line > "$LEASE/owner"
    echo $$ > "$LEASE/pid"
    [ $timing = 1 ] || touch "$LEASE/correctness"
fi
rm -f "$QUEUE/$ticket"
watcher=""
trap leave EXIT
if [ $timing = 1 ] && [ -z "${OPENMM_WINDOW:-}" ]; then
    watch_idle &
    watcher=$!
fi
export OPENMM_LEASE_PID=$$
# perl runs the command in its own process group, so the cap and a signal stop all of it, python included.
perl -e '
    my $cap = shift;
    my $pid = fork() // die "fork: $!\n";
    if ($pid == 0) {
        setpgrp(0, 0);
        exec { $ARGV[0] } @ARGV or die "cannot run $ARGV[0]: $!\n";
    }
    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { kill "TERM", -$pid };
    $SIG{ALRM} = sub {
        print STDERR "lease.sh: the $cap s cap ran out, stopping the command\n";
        kill "TERM", -$pid;
        sleep 10;
        kill "KILL", -$pid;
    };
    alarm $cap;
    waitpid($pid, 0);
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
' "$cap" "$@" &
runner=$!
trap 'kill -TERM $runner 2>/dev/null' INT TERM HUP
set +e
wait $runner
code=$?
while kill -0 $runner 2>/dev/null; do
    wait $runner
    code=$?
done
exit $code
