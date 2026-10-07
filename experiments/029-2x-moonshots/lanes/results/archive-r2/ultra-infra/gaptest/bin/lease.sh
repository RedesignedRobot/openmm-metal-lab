#!/bin/sh
# Runs on the M3 Ultra: holds the GPU lease /tmp/openmm-metal-bench/ultra-infra/gaptest/lease around one command, first come, first
# served. Each caller puts a ticket in /tmp/openmm-metal-bench/ultra-infra/gaptest/queue, named <microseconds>-<lane>-<pid>, and
# takes the lease when its ticket is the oldest live one and the lease is free. Files in the queue with
# any other name are ignored. A ticket or lease counts as live only while its pid runs lease.sh, since
# a dead pid can be reused. Dead tickets and leases are cleared, and so is a lease taken by hand (no
# pid file) once it is older than the cap plus a minute. The ticket at the head polls every 0.1 s, the
# rest every second. The command runs in its own process group, which is stopped after 20 minutes, or
# when lease.sh gets INT, TERM or HUP. A lease.sh started under another one (ab.sh or gate.sh inside
# your own lease.sh) runs its command at once, inside the outer hold and its cap.
# The lease never waits for builds. A timing hold pauses them instead: at its start build-policy.py
# sends SIGSTOP to every ninja build.sh registered (and to the compile jobs under it), build.sh starts
# no new phase while the hold lasts, and the release sends SIGCONT. A dead holder can't leave builds
# stopped: build-policy.py's guard, and every lease.sh that clears a dead lease, continue them. A timing
# hold that starts while an unregistered build (clang, clang++, ninja or cc1plus not from build.sh)
# still runs says BUILD RUNNING in the owner line. Build gap: when a timing hold ends while builds are
# paused or waiting, the next timing ticket (the window's included) waits until they end, for at most 15
# minutes (build-policy.py gap); builds still running then are paused by that hold. During the gap a
# --correctness ticket whose only live tickets ahead are timing tickets starts or joins a correctness
# hold; nothing passes a window ticket. Correctness holds leave builds alone. --correctness
# marks work whose result doesn't depend on timing (forces, ctest, drift); gate.sh uses it. Never use
# it for a timing or a profile.
# Correctness holds share the GPU: when the ticket at the head is --correctness and the lease is a
# correctness hold with fewer than 6 members that started under 30 minutes ago, it joins that hold. A
# timing ticket waits for an empty lease, and nothing behind it joins, so timings stay exclusive and
# FIFO order holds. The lease is released when its last member ends; /tmp/openmm-metal-bench/ultra-infra/gaptest/lease/members lists them.
# During a correctness burst (/tmp/openmm-metal-bench/ultra-infra/gaptest/burst exists; the lead or infra creates and removes it), any
# queued --correctness ticket joins a correctness hold with room, even behind a timing ticket. The
# 30 minute bound still applies, so a hold stops taking members, drains, and the head (a timing ticket
# or the window) goes next.
# Lead and infra only, never lanes: LEASE_TICKET_US=<16 digits> dates the ticket instead of the clock,
# so a restarted job keeps its original place (and window.sh goes next), and --cap SECONDS replaces the
# 20 minute cap (window.sh's hold).
# Queue classes (RULES.md, GPU scheduling): --merge-path tickets go first, FIFO among themselves,
# then every other ticket, FIFO. A merge-path ticket's time has a leading 0, so it sorts ahead of every
# other ticket in the queue and waiters of any version see it first; it never preempts a running hold.
# In the day slot (07:00-24:00 UTC) correctness is the product and timings are provisional, so a
# --correctness ticket that isn't merge-path forms a third class between the two: its time carries the
# prefix 05, which sorts after merge-path (0 then the time, 01...) and ahead of plain times (1...), FIFO
# within the class. Each waiter renames its own ticket within 10 s of a slot change, keeping its time,
# so at night (00:00-07:00 UTC) every ticket is back to plain FIFO for the confirms and the window.
# The day class never starves timing for long: once the oldest live plain ticket has waited over 30
# minutes, a day-correctness ticket at the head of the queue drops its prefix for good, keeping its time,
# and waits in plain FIFO order. It neither starts a new hold nor joins a running one, so the old ticket
# goes first once the current hold drains. (A correctness burst still joins behind timing; the lead
# decides when it runs.)
# Order is only the sorted ticket names, so waiters of any version see the new order without a restart.
# --merge-path needs --correctness, never --quick, and a command that names ultra-integrated (its gates
# and checks) or gate.sh on a candidate dir listed in ultra-tools/merge-queue.txt (one path per line;
# the lead edits it). Anything else is refused.
# A timing hold carries only timing (RULES.md). When the GPU of an outer timing hold (not nested, not
# the window) reads under 10% for 60 s straight, lease.sh writes one line to the holder's stderr and to
# /tmp/openmm-metal-bench/ultra-infra/gaptest/idle.log, and warns again after the GPU has been busy.
# usage: lease.sh [--correctness [--merge-path]] [--cap SECONDS] <lane> <what> <command...>
#        lease.sh --status
set -eu
export LC_ALL=C
LEASE=/tmp/openmm-metal-bench/ultra-infra/gaptest/lease
QUEUE=/tmp/openmm-metal-bench/ultra-infra/gaptest/queue
CAP_SECONDS=1200
HAND_LEASE_MAX_SECONDS=$((CAP_SECONDS + 60))
MAX_MEMBERS=6
JOIN_MAX_SECONDS=1800
BURST=/tmp/openmm-metal-bench/ultra-infra/gaptest/burst
DAY_START_HOUR=24
DAY_PREFIX=05
STARVE_SECONDS=1800
MERGE_QUEUE=/tmp/openmm-metal-bench/ultra-tools/merge-queue.txt
INTEGRATED=/tmp/openmm-metal-bench/ultra-integrated
TICKET='[0-9]+-[A-Za-z0-9_.-]+-[0-9]+'
IDLE_LOG=/tmp/openmm-metal-bench/ultra-infra/gaptest/idle.log
IDLE_POLL_SECONDS=5
IDLE_WARN_SECONDS=60
IDLE_BELOW_PERCENT=10
POLICY=/tmp/openmm-metal-bench/ultra-infra/gaptest/bin/build-policy.py
GAP=/tmp/openmm-metal-bench/ultra-infra/gaptest/.build-gap.json
GAP_SECONDS=20
TIMING_MARKS=/tmp/openmm-metal-bench/ultra-infra/gaptest/timing

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

