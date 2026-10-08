#!/bin/sh
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
OUT=/tmp/openmm-metal-bench/ultra-r3-gbown/phase-a
export SHADER_HELD=1
case "$(date -u +%H)" in 00|01|02|03|04|05|06) echo 'night slot: profile refused'; exit 2;; esac
"$TOOLS/shader.sh" "$OUT" base gbsa /tmp/openmm-metal-bench/ultra-r2-accum-gb-s 2
"$TOOLS/shader.sh" "$OUT" row gbsa /tmp/openmm-metal-bench/ultra-r3-gbown 2
for tag in base row; do
    /tmp/openmm-metal-bench/env/bin/python /tmp/openmm-metal-bench/ultra-r3-gbown/tools/bornphase.py \
        "$OUT/$tag-intervals.xml" "$(cat "$OUT/$tag.pypid")" > "$OUT/$tag-chain.txt"
done

# Only spend the second precision capture when single clears its kill.
if /tmp/openmm-metal-bench/env/bin/python - "$OUT" <<'CHECK'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
def phase(tag):
    return float(re.search(r"whole Born phase: median ([0-9.]+)", (root/(tag+"-chain.txt")).read_text())[1])
delta = phase("base")-phase("row")
print("single whole Born saving:", delta, "us")
sys.exit(0 if delta >= 4 else 1)
CHECK
then
    PRECISION=mixed "$TOOLS/shader.sh" "$OUT" basem gbsa /tmp/openmm-metal-bench/ultra-r2-accum-gb-s 2
    PRECISION=mixed "$TOOLS/shader.sh" "$OUT" rowm gbsa /tmp/openmm-metal-bench/ultra-r3-gbown 2
    for tag in basem rowm; do
        /tmp/openmm-metal-bench/env/bin/python /tmp/openmm-metal-bench/ultra-r3-gbown/tools/bornphase.py \
            "$OUT/$tag-intervals.xml" "$(cat "$OUT/$tag.pypid")" > "$OUT/$tag-chain.txt"
    done
fi
