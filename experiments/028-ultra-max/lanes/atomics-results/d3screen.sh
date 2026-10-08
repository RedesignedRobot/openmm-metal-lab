#!/bin/sh
# Design 3 (72af6f137, ultra-dispatch/d3) against its serial base (b919bfe7a, ultra-dispatch/d3floor):
# quick gate first, then a 2x15 s screen split into six tickets of two tests each, kill-line tests first.
L=/tmp/openmm-metal-bench/ultra-atomics
D=/tmp/openmm-metal-bench/ultra-dispatch
T=/tmp/openmm-metal-bench/ultra-tools
$T/gate.sh --quick $D/d3 > $L/gate-d3.out 2>&1
tail -1 $L/gate-d3.out | grep -q PASS || { echo "$(date -u +%H:%M:%SZ) quick gate did not pass: $(tail -1 $L/gate-d3.out)"; exit 1; }
echo "$(date -u +%H:%M:%SZ) quick gate PASS"
for prec in single mixed; do
  for tests in apoa1rf,amber20-cellulose rf,pme amber20-dhfr,gbsa; do
    name=d3s-$prec-$(echo $tests | cut -c1-6)
    $T/lease.sh ultra-atomics "d3 screen $prec $tests 2x15 s" $T/ab.sh --rerun-builds $L/$name 2 15 $tests \
      ser=$D/d3floor/venv/bin/python:Metal:$prec d3=$D/d3/venv/bin/python:Metal:$prec > $L/$name.out 2>&1
    echo "$(date -u +%H:%M:%SZ) $name exit $?"
  done
done
echo "SCREEN DONE"
