#!/bin/sh
# One round of wl-run.sh, under its lease: each workloads.py argument set in a fresh process, in reverse
# order on even rounds. WL_OUT and WL_ROUND come from wl-run.sh.
# usage: wl-round.sh "<workloads.py args>"...
PY=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
WL=/tmp/openmm-metal-bench/ultra-workloads/workloads.py
n=$#
i=0
while [ "$i" -lt "$n" ]; do
    if [ $((WL_ROUND % 2)) -eq 0 ]; then eval "a=\${$((n-i))}"; else eval "a=\${$((i+1))}"; fi
    i=$((i+1))
    echo "$(date -u +%H:%M:%SZ) round $WL_ROUND load $(sysctl -n vm.loadavg) vm $(ps -Ao pcpu=,comm= | awk '/Virtualization\.VirtualMachine/ { c += $1 } END { printf "%.0f%%", c }') run $a" >> "$WL_OUT.top"
    # shellcheck disable=SC2086
    if res=$(perl -e 'alarm shift; exec @ARGV' 900 "$PY" "$WL" $a 2>> "$WL_OUT.err"); then
        echo "$res" | sed "s/^{/{\"round\": $WL_ROUND, /" >> "$WL_OUT"
    else
        echo "FAILED round $WL_ROUND $a" >> "$WL_OUT.top"
    fi
done
