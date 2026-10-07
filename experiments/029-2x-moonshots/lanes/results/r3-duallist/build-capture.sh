#!/bin/sh
set -eu
tree=$1
out=$2
src=$tree/src
build=$tree/build
prefix=$tree/prefix
here=$(cd "$(dirname "$0")" && pwd)
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
c++ -O2 -std=gnu++17 -arch arm64 -isysroot "$(xcrun --show-sdk-path)" -shared -fPIC -stdlib=libc++ -w \
    -DMETALCPP_SYMBOL_VISIBILITY_HIDDEN \
    -I"$src/platforms/metal/include" -I"$src/platforms/metal/src" -I"$src/platforms/common/include" \
    -I"$src/openmmapi/include" -I"$src/serialization/include" -I"$src/olla/include" -I"$src/include" -I"$src/src" \
    -I"$src/libraries/metal-cpp" -I"$src/libraries/lepton/include" -I"$src/libraries/vecmath/include" \
    -I"$build/platforms/metal/src" -I"$build/platforms/common/src" \
    -L"$prefix/lib" -L"$prefix/lib/plugins" -lOpenMM -lOpenMMMetal -framework Metal -framework Foundation \
    -Wl,-rpath,"$prefix/lib" -Wl,-rpath,"$prefix/lib/plugins" -o "$out" "$here/capture.mm"
