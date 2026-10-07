#!/bin/sh
# pilot.sh <bundle> <corpus> <work dir> smoke|kill|soak|reload|opencl|restart [precision | plugin dir]
# The pilot checks, one GPU correctness ticket per mode. Every run uses the packaged bundle
# (package.sh), an empty environment and the core's priority (nice 19, darwin background).
# smoke, kill and soak take an optional precision, single by default; use a new work dir per precision.
#   smoke  each corpus unit end to end: force check against Reference, then 25000 steps (neq 1000)
#   kill   killtest.sh on gbsa and neq (bitwise expected) and tip3p-hmr (bitwise not expected, gap 3)
#   soak   tip3p-hmr (PME, barostat, neighbor list) for 200000 steps, footprint every 10000 steps
#   reload  the restart difference without the barostat: runs A straight, B resumed in a new process
#          at step 500, C with an in-process checkpoint round trip at step 500; dumpcmp.py B and C vs A
#   opencl gap 3 on upstream's OpenCL platform, which has no DeterministicForces: tip3p-hmr twice
#          straight and once stopped at step 500 and resumed; needs a plugin dir with OpenCL (5th arg)
#   restart  why a killed tip3p-hmr run differs: killtest.sh with --trace on tip3p-hmr as shipped
#          (barostat every 25 steps) and with the barostat off, then tracecmp.py on each
set -u
bundle=$1
corpus=$2
work=$3
mode=$4
here=$(cd "$(dirname "$0")" && pwd)
precision=single
case $mode in smoke|kill|soak) precision=${5:-single} ;; esac

mkdir -p "$work/wu"
for unit in gbsa neq tip3p-hmr tip4pew; do
    mkdir -p "$work/wu/$unit"
    for f in system state integrator; do
        [ -f "$work/wu/$unit/$f.xml" ] || bunzip2 -c "$corpus/$unit/$f.xml.bz2" > "$work/wu/$unit/$f.xml"
    done
done

# Output dirs must be new: nothing on the Studio gets deleted without the owner's yes (2026-09-28).
require_new() {
    for d in "$@"; do
        [ -e "$d" ] && { echo "$d exists; pick a new work dir"; exit 2; }
    done
    return 0
}

core() {
    env -i PATH=/usr/bin:/bin nice -n 19 /usr/sbin/taskpolicy -b "$bundle/minicore" "$@"
}
echo "precision $precision"

case $mode in
smoke)
    for unit in gbsa neq tip3p-hmr tip4pew; do
        steps=25000
        [ $unit = neq ] && steps=1000
        require_new "$work/smoke-$unit"
        start=$(date +%s)
        core --wu "$work/wu/$unit" --out "$work/smoke-$unit" --steps $steps --checkpoint-steps 1000 --precision $precision > "$work/smoke-$unit.log" 2>&1
        status=$?
        echo "$unit: exit $status, $(( $(date +%s) - start )) s"
        grep -e '^force check' -e '^plugin' -e 'error' "$work/smoke-$unit.log"
        tail -n 2 "$work/smoke-$unit.log" | head -n 1
    done
    ;;
kill)
    "$here/killtest.sh" "$bundle" "$work/wu/gbsa" "$work/kill-gbsa" 20000 1000 --precision $precision
    "$here/killtest.sh" "$bundle" "$work/wu/neq" "$work/kill-neq" 1000 100 --precision $precision
    "$here/killtest.sh" "$bundle" "$work/wu/tip3p-hmr" "$work/kill-tip3p-hmr" 20000 1000 --precision $precision
    ;;
soak)
    require_new "$work/soak"
    core --wu "$work/wu/tip3p-hmr" --out "$work/soak" --steps 200000 --checkpoint-steps 10000 --precision $precision > "$work/soak.log" 2>&1
    echo "soak: exit $?"
    grep '^step' "$work/soak.log" | awk 'NR == 1 || NR % 5 == 0 { print }'
    ;;
reload)
    dumps="500 501 502 510 600 1000 2000"
    flags="--wu $work/wu/tip3p-hmr-nobaro --checkpoint-steps 500 --seed 2029 --deterministic --trace"
    flags="$flags --dump-steps $(echo $dumps | tr ' ' ,)"
    require_new "$work/reload-A" "$work/reload-B" "$work/reload-C"
    core $flags --steps 2000 --out "$work/reload-A" > "$work/reload-A.log" 2>&1
    core $flags --steps 500 --out "$work/reload-B" > "$work/reload-B.log" 2>&1
    core $flags --steps 2000 --out "$work/reload-B" >> "$work/reload-B.log" 2>&1
    core $flags --steps 2000 --reload-at 500 --out "$work/reload-C" > "$work/reload-C.log" 2>&1
    grep -H -e '^done' -e 'error' -e '^resumed' "$work"/reload-?.log
    echo "B, resumed in a new process at step 500, vs A:"
    python3 "$here/dumpcmp.py" "$work/reload-A" "$work/reload-B" $dumps
    echo "C, checkpoint round trip in the same process at step 500, vs A:"
    python3 "$here/dumpcmp.py" "$work/reload-A" "$work/reload-C" $dumps
    ;;
opencl)
    plugins=$5
    flags="--wu $work/wu/tip3p-hmr --platform OpenCL --plugins $plugins --checkpoint-steps 500 --seed 2029 --trace"
    require_new "$work/opencl-S1" "$work/opencl-S2" "$work/opencl-R"
    core $flags --steps 1000 --out "$work/opencl-S1" > "$work/opencl-S1.log" 2>&1
    core $flags --steps 1000 --out "$work/opencl-S2" > "$work/opencl-S2.log" 2>&1
    core $flags --steps 500 --out "$work/opencl-R" > "$work/opencl-R.log" 2>&1
    core $flags --steps 1000 --out "$work/opencl-R" >> "$work/opencl-R.log" 2>&1
    grep -H -e '^platform' -e '^force check' -e '^done' -e 'error' -e '^resumed' "$work"/opencl-*.log
    echo "S2, a second straight run, vs S1:"
    python3 "$here/tracecmp.py" "$work/opencl-S1" "$work/opencl-S2" 25
    echo "R, stopped at step 500 and resumed in a new process, vs S1:"
    python3 "$here/tracecmp.py" "$work/opencl-S1" "$work/opencl-R" 25
    ;;
restart)
    nobaro=$work/wu/tip3p-hmr-nobaro
    mkdir -p "$nobaro"
    cp "$work/wu/tip3p-hmr/state.xml" "$work/wu/tip3p-hmr/integrator.xml" "$nobaro/"
    sed 's/frequency="25" name="MonteCarloBarostat"/frequency="0" name="MonteCarloBarostat"/' \
        "$work/wu/tip3p-hmr/system.xml" > "$nobaro/system.xml"
    for unit in tip3p-hmr:25 tip3p-hmr-nobaro:0; do
        name=${unit%:*}
        echo "== $name"
        "$here/killtest.sh" "$bundle" "$work/wu/$name" "$work/restart-$name" 5000 500 --trace
        python3 "$here/tracecmp.py" "$work/restart-$name/straight" "$work/restart-$name/killed" ${unit#*:}
    done
    ;;
*)
    echo "usage: pilot.sh <bundle> <corpus> <work dir> smoke|kill|soak|reload|opencl|restart [precision | plugin dir]"
    exit 2
    ;;
esac
