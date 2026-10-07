#!/bin/sh
# Runs on the M3 Ultra: builds cand at 4ab189b29 (precise rsqrt and division in the AMOEBA fixed field on Metal) with
# build.sh outside any hold, then queues three tickets, each with its pid in tickets.pid: the full gate,
# the amoebaforces x5 bitwise check (--correctness), and a 2x15 s screen of bar (6998abf2f) against
# fix2 on amoebagk and amoebapme, single and mixed. amoebapme runs the fixed field kernel too.
L=/tmp/openmm-metal-bench/ultra-plugins
T=/tmp/openmm-metal-bench/ultra-tools
echo "build $(date -u +%H:%M:%SZ)"
$T/build.sh $L/cand > $L/cand/build.out 2>&1 || { echo "build FAILED"; tail -20 $L/cand/build.out; exit 1; }
echo "built $(sed -n 's/^commit //p' $L/cand/BUILT) $(date -u +%H:%M:%SZ)"
/bin/sh -c 'nohup '$T'/ab.sh '$L'/screen-fix2 2 15 amoebagk,amoebapme bar-single='$L'/bar/venv/bin/python:Metal:single fix2-single='$L'/cand/venv/bin/python:Metal:single bar-mixed='$L'/bar/venv/bin/python:Metal:mixed fix2-mixed='$L'/cand/venv/bin/python:Metal:mixed > '$L'/screen-fix2.out 2>&1 < /dev/null & echo $! screen-fix2 >> '$L'/tickets.pid'
sleep 2
/bin/sh -c 'nohup '$T'/gate.sh '$L'/cand > '$L'/cand/gate.out 2>&1 < /dev/null & echo $! gate-fix2 >> '$L'/tickets.pid'
/bin/sh -c 'nohup '$T'/lease.sh --correctness plugins "amoebaforces x5 on 4ab189b29" /bin/sh '$L'/amoebaforces.sh fix2 '$L'/cand > '$L'/forces-fix2.out 2>&1 < /dev/null & echo $! forces-fix2 >> '$L'/tickets.pid'
echo "queued $(date -u +%H:%M:%SZ)"
