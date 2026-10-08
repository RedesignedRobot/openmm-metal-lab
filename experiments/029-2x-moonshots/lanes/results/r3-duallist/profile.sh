#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=/tmp/openmm-metal-bench/ultra-r3-duallist
label=$1
test=$2
if [ -z "${OPENMM_LEASE_PID:-}" ]; then
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh r3-duallist "32-step counters $label $test" /bin/sh "$0" "$@"
fi
hour=$(date -u +%H)
[ "$hour" -ge 7 ] || { echo 'night timing slot: profile refused'; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export MTL_CAPTURE_ENABLED=1
case $label in
    control) tree=/tmp/openmm-metal-bench/ultra-r2-accum-nb; lib=$root/control-capture.dylib ;;
    dual) tree=$root; lib=$root/capture.dylib ;;
    *) exit 2 ;;
esac
out=$root/counters/$test-$label
mkdir -p "$out"
"$tree/venv/bin/python" "$here/capture.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$test" "$lib" "$out/$test-$label.gputrace" > "$out/capture.txt" 2>&1
status=0
/tmp/openmm-metal-bench/env/bin/python "$here/gddual.py" "$out/$test-$label.gputrace" "$out" > "$out/profile.txt" 2>&1 || status=$?
[ "$status" -eq 0 ] || exit "$status"
echo "PROFILE DONE $test $label $(date -u +%Y-%m-%dT%H:%M:%SZ)"