policy() {
    /tmp/openmm-metal-bench/env/bin/python3 "$POLICY" "$@"
}

# Build processes running now; one a timing hold paused (state T) doesn't count.
running_builds() {
    ps -axo stat=,ucomm= | awk '$1 !~ /^T/ && $2 ~ /^(clang|clang\+\+|ninja|cc1plus)$/' | wc -l | tr -d ' '
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
                policy recover || true
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
        policy recover || true
        return 0
    fi
    [ -d "$LEASE" ] || return 0
    age=$(( $(date +%s) - $(stat -f %m "$LEASE" 2>/dev/null || date +%s) ))
    [ $age -gt $HAND_LEASE_MAX_SECONDS ] && [ ! -f "$LEASE/pid" ] || return 0
    echo "$(date -u +%H:%M:%SZ) clearing a lease taken by hand $age s ago: $(cat "$LEASE/owner" 2>/dev/null)" >&2
    rm -rf "$LEASE"
}

# A correctness hold takes a correctness job while it has fewer than MAX_MEMBERS members and started
# under JOIN_MAX_SECONDS ago (the primary creates $LEASE/correctness when it takes the lease).
can_join() {
    [ -f "$LEASE/correctness" ] || return 1
    members=0
    for m in "$LEASE/members"/*; do
        [ -e "$m" ] && members=$((members+1))
    done
    [ $members -ge 1 ] && [ $members -lt $MAX_MEMBERS ] || return 1
    started=$(stat -f %m "$LEASE/correctness" 2>/dev/null) || return 1
    [ $(( $(date +%s) - started )) -lt $JOIN_MAX_SECONDS ]
}

# True when the oldest live plain ticket (16-digit time: timing, or correctness at night or deferred)
# has waited over STARVE_SECONDS. Plain tickets sort oldest first after the merge-path and day classes.
plain_starved() {
    limit=$(( $(now_us) - STARVE_SECONDS * 1000000 ))
    for path in "$QUEUE"/*; do
        is_ticket "${path##*/}" || continue
        [ ${#ticket_head} = 16 ] || continue
        [ "$ticket_head" -lt $limit ] || return 1
        [ "$ticket_pid" != $$ ] && is_lease_pid "$ticket_pid" && return 0
    done
    return 1
}

# True during a build gap when every live ticket ahead of this one is a timing ticket (marked in
# TIMING_MARKS; a window ticket isn't), since the gap holds those back.
gap_passable() {
    [ -e "$GAP" ] || return 1
    [ $(( $(date +%s) - $(stat -f %m "$GAP" 2>/dev/null || echo 0) )) -lt $GAP_SECONDS ] || return 1
    for path in "$QUEUE"/*; do
        t="${path##*/}"
        is_ticket "$t" || continue
        [ "$t" = "$ticket" ] && break
        is_lease_pid "$ticket_pid" || continue
        [ -e "$TIMING_MARKS/$ticket_pid" ] || return 1
    done
    [ "$t" = "$ticket" ] && policy gap
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
    if [ "$timing" = 1 ]; then
        policy end $$ || true
    fi
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
        if [ -f "$LEASE/correctness" ]; then
            age=$(( $(date +%s) - $(stat -f %m "$LEASE/correctness") ))
            state="open to new members for $((JOIN_MAX_SECONDS - age)) s"
            [ $age -ge $JOIN_MAX_SECONDS ] && state="closed to new members (over $JOIN_MAX_SECONDS s), draining"
            echo "shared correctness hold, started $age s ago, $state; members:"
        fi
        for m in "$LEASE/members"/*; do
            [ -f "$m" ] && [ -f "$LEASE/correctness" ] && echo "  pid ${m##*/}: $(cat "$m" 2>/dev/null)"
        done
    else
        echo "holder: none"
    fi
    [ -e "$BURST" ] && echo "correctness burst: queued correctness tickets join a correctness hold with room"
    plain_starved && echo "a plain ticket has waited over $STARVE_SECONDS s: day-correctness tickets start or join no hold ahead of it"
    echo "build processes running: $(running_builds); $(policy status 2>&1)"
    echo "queue, oldest first:"
    now=$(now_us)
    ignored=0
    for path in "$QUEUE"/*; do
        [ -e "$path" ] || continue
        ticket="${path##*/}"
        is_ticket "$ticket" || { ignored=$((ignored+1)); continue; }
        head="${ticket%%-*}"
        class=normal
        time="$head"
        case ${#head} in
        17) class=merge-path; time="${head#0}" ;;
        18) class=correctness; time="${head#$DAY_PREFIX}" ;;
        esac
        state="waiting $(( (now - time) / 1000000 )) s"
        is_lease_pid "${ticket##*-}" || state="dead, skipped and removed when it reaches the front"
        echo "  $ticket  $class  $state"
    done
    [ $ignored = 0 ] || echo "ignored: $ignored files in $QUEUE whose names aren't tickets"
    exit 0
