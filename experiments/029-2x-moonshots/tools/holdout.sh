#!/bin/sh
# Runs on the M3 Ultra at nice 0, head only: the holdout check of a candidate tree against a baseline
# tree, at merges and in w-windows. Lanes never run it or read its per-candidate results.
# The frozen set is /tmp/openmm-metal-bench/holdout (built once by lab tools/holdout/build.py): the four
# FAH corpus units in mixed (tip3p-hmr, tip4pew with virtual sites, gbsa, neq) and DHFR solvated in PME
# boxes of 47k, 170k and 560k atoms in single and mixed. MANIFEST.sha256 pins every file; the run refuses
# a changed set before it queues.
# Each tree is a build.sh dir (<dir>/venv/bin/python). The whole check is one lease.sh timing hold:
# holdout.sh re-execs itself through lease.sh once. holdout.py does the work: per item, one warm
# worker process per configuration (each tree's Metal precisions and OpenCL single), Metal forces against
# Reference, then 3 interleaved rounds, reversed every other round: 30 s per run for the four FAH units,
# 4 s for the PME boxes. <outdir>/summary.txt has, per
# item and precision, each tree's Metal/OpenCL ratio, the candidate/baseline speed ratio with its spread
# and the merge verdict (BLOCK: more than 1% slower with a spread under 1.5%), then the forces table.
# About 26 minutes of GPU for both trees: the 2026-09-29 acceptance run (7.8 min at 4 s everywhere) with
# the FAH runs scaled to 30 s. Its lease cap is twice that plus 10 minutes, over lease.sh's 20 minute
# default. Run inside a gpuq window job, the job's own cap applies: submit it with --est 26m.
#   /tmp/openmm-metal-bench/ultra-tools/bg.sh /tmp/openmm-metal-bench/ultra-lead/ho1.out \
#     /tmp/openmm-metal-bench/ultra-tools/holdout.sh /tmp/openmm-metal-bench/ultra-r1 \
#     /tmp/openmm-metal-bench/ultra-integrated /tmp/openmm-metal-bench/ultra-lead/ho1
# GPUQ_PREFLIGHT=1 (gpuq submit sets it) runs every check, then exits 0 before queuing or writing anything.
# usage: holdout.sh <baseline-tree> <candidate-tree> <outdir>
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
HOLDOUT=/tmp/openmm-metal-bench/holdout
PY=/tmp/openmm-metal-bench/env/bin/python3
ESTIMATE_MINUTES=26
unset PYTHONPATH OPENMM_CPU_THREADS
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ -n "${GPUQ_PREFLIGHT:-}" ] || [ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through bg.sh" >&2; exit 2; }
[ $# = 3 ] || { echo "usage: holdout.sh <baseline-tree> <candidate-tree> <outdir>" >&2; exit 2; }
base="${1%/}"
cand="${2%/}"
case "$3" in
/*) out="${3%/}" ;;
*) echo "the outdir must be an absolute path" >&2; exit 2 ;;
esac
lane="$(echo "$out" | sed -n 's|^/tmp/openmm-metal-bench/\(ultra-[^/]*\)/.*|\1|p')"
[ -n "$lane" ] || { echo "put the outdir under /tmp/openmm-metal-bench/ultra-<lane>/" >&2; exit 2; }

if [ -z "${HOLDOUT_HELD:-}" ]; then
    for dir in "$base" "$cand"; do
        [ -x "$dir/venv/bin/python" ] || { echo "$dir/venv/bin/python is missing: not a build.sh tree" >&2; exit 2; }
        [ -f "$dir/BUILT" ] || { echo "$dir/BUILT is missing: a build.sh is running there, or the last one failed" >&2; exit 2; }
        [ "$(sed -n 's/^src //p' "$dir/BUILT")" = "$("$TOOLS/srchash.sh" "$dir")" ] \
            || { echo "$dir/src changed after build.sh; rebuild first" >&2; exit 2; }
        "$PY" "$TOOLS/check-pin.py" "$dir"
    done
    # Other files may sit in the outdir; an earlier holdout's own outputs may not.
    for own in configs.txt results.jsonl forces.jsonl summary.txt workers; do
        [ ! -e "$out/$own" ] || { echo "$out already holds $own from an earlier holdout; use a new outdir per run" >&2; exit 2; }
    done
    "$PY" "$TOOLS/holdout.py" verify "$HOLDOUT" > /dev/null
    [ -z "${GPUQ_PREFLIGHT:-}" ] || { echo "preflight ok: holdout.sh $out"; exit 0; }
    mkdir -p "$out"
    for dir in "$base" "$cand"; do
        echo "$(basename "$dir") $(tr '\n' ' ' < "$dir/BUILT")" >> "$out/configs.txt"
    done
    cat "$out/configs.txt"
    echo "estimate: about $ESTIMATE_MINUTES min of GPU"
    export HOLDOUT_HELD=1
    exec "$TOOLS/lease.sh" --cap $((2 * ESTIMATE_MINUTES * 60 + 600)) "$lane" "holdout.sh $out, about $ESTIMATE_MINUTES min" "$0" "$@"
fi
"$PY" "$TOOLS/holdout.py" run "$HOLDOUT" "$out" "$base/venv/bin/python" "$cand/venv/bin/python"
echo "done $out"
