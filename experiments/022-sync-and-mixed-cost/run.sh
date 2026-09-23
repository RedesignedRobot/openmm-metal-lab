#!/bin/sh
# Measurement phases for 022 on the Mac Studio.  Every speed is the host wall clock over whole steps
# (fahwu.py, time.perf_counter, after a 200-step warm-up); profile numbers come from the platform
# (OPENMM_METAL_PROFILE, see profrun.py).  Each call is one lease-sized block: run it through leased.sh.
# usage: run.sh <phase> <out-dir> <wu-dir> <args>...
#   ctest <variant> <prec>  the variant's Metal C++ tests in precision Single or Mixed; failures rerun once alone
#   bits <variant>...       1000 steps of each of $WORKLOADS, single and mixed, twice per variant, digests
#   energy <variant>...     50 potential-energy evaluations of the start state of each of $WORKLOADS,
#                           single and mixed, per variant (the run-to-run spread of the energy sum)
#   p1 <variant>            profiling-off, census and per-dispatch runs of each of $WORKLOADS in single
#                           and mixed; the order of the three modes rotates from cell to cell
#   runs <log> <spec>...    one run per spec variant:workload:precision:platform:mode, $DURATION s each
#                           (default 60), in the order rotated by $ROUND (default 1)
# A variant is a directory under $VROOT made by build.sh, and its name is the label; a workload is a
# directory under <wu-dir>.
# Launch through detach.py from a shell at nice 0, never from zsh with &: zsh runs background jobs at
# nice 5 (BG_NICE).
set -u
phase=$1 out=$2 wus=$3
shift 3
here=$(cd "$(dirname "$0")" && pwd)
vroot=${VROOT:-/tmp/openmm-metal-bench/022/v}
PATH=/tmp/openmm-metal-bench/env/bin:$PATH  # ctest
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
if [ "$nice_value" != 0 ]; then
    echo "running at nice $nice_value, not 0; see the launch line above" >&2
    exit 1
fi
mkdir -p "$out"
snapshot() {
    { echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) $1"; uptime; pmset -g therm
      top -l 2 -o cpu -n 6 -stats command,cpu | tail -6; } >> "$out/host.txt" 2>&1
}
{ echo "== $phase $* nice $nice_value"; uname -a; sw_vers; sysctl -n machdep.cpu.brand_string hw.memsize
  for v in $(ls "$vroot"); do echo "$v: $(head -1 "$vroot/$v/commit.txt")"; done; } >> "$out/host.txt" 2>&1

rotate() {  # rotate <n> <items...>: the items starting from item number <n>
    r=$1; shift
    echo "$@" | tr ' ' '\n' | awk -v r="$r" '{a[NR]=$0} END {for (i=0;i<NR;i++) print a[(i+r-1)%NR+1]}'
}
prof() {  # prof <log> <variant> <workload> <precision> <mode> [platform]
    log=$1 v=$vroot/$2
    "$v/python.sh" "$here/profrun.py" "$v/python.sh" "$2" "$wus/$3" "$4" "$5" "${DURATION:-60}" "${6:-Metal}" \
        >> "$out/$log.jsonl" 2>> "$out/$log.err"
    echo "$(date -u +%H:%M:%SZ) $log $2 $3 $4 $5 ${6:-Metal} exit $?"
}

case $phase in
ctest)
    v=$vroot/$1 log=$out/ctest-$1-$2
    snapshot "ctest $1 $2"
    (cd "$v/build" && ctest -R "^TestMetal.*$2\$" -j 4 --output-on-failure > "$log.log" 2>&1)
    (cd "$v/build" && ctest -R "^TestMetal.*$2\$" --rerun-failed --output-on-failure > "$log-rerun.log" 2>&1)
    grep -E "tests passed|tests failed|\(Failed\)|\*\*\*" "$log.log" "$log-rerun.log" ;;
bits)
    snapshot bits
    for wu in $WORKLOADS; do
        for prec in single mixed; do
            for v in "$@"; do
                for rep in 1 2; do
                    "$vroot/$v/python.sh" "$here/bitwise.py" "$wus/$wu" "$prec" 1000 "$out/$v-$wu-$prec-$rep.npz" \
                        2>> "$out/bits.err" | sed "s/^{/{\"variant\": \"$v\", \"rep\": $rep, /" >> "$out/bits.jsonl"
                done
            done
        done
    done ;;
energy)
    snapshot energy
    for wu in $WORKLOADS; do
        for prec in single mixed; do
            for v in "$@"; do
                "$vroot/$v/python.sh" "$here/energy.py" "$wus/$wu" "$prec" 50 2>> "$out/energy.err" \
                    | sed "s/^{/{\"variant\": \"$v\", /" >> "$out/energy.jsonl"
            done
        done
    done ;;
p1)
    cell=0
    for wu in $WORKLOADS; do
        snapshot "p1 $wu"
        for prec in single mixed; do
            cell=$((cell+1))
            for mode in $(rotate $(( (cell-1)%3+1 )) 0 1 kernels); do
                prof p1 "$1" "$wu" "$prec" "$mode"
            done
        done
    done ;;
runs)
    log=$1; shift
    snapshot "runs $log round ${ROUND:-1}"
    for spec in $(rotate "${ROUND:-1}" "$@"); do
        IFS=: read -r v wu prec platform mode <<EOF
$spec
EOF
        prof "$log" "$v" "$wu" "$prec" "$mode" "$platform"
    done ;;
*)
    echo "unknown phase $phase" >&2; exit 1 ;;
esac
snapshot "end $phase"
