#!/bin/sh
# Lead-owned sampler: every 5 s until gpu-util.stop exists, logs GPU utilization, the lease holder, live queue length
# and build processes to /tmp/openmm-metal-bench/ultra-lead/gpu-util.log. Read-only; touches nothing else.
out=/tmp/openmm-metal-bench/ultra-lead/gpu-util.log
while [ ! -e /tmp/openmm-metal-bench/ultra-lead/gpu-util.stop ]; do
    u=$(ioreg -r -d 1 -w 0 -c IOAccelerator | grep -o "\"Device Utilization %\"=[0-9]*" | head -1 | cut -d= -f2)
    h=$(cut -d" " -f1 /tmp/openmm-lease/owner 2>/dev/null)
    q=0
    for t in /tmp/openmm-lease-queue/*; do
        [ -e "$t" ] || continue
        kill -0 "${t##*-}" 2>/dev/null && q=$((q+1))
    done
    b=$(pgrep -x "clang|clang\+\+|ninja|cc1plus" | wc -l | tr -d " ")
    echo "$(date -u +%H:%M:%S) gpu=${u:-?} holder=${h:-none} queue=$q builds=$b" >> "$out"
    sleep 5
done
