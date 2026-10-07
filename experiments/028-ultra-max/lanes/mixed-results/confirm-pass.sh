#!/bin/sh
# Mixed lane confirmation pass, inside one queue slot's lease: 3 x 30 s of ultra-base and c1..c5 in mixed on
# one test, then optional untimed work. usage: confirm-pass.sh <name> <test> [after-script]
M=/tmp/openmm-metal-bench/ultra-mixed
B=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0" >&2; exit 2; }
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
echo "$(date -u +%H:%M:%SZ) $1 start"
/tmp/openmm-metal-bench/ultra-tools/ab.sh $M/$1 3 30 $2 \
    base=$B:Metal:mixed c1=$M/venv/bin/python:Metal:mixed c2=$M/t2/venv/bin/python:Metal:mixed \
    c3=$M/t3/venv/bin/python:Metal:mixed c4=$M/t4/venv/bin/python:Metal:mixed c5=$M/t5/venv/bin/python:Metal:mixed
echo "$(date -u +%H:%M:%SZ) $1 timed part done"
[ -n "${3:-}" ] && /bin/sh $M/$3
echo "$(date -u +%H:%M:%SZ) $1 done"
