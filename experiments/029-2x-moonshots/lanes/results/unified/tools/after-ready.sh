#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
stage=waiting
finish() {
    code=$?
    if [ "$code" -eq 0 ]; then
        echo 'PASS local-profiles-correctness-and-screens; inspect separate M2 verdict' > "$D/after-ready.verdict"
    else
        echo "FAIL stage=$stage exit=$code" > "$D/after-ready.verdict"
    fi
}
trap finish EXIT
echo "Waiting for READY and candidate BUILT at $(date -u +%FT%TZ)"
while [ ! -f /tmp/openmm-metal-bench/READY ] || [ ! -f "$D/BUILT" ]; do
    if [ ! -f "$D/BUILT" ] && ! kill -0 "$(cat "$D/build.pid")" 2>/dev/null; then
        echo 'Candidate builder exited without BUILT'
        exit 1
    fi
    sleep 30
done
stage=baseline-profiles
echo "Prerequisites ready at $(date -u +%FT%TZ)"
"$D/tools/profile-baseline.sh"
stage=candidate-correctness
"$D/tools/check-candidate.sh"
stage=candidate-smokes
"$D/tools/smoke-arms.sh"
stage=m2-launch
/tmp/openmm-metal-bench/ultra-tools/bg.sh "$D/m2.log" "$D/tools/run-m2.sh" > "$D/m2.pid"
stage=screen-small
"$D/tools/screen-candidate.sh" small
stage=screen-cellulose
"$D/tools/screen-candidate.sh" cellulose
