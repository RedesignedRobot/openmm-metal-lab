#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
if ! mkdir "$D/m2-once" 2>/dev/null; then
    test -d "$D/m2-once"
    echo 'M2 already submitted; see m2-main.log, m2-worker.pid and m2.verdict'
    exit 0
fi
echo "$$" > "$D/m2-worker.pid"
exec > "$D/m2-main.log" 2>&1
finish() {
    code=$?
    echo "M2 exit=$code" > "$D/m2.verdict"
}
trap finish EXIT
test -f /tmp/openmm-metal-bench/READY
/tmp/openmm-metal-bench/ultra-tools/m2cand.sh -r 2 -s 15 -t pme,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose $HOME/code/wt/m29-unified
