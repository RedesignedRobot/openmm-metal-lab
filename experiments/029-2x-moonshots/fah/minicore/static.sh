#!/bin/sh
# static.sh <prefix> <bundle dir>
# Builds minicore with OpenMM and the Metal platform linked in statically, the way a FAH core ships
# (one executable, no plugins dir). The prefix must come from a build with OPENMM_BUILD_STATIC_LIB=ON
# and CMAKE_OSX_DEPLOYMENT_TARGET=15.0. The executable is signed ad hoc with the hardened runtime;
# with no dylibs of its own it needs no entitlements. The checks at the end fail the script if it
# links anything outside the OS or its minos is below 15.0.
set -eu
prefix=$1
bundle=$2
src=$(cd "$(dirname "$0")" && pwd)

# Nothing on the Studio gets deleted without the owner's yes (2026-09-28), so the bundle dir must be new.
[ -e "$bundle" ] && { echo "$bundle exists; pick a new bundle dir"; exit 2; }
mkdir -p "$bundle"
# force_load keeps every object of libOpenMM_static.a: the serialization proxies register from an
# __attribute__((constructor)) that nothing references, so a plain link drops them and XmlSerializer
# fails with "no serialization proxy registered for type 'System'".
clang++ -std=c++17 -O2 -mmacosx-version-min=15.0 -Wall -Wno-reorder-ctor -Wno-unused-function -I"$prefix/include" \
    -DMINICORE_STATIC -DOPENMM_USE_STATIC_LIBRARIES "$src/minicore.cpp" "$src/compiletime.cpp" \
    "$prefix/lib/plugins/libOpenMMMetal_static.a" -Wl,-force_load,"$prefix/lib/libOpenMM_static.a" \
    -lobjc -framework Metal -framework Foundation -framework QuartzCore -framework IOKit -framework CoreFoundation \
    -o "$bundle/minicore"
codesign --force --sign - --options runtime "$bundle/minicore"

status=0
if otool -L "$bundle/minicore" | tail -n +2 | grep -v -e '/usr/lib/' -e '/System/Library/'; then
    echo "FAIL: minicore links outside the OS"
    status=1
fi
minos=$(vtool -show-build "$bundle/minicore" | awk '/minos/ {print $2}')
echo "minos $minos"
case "$minos" in
15.*|1[6-9].*|2[0-9].*) ;;
*) echo "FAIL: minos $minos is below 15.0"; status=1 ;;
esac
exit $status
