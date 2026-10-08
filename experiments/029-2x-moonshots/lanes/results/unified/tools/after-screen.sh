#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
T=/tmp/openmm-metal-bench/ultra-tools
stage=smokes
finish() {
    code=$?
    echo "local screens exit=$code stage=$stage; inspect separate M2 verdict" > "$D/after-screen.verdict"
}
trap finish EXIT
test -f /tmp/openmm-metal-bench/READY
grep -qx 'src 40a2106d8b2acbbcfa2d9ac6c9e9617390f8f7d7' "$D/BUILT"
grep -qx 'CANDIDATE CORRECTNESS COMPLETE' "$D/after-ready.log"
"$D/tools/smoke-arms.sh"
stage=m2-submission
"$D/tools/run-m2.sh"
stage=screen-small
"$D/tools/screen-candidate.sh" small
stage=screen-cellulose
"$D/tools/screen-candidate.sh" cellulose
stage=complete
