#!/bin/sh
# C2: run the mock FAH core on each work unit, one lease per work unit.
# usage: sh c2.sh <out-dir> "<wu> <steps> <interval>" ...
B=/tmp/openmm-metal-bench/020
PY=$B/venv/bin/python
out=$1; shift
mkdir -p $out
for job in "$@"; do
  set -- $job
  until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
  echo "fah-readiness $(date -u +%H:%MZ) C2 mock core $1" > /tmp/openmm-lease/owner
  if [ ! -d $B/fah-wu/$1 ]; then
    case $1 in
      stmv) $PY $B/lab/makewu.py stmv $B/amber $B/fah-wu/stmv ;;
      tip4pew) $PY $B/lab/makewu.py tip4pew $B/fah-wu/tip4pew ;;
    esac >> $out/makewu.log 2>&1
  fi
  echo "== $(date -u +%FT%TZ) $1 $2 $3" >> $out/run.log
  $PY $B/lab/mockcore.py $B/fah-wu/$1 $out $2 $3 >> $out/results.jsonl 2>> $out/run.log
  echo "exit $? $(date -u +%FT%TZ)" >> $out/run.log
  rm -rf /tmp/openmm-lease
done
echo ALLDONE >> $out/run.log