fi
timing=1
merge_path=0
cap=$CAP_SECONDS
while :; do
    case "${1:-}" in
    --correctness) timing=0; shift ;;
    --merge-path) merge_path=1; shift ;;
    --cap) cap="${2:-}"; shift 2 ;;
    *) break ;;
    esac
done
case "$cap" in ''|*[!0-9]*|0) echo "--cap takes a number of seconds" >&2; exit 2 ;; esac
[ $# -ge 3 ] || { echo "usage: lease.sh [--correctness [--merge-path]] [--cap SECONDS] <lane> <what> <command...> | lease.sh --status" >&2; exit 2; }
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

# True for a command that names ultra-integrated, or that runs gate.sh on a dir in the merge queue; never --quick.
merge_path_allowed() {
    gate=0
    integrated=0
    queued=0
    for arg in "$@"; do
        arg="${arg%/}"
        case "$arg" in
        --quick) return 1 ;;
        gate.sh|*/gate.sh) gate=1 ;;
        "$INTEGRATED"|"$INTEGRATED"/*) integrated=1 ;;
        esac
        [ -n "$arg" ] && [ -f "$MERGE_QUEUE" ] \
            && sed -e 's/[[:space:]]*$//' -e 's#/*$##' "$MERGE_QUEUE" | grep -qxF -- "$arg" && queued=1
    done
    [ $integrated = 1 ] || { [ $gate = 1 ] && [ $queued = 1 ]; }
}
if [ $merge_path = 1 ]; then
    [ $timing = 0 ] || { echo "lease.sh: --merge-path is for --correctness work only; timings are never merge-path" >&2; exit 2; }
    merge_path_allowed "$@" || { echo "lease.sh: --merge-path is only for full gates and checks on $INTEGRATED, or the full gate (gate.sh, no --quick) of a candidate dir listed in $MERGE_QUEUE" >&2; exit 2; }
fi

case "${LEASE_TICKET_US:-}" in
'') ticket_us="$(now_us)" ;;
*[!0-9]*) echo "LEASE_TICKET_US must be 16 digits" >&2; exit 2 ;;
*) ticket_us="$LEASE_TICKET_US" ;;
esac
[ ${#ticket_us} -eq 16 ] || { echo "LEASE_TICKET_US must be 16 digits" >&2; exit 2; }
unset LEASE_TICKET_US
mkdir -p "$QUEUE"
# The name a ticket should carry now: the day prefix on a plain --correctness ticket by day, unless it
# deferred to a starved plain ticket.
deferred=0
starved=0
slot_ticket() {
    if [ $timing = 0 ] && [ $merge_path = 0 ] && [ $deferred = 0 ] && [ "$(date -u +%H)" -ge $DAY_START_HOUR ]; then
        echo "$DAY_PREFIX$ticket_us-$lane-$$"
    else
        echo "$ticket_us-$lane-$$"
    fi
}
ticket="$(slot_ticket)"
[ $merge_path = 0 ] || ticket="0$ticket"
touch "$QUEUE/$ticket"
trap 'rm -f "$QUEUE/$ticket" "$TIMING_MARKS/$$"' EXIT
if [ $timing = 1 ] && [ -z "${OPENMM_WINDOW:-}" ]; then
    mkdir -p "$TIMING_MARKS"
    touch "$TIMING_MARKS/$$"
fi
trap 'exit 1' INT TERM HUP
build_note=""
in_gap=0
# Tenths of a second.
waited=0
next_report=0
next_slot_check=100
while :; do
    if [ $timing = 0 ] && [ $merge_path = 0 ] && [ $waited -ge $next_slot_check ]; then
        want="$(slot_ticket)"
        if [ "$want" != "$ticket" ]; then
            mv -f "$QUEUE/$ticket" "$QUEUE/$want" 2>/dev/null || true
            ticket="$want"
        fi
        next_slot_check=$((waited + 100))
    fi
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
        if [ "$ticket" != "$ticket_us-$lane-$$" ] && [ $merge_path = 0 ]; then
            if [ $((waited % 10)) -eq 0 ]; then
                if plain_starved; then starved=1; else starved=0; fi
            fi
            if [ $starved = 1 ]; then
                deferred=1
                mv -f "$QUEUE/$ticket" "$QUEUE/$ticket_us-$lane-$$" 2>/dev/null || true
                ticket="$ticket_us-$lane-$$"
                echo "$(date -u +%H:%M:%SZ) lease.sh: a plain ticket has waited over $STARVE_SECONDS s; this correctness ticket starts or joins no hold ahead of it and waits in plain FIFO order" >&2
                continue
            fi
        fi
        # A timing ticket checks for a build gap after taking the lease dir, so a gap that the last
        # holder opened as it released can't be missed.
        if mkdir "$LEASE" 2>/dev/null; then
            if [ $timing = 1 ] && [ -e "$GAP" ] && policy gap; then
                rmdir "$LEASE"
                [ $in_gap = 1 ] || echo "$(date -u +%H:%M:%SZ) lease.sh: build gap, waiting up to $GAP_SECONDS s for the builds the last timing hold paused or held back" >&2
                in_gap=1
            else
                role=primary
                break
            fi
        else
            in_gap=0
        fi
        if [ $timing = 0 ] && can_join && { owner_line > "$LEASE/members/$$"; } 2>/dev/null; then
            role=member
            break
        fi
        [ $((waited % 10)) -eq 0 ] && clear_dead_lease
        step=1
        pause=0.1
        if [ $in_gap = 1 ]; then
            step=10
            pause=1
        fi
    else
        if [ $timing = 0 ] && [ -e "$BURST" ] && can_join && { owner_line > "$LEASE/members/$$"; } 2>/dev/null; then
            role=member
            break
        fi
        if [ $timing = 0 ] && gap_passable; then
            if can_join && { owner_line > "$LEASE/members/$$"; } 2>/dev/null; then
                role=member
                break
            fi
            if mkdir "$LEASE" 2>/dev/null; then
                role=primary
                break
            fi
        fi
        step=10
        pause=1
    fi
    if [ $waited -ge $next_report ]; then
        echo "$(date -u +%H:%M:%SZ) waiting for the lease: $(ls "$QUEUE" | grep -xE "$TICKET" | grep -n -x "$ticket" | cut -d: -f1) in the queue," \
            "held by: $(cat "$LEASE/owner" 2>/dev/null || echo nobody), $(running_builds) build processes running" >&2
        next_report=$((next_report + 3000))
    fi
    sleep $pause
    waited=$((waited + step))
done
if [ $role = primary ]; then
    mkdir "$LEASE/members"
    owner_line > "$LEASE/members/$$"
    owner_line > "$LEASE/owner"
    echo $$ > "$LEASE/pid"
    [ $timing = 1 ] || touch "$LEASE/correctness"
fi
rm -f "$QUEUE/$ticket" "$TIMING_MARKS/$$"
watcher=""
trap leave EXIT
if [ "$timing" = 1 ]; then
    policy begin $$
    if [ "$(running_builds)" != 0 ]; then
        build_note=" BUILD RUNNING"
        owner_line > "$LEASE/members/$$"
        owner_line > "$LEASE/owner"
    fi
fi
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
