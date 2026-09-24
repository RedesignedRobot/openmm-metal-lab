#!/bin/sh
# Every 20 s while the workloads lane holds the lease: load, owner, the Hyperscale VM's CPU and the top 6
# processes, to psamples.txt. Stops when /tmp/openmm-metal-bench/ultra-workloads/sampler.stop exists.
D=/tmp/openmm-metal-bench/ultra-workloads
until [ -e "$D/sampler.stop" ]; do
    if grep -q '^ultra-workloads' /tmp/openmm-lease/owner 2>/dev/null; then
        { echo "== $(date -u +%H:%M:%SZ) load $(sysctl -n vm.loadavg) vm $(ps -Ao pcpu=,comm= | awk '/Virtualization\.VirtualMachine/ { c += $1 } END { printf "%.0f%%", c }') lease: $(cut -c1-140 /tmp/openmm-lease/owner 2>/dev/null)"
          ps -axo pcpu,nice,command -r | head -7 | tail -6 | cut -c1-150
          pgrep -lx 'clang|clang\+\+|ninja|cc1plus' 2>/dev/null | sed 's/^/BUILD /'; } >> "$D/psamples.txt"
    fi
    sleep 20
done
