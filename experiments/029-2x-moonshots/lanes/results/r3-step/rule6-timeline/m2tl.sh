#!/bin/sh
# r3-step rule 6 on the M2: benchmark.py 15 s with timeline.dylib (r3-tools' rule 6 probe), apoa1pme and
# apoa1ljpme mixed, base 8ae6cf17b, trunk cand-r3-fah-df6cad8748 (5071882fa) and the fix
# cand-r3-step-r6-ac5e12b175 (82a1f9c98), 3 rounds, arm order rotated and reversed each round.
ROOT=$HOME/lab/ultra-m2.noindex
P=$ROOT/r3-step/tl
cd $ROOT/base/benchmarks || exit 2
unset PYTHONPATH OPENMM_CPU_THREADS
mkdir -p $P/out
for r in 1 2 3; do for test in apoa1ljpme apoa1pme; do
  case $r in
    1) list="base cand-r3-fah-df6cad8748 cand-r3-step-r6-ac5e12b175" ;;
    2) list="cand-r3-step-r6-ac5e12b175 cand-r3-fah-df6cad8748 base" ;;
    3) list="cand-r3-fah-df6cad8748 base cand-r3-step-r6-ac5e12b175" ;;
  esac
  for arm in $list; do
    case $arm in base) tag=base ;; cand-r3-fah*) tag=trunk ;; *) tag=fix ;; esac
    name=$tag-$test-mixed-r$r
    "$ROOT/tools/m2-lease.sh" r3-step "r3-step rule 6 timeline $name" /usr/bin/time -l -o $P/out/$name.time \
      /usr/bin/env TIMELINE_OUT=$P/out/$name.tl DYLD_INSERT_LIBRARIES=$P/timeline.dylib $ROOT/$arm/venv/bin/python benchmark.py --platform Metal --precision mixed --test $test --seconds 15 \
      --style table --outfile $P/out/$name.json > $P/out/$name.log 2>&1
    echo "$name exit $? $(awk '/peak memory footprint/{printf "%.1f MiB", $1/1048576}' $P/out/$name.time) $(head -1 $P/out/$name.tl)"
  done
done; done
echo "M2TL DONE $(date -u +%H:%M:%SZ)"
