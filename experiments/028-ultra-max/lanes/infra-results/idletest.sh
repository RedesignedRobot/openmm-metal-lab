#!/bin/sh
# Scratch test of lease.sh's idle warning: private lease, queue and log, the GPU reading from a file,
# 1 s polls and a 3 s threshold. No GPU work.
set -u
GT=/tmp/openmm-metal-bench/ultra-infra/idlet
N=/tmp/openmm-metal-bench/ultra-infra/next
rm -rf "$GT"; mkdir -p "$GT"
sed -e "s|^LEASE=.*|LEASE=$GT/lease|" -e "s|^QUEUE=.*|QUEUE=$GT/queue|" -e "s|^IDLE_LOG=.*|IDLE_LOG=$GT/idle.log|" \
    -e "s|^IDLE_POLL_SECONDS=.*|IDLE_POLL_SECONDS=1|" -e "s|^IDLE_WARN_SECONDS=.*|IDLE_WARN_SECONDS=3|" \
    -e "s|util=\"\$(ioreg .*|util=\"\$(cat $GT/util)\"|" "$N/lease.sh" > "$GT/lease.sh"
grep -c "cat $GT/util" "$GT/lease.sh" | sed 's/^/fake reading lines: /'
chmod +x "$GT/lease.sh"; L="$GT/lease.sh"
echo "== 1: timing hold, idle 4.5 s, busy 2 s, idle 4 s: expect 2 warnings"
"$L" t1 "idle then busy" sh -c "echo 0 > $GT/util; sleep 4.5; echo 50 > $GT/util; sleep 2; echo 0 > $GT/util; sleep 4" 2> "$GT/t1.err"
cat "$GT/t1.err"
echo "== 2: correctness hold idle 5 s: expect none"
"$L" --correctness c1 "correctness" sh -c "echo 0 > $GT/util; sleep 5" 2> "$GT/c1.err"; wc -l < "$GT/c1.err" | sed 's/^ */stderr lines: /'
echo "== 3: nested lease.sh inside a timing hold, idle 4.5 s: expect 1 warning (outer only)"
"$L" outer "outer" sh -c "echo 0 > $GT/util; $L inner inner sleep 4.5" 2> "$GT/t3.err"; cat "$GT/t3.err"
echo "== 4: window hold (OPENMM_WINDOW=1), idle 5 s: expect none"
OPENMM_WINDOW=1 "$L" window "window" sh -c "echo 0 > $GT/util; sleep 5" 2> "$GT/t4.err"; wc -l < "$GT/t4.err" | sed 's/^ */stderr lines: /'
echo "== 5: busy timing hold 5 s: expect none"
"$L" busy "busy" sh -c "echo 90 > $GT/util; sleep 5" 2> "$GT/t5.err"; wc -l < "$GT/t5.err" | sed 's/^ */stderr lines: /'
echo "== idle log"; cat "$GT/idle.log"
sleep 1.5
echo "leftovers: lease $(ls -d "$GT/lease" 2>/dev/null || echo none), queue $(ls "$GT/queue" | wc -l | tr -d ' '), watcher processes $(pgrep -f "$GT/lease.sh" | wc -l | tr -d ' ')"
