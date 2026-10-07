#!/bin/sh
# Launch through ultra-tools/bg.sh. Compilation happens before taking the lease.
set -eu
here=/tmp/openmm-metal-bench/ultra-r2-accum-nb/t256
tree="$1"
tools=/tmp/openmm-metal-bench/ultra-tools
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
hour=$(date -u +%H)
case "$hour" in 00|01|02|03|04|05|06) echo 'quiet hours: no capture or compile' >&2; exit 2;; esac
src=$tree/src build=$tree/build prefix=$tree/prefix
c++ -O2 -std=gnu++17 -arch arm64 -isysroot "$(xcrun --show-sdk-path)" -shared -fPIC -stdlib=libc++ \
    -DMETALCPP_SYMBOL_VISIBILITY_HIDDEN \
    -I"$src/platforms/metal/include" -I"$src/platforms/metal/src" -I"$src/platforms/common/include" \
    -I"$src/openmmapi/include" -I"$src/serialization/include" -I"$src/olla/include" -I"$src/include" -I"$src/src" \
    -I"$src/libraries/metal-cpp" -I"$src/libraries/lepton/include" -I"$src/libraries/vecmath/include" \
    -I"$build/platforms/metal/src" -I"$build/platforms/common/src" \
    -L"$prefix/lib" -L"$prefix/lib/plugins" -lOpenMM -lOpenMMMetal -framework Foundation -framework Metal -framework QuartzCore -lobjc \
    -Wl,-rpath,"$prefix/lib" -Wl,-rpath,"$prefix/lib/plugins" \
    -o "$2" "$here/nbreplay.cpp"
