#!/bin/sh
# Runs harness/scaling.py once per box, in the order team-lead gave, so one failing size cannot stop the rest.
set -u
py=/tmp/openmm-metal-bench/env/bin/python
out=/tmp/openmm-metal-bench/scaling-m3ultra-20260923T1016Z
jsonl=$out/scaling-m3ultra-20260923T1016Z.jsonl
snap() { { echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) $1"; uptime; pmset -g therm; top -l 2 -o cpu -n 6 -stats command,cpu | tail -6; } >> $out/host.txt 2>&1; }
{ echo "nice $(ps -o nice= -p $$ | tr -d " ")"; echo "commit $(cat /tmp/openmm-metal-bench/COMMIT)"; shasum -a 256 /tmp/openmm-metal-bench/harness/scaling.py; "$py" -c "import openmm as m; print(\"openmm\", m.__version__, [m.Platform.getPlatform(i).getName() for i in range(m.Platform.getNumPlatforms())])"; } > $out/host.txt 2>&1
for job in "Metal single 3 5 8 12 16 20" "Metal mixed 3 5 8 12 16 20" "OpenCL single 8 16"; do
    set -- $job; platform=$1 precision=$2; shift 2
    snap "$platform $precision"
    for nm in "$@"; do
        echo "=== $(date -u +%H:%M:%SZ) $platform $precision $nm nm" >> $out/scaling.err
        "$py" /tmp/openmm-metal-bench/harness/scaling.py $platform $precision $nm >> $jsonl 2>> $out/scaling.err || echo "FAILED $platform $precision $nm exit $?" >> $out/scaling.err
    done
done
snap end
echo done > $out/DONE
