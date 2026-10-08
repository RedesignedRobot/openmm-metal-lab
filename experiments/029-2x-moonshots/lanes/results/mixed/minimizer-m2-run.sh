#!/bin/sh
set -eu
unset PYTHONPATH OPENMM_PLUGIN_DIR
echo "M2 minimizer timing pid=$$"
ROOT=$HOME/lab/ultra-m2.noindex
D=$ROOT/m29-mixed-minimizer-evidence
M=$ROOT/cand-m29-mixed-minimizer-source-b60e2c40f9
B=$ROOT/base
BENCH=$B/benchmarks
mkdir -p "$D/results"
for tree in "$B" "$M"; do
    test -f "$tree/BUILT"
    /opt/homebrew/bin/python3 "$ROOT/tools/m2-verify.py" "$tree"
done
for round in 1 2; do
    if [ "$round" = 1 ]; then arms='base-single base-mixed mine-single mine-mixed cpu'; else arms='cpu mine-mixed mine-single base-mixed base-single'; fi
    for arm in $arms; do
        tree="$B"; platform=Metal; precision=single
        case "$arm" in
            base-mixed) precision=mixed ;;
            mine-single) tree="$M" ;;
            mine-mixed) tree="$M"; precision=mixed ;;
            cpu) platform=CPU; precision=mixed ;;
        esac
        cp "$tree/BUILT" "$D/results/$arm-r$round.BUILT"
        date -u > "$D/results/$arm-r$round.load-before.txt"
        sysctl -n vm.loadavg >> "$D/results/$arm-r$round.load-before.txt"
        /usr/bin/time -l "$tree/venv/bin/python" "$D/minimize.py" "$BENCH" "$platform" "$precision" > "$D/results/$arm-r$round.json" 2> "$D/results/$arm-r$round.footprint.txt"
    done
done
echo M2_MINIMIZER_DONE > "$D/verdict.txt"
