#!/bin/sh
# Runs on the M3 Ultra: builds head at 95373278b (precise rsqrt in the AMOEBA fixed field on Metal) with
# build.sh outside any hold, then queues three tickets, each with its pid in tickets.pid: the full gate,
# the amoebaforces x5 bitwise check (--correctness), and a 2x15 s screen of bar (6998abf2f) against
# fix on amoebagk and amoebapme, single and mixed. amoebapme runs the fixed field kernel too.
L=/tmp/openmm-metal-bench/ultra-plugins
T=/tmp/openmm-metal-bench/ultra-tools
echo "build $(date -u +%H:%M:%SZ)"
$T/build.sh $L/head > $L/head/build.out 2>&1 || { echo "build FAILED"; tail -20 $L/head/build.out; exit 1; }
echo "built $(sed -n 's/^commit //p' $L/head/BUILT) $(date -u +%H:%M:%SZ)"
/bin/sh -c 'nohup '$T'/gate.sh '$L'/head > '$L'/head/gate.out 2>&1 < /dev/null & echo $! gate-fix >> '$L'/tickets.pid'
/bin/sh -c 'nohup '$T'/lease.sh --correctness plugins "amoebaforces x5 on 95373278b" /bin/sh '$L'/amoebaforces.sh fix '$L'/head > '$L'/forces-fix.out 2>&1 < /dev/null & echo $! forces-fix >> '$L'/tickets.pid'
/bin/sh -c 'nohup '$T'/ab.sh '$L'/screen-fix 2 15 amoebagk,amoebapme bar-single='$L'/bar/venv/bin/python:Metal:single fix-single='$L'/head/venv/bin/python:Metal:single bar-mixed='$L'/bar/venv/bin/python:Metal:mixed fix-mixed='$L'/head/venv/bin/python:Metal:mixed > '$L'/screen-fix.out 2>&1 < /dev/null & echo $! screen-fix >> '$L'/tickets.pid'
echo "queued $(date -u +%H:%M:%SZ)"
