#!/bin/sh
# M2 under job.lock: benchmark.py apoa1ljpme mixed, 8ae6cf17b (base) against 4c26efa9b, 3 interleaved rounds, with timeline.dylib.
ROOT=$HOME/lab/ultra-m2.noindex
P=$ROOT/r3-tools-probe
cd $ROOT/base/benchmarks || exit 2
unset PYTHONPATH OPENMM_CPU_THREADS
mkdir -p $P/out6
for r in 1 2; do for prec in single mixed; do
  list="base cand-r3-interp-bab21c2a2d"
  [ $((r % 2)) = 0 ] && list="cand-r3-interp-bab21c2a2d base"
  for arm in $list; do
    name=${arm%%-*}-apoa1pme-$prec-r$r
    "$ROOT/tools/m2-lease.sh" ultra-m2 "r3-tools footprint timeline $name" /usr/bin/time -l -o $P/out6/$name.time \
      /usr/bin/env TIMELINE_OUT=$P/out6/$name.tl DYLD_INSERT_LIBRARIES=$P/timeline.dylib $ROOT/$arm/venv/bin/python benchmark.py --platform Metal --precision $prec --test apoa1pme --seconds 15 \
      --style table --outfile $P/out6/$name.json > $P/out6/$name.log 2>&1
    echo "$name exit $? $(awk '/peak memory footprint/{printf "%.1f MiB", $1/1048576}' $P/out6/$name.time) $(head -1 $P/out6/$name.tl)"
  done
done; done
