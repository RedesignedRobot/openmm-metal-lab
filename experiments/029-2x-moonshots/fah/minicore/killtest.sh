#!/bin/sh
# killtest.sh <bundle> <wu dir> <out dir> <steps> <checkpoint steps> [minicore flags...]
# Runs one work unit twice from the same state with DeterministicForces: once straight through, once
# killed with SIGKILL at random times and restarted until it finishes, like a donor Mac that loses
# power. Then it kills one process inside its checkpoint write (MINICORE_CRASH_IN_WRITE) and truncates
# the saved checkpoint, and checks that both restarts recover. Every run uses an empty environment and
# the core's priority (nice 19, darwin background), with the bundle's own plugins.
# Prints PASS or FAIL per check. The final positions and velocities are compared bit for bit; units
# with a neighbor list can differ after a restart (GAPS.md gap 3), so their compare is reported, not
# required.
set -u
bundle=$1
wu=$2
out=$3
steps=$4
chunk=$5
shift 5
flags="--wu $wu --steps $steps --checkpoint-steps $chunk --seed 2029 --deterministic $*"
core() {
    env -i PATH=/usr/bin:/bin MINICORE_CRASH_IN_WRITE=${MINICORE_CRASH_IN_WRITE:-} nice -n 19 /usr/sbin/taskpolicy -b "$bundle/minicore" "$@"
}

# These scripts never delete anything, so the out dir must be new.
[ -e "$out" ] && { echo "$out exists; pick a new out dir"; exit 2; }
mkdir -p "$out/killed"

start=$(date +%s)
core $flags --out "$out/straight" > "$out/straight.log" 2>&1
echo "straight: exit $?"
straight_s=$(( $(date +%s) - start ))
echo "straight: $straight_s s"

# Each start is killed at a random point inside a chunk after its first new checkpoint, so every
# start makes progress and kills land in stepping and in checkpoint writes alike. After ten kills the
# unit runs to the end. The launch execs through env, nice and taskpolicy so no wrapper shell sits
# between the script and the core, and the kill targets the pid minicore records. A backgrounded
# function call without exec left one orphaned core per restart (22:59Z, 2026-09-27). Only one core
# runs at a time, and the EXIT trap kills the recorded one if the script stops early.
chunk_s=$(awk -v w=$straight_s -v n=$(( steps / chunk )) 'BEGIN { printf "%.2f", w / n }')
kills=0
restarts=0
touch "$out/killed.log"
trap 'pid=$(cat "$out/killed/minicore.pid" 2>/dev/null); [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null' EXIT
while ! grep -q '^done ' "$out/killed.log"; do
    [ $restarts -ge 30 ] && break
    restarts=$((restarts + 1))
    : > "$out/killed/minicore.pid"
    before=$(grep -c '^step ' "$out/killed.log")
    ( exec env -i PATH=/usr/bin:/bin nice -n 19 /usr/sbin/taskpolicy -b "$bundle/minicore" $flags \
        --out "$out/killed" >> "$out/killed.log" 2>&1 ) &
    shell=$!
    if [ $kills -lt 10 ]; then
        while [ "$(grep -c '^step ' "$out/killed.log")" -le "$before" ] && kill -0 $shell 2>/dev/null; do
            sleep 0.1
        done
        sleep "$(awk -v c=$chunk_s -v r=$RANDOM 'BEGIN { printf "%.2f", c * (r % 100) / 100 }')"
        pid=$(cat "$out/killed/minicore.pid" 2>/dev/null)
        if [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; then
            kills=$((kills + 1))
        fi
    fi
    wait $shell 2>/dev/null
    : > "$out/killed/minicore.pid"
done
trap - EXIT
echo "killed: $kills kills, $restarts starts"
grep -q '^done ' "$out/killed.log" && echo "PASS finished after kills" || echo "FAIL never finished"
grep -q 'failed its length or hash check' "$out/killed.log" && echo "note: a kill left a bad checkpoint"
if cmp -s "$out/straight/final.bin" "$out/killed/final.bin"; then
    echo "PASS killed run is bitwise equal to the straight run"
else
    echo "DIFF killed run differs from the straight run"
fi
grep '^global protocol_work' "$out/straight.log" "$out/killed.log" | tail -2

export MINICORE_CRASH_IN_WRITE=1
core $flags --out "$out/midwrite" > "$out/midwrite.log" 2>&1
echo "mid-write crash: exit $?"
unset MINICORE_CRASH_IN_WRITE
core $flags --out "$out/midwrite" >> "$out/midwrite.log" 2>&1
grep -q '^done ' "$out/midwrite.log" && echo "PASS recovered from a crash mid-write" || echo "FAIL after mid-write crash"
cmp -s "$out/straight/final.bin" "$out/midwrite/final.bin" && echo "PASS mid-write run is bitwise equal to the straight run" \
    || echo "DIFF mid-write run differs from the straight run"

cp "$out/straight/checkpoint.bin" "$out/truncated.bin"
mkdir -p "$out/truncated"
head -c $(( $(stat -f %z "$out/truncated.bin") / 2 )) "$out/truncated.bin" > "$out/truncated/checkpoint.bin"
core $flags --out "$out/truncated" > "$out/truncated.log" 2>&1
grep -q 'failed its length or hash check' "$out/truncated.log" && grep -q '^done ' "$out/truncated.log" \
    && echo "PASS truncated checkpoint refused and the unit rerun" || echo "FAIL truncated checkpoint"
