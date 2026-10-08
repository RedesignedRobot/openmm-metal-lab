#!/bin/sh
# Launch through ultra-tools/bg.sh. Compilation happens before taking the lease.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree=/tmp/openmm-metal-bench/ultra-r3-nb16
tools=/tmp/openmm-metal-bench/ultra-tools
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
hour=$(date -u +%H)
case "$hour" in 00|01|02|03|04|05|06) echo 'quiet hours: no capture or compile' >&2; exit 2;; esac
if [ "${1:-}" = run ]; then
    exec "$tree/venv/bin/python" "$here/capture.py" --lib "$tree/libsnapshot.dylib" \
        --bench /tmp/openmm-metal-bench/ultra-base/benchmarks --out "$here/snapshots" \
        --built "$tree/BUILT" --precision single --steps 0,100 \
        apoa1rf apoa1pme amber20-cellulose amber20-stmv
fi
src=$tree/src build=$tree/build prefix=$tree/prefix
c++ -O2 -std=gnu++17 -arch arm64 -isysroot "$(xcrun --show-sdk-path)" -shared -fPIC -stdlib=libc++ \
    -DMETALCPP_SYMBOL_VISIBILITY_HIDDEN \
    -I"$src/platforms/metal/include" -I"$src/platforms/metal/src" -I"$src/platforms/common/include" \
    -I"$src/openmmapi/include" -I"$src/serialization/include" -I"$src/olla/include" -I"$src/include" -I"$src/src" \
    -I"$src/libraries/metal-cpp" -I"$src/libraries/lepton/include" -I"$src/libraries/vecmath/include" \
    -I"$build/platforms/metal/src" -I"$build/platforms/common/src" \
    -L"$prefix/lib" -L"$prefix/lib/plugins" -lOpenMM -lOpenMMMetal \
    -Wl,-rpath,"$prefix/lib" -Wl,-rpath,"$prefix/lib/plugins" \
    -o "$tree/libsnapshot.dylib" "$here/snapshot.cpp"
exec "$tools/lease.sh" --correctness r3-nb16 "live list snapshots: four benchmarks at steps 0 and 100" /bin/sh "$here/capture.sh" run
