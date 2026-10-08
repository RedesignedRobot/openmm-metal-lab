#!/bin/sh
# Waits until ultra-integrated's BUILT names 89d7f17fc (b69efb0fe plus f1) and a gate run on that build
# passed, then queues the agg rerun as four lease.sh tickets, one per test, so every test measures that
# build. Ticket pids go to agg2-tickets.pid.
W=/tmp/openmm-metal-bench/ultra-workloads
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
I=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python
T=/tmp/openmm-metal-bench/ultra-integrated
# The gate passed when a gate*.out in the tree, newer than BUILT, ends in PASS (gate.sh's last line).
passed() {
    grep -q '^commit 89d7f17fc' "$T/BUILT" 2>/dev/null || return 1
    for f in $(find "$T" -maxdepth 1 -name 'gate*.out' -newer "$T/BUILT"); do
        [ "$(tail -1 "$f")" = PASS ] && { gate=$f; return 0; }
    done
    return 1
}
until passed; do
    sleep 60
done
echo "$(date -u +%H:%M:%SZ) ultra-integrated BUILT: $(tr '\n' ' ' < "$T/BUILT")"
echo "$(date -u +%H:%M:%SZ) gate PASS: $gate"
for test in gbsa rf pme amber20-dhfr; do
    nohup /tmp/openmm-metal-bench/ultra-tools/lease.sh ultra-workloads "agg2 $test base vs integrated, about 9 min" \
        "$B" "$W/agg2.py" "$W/agg2-$test" 2 10 "$test" \
        "base-s=$B:Metal:single" "int-s=$I:Metal:single" "base-m=$B:Metal:mixed" "int-m=$I:Metal:mixed" \
        > "$W/agg2-$test.out" 2>&1 < /dev/null &
    echo "$test $!" >> "$W/agg2-tickets.pid"
    sleep 1
done
echo "$(date -u +%H:%M:%SZ) queued: $(tr '\n' ' ' < "$W/agg2-tickets.pid")"
