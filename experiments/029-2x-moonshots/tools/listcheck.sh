#!/bin/sh
# Neighbor-list coverage check (listcheck.py) on one tree: builds liblistcheck.dylib against the tree's
# headers and installed libraries into <out dir>, outside any hold, then runs listcheck.py with the tree's
# venv in one correctness ticket. Extra arguments go to listcheck.py (tests, --steps, --precision,
# --drop-tile). Writes <out dir>/listcheck.txt; exits 1 if a row fails. benchmark.py comes from the base
# tree beside <tree> (ultra-base on the Studio, base on the M2) unless LISTCHECK_BENCH names a directory.
# The ticket goes through lease.sh, or m2-lease.sh on the M2, under lane LISTCHECK_LANE (default listcheck).
#   ultra-tools/listcheck.sh <tree> <out dir> [listcheck.py arguments...]
set -eu
TOOLS=$(cd "$(dirname "$0")" && pwd)
if [ "$1" = run ]; then
    tree=$2 out=$3 bench=$4
    shift 4
    "$tree/venv/bin/python" "$TOOLS/listcheck.py" --lib "$out/liblistcheck.dylib" "$bench" "$@" > "$out/listcheck.txt" 2>&1
    exit
fi
tree=$(cd "$1" && pwd)
bench=${LISTCHECK_BENCH:-$(dirname "$tree")/ultra-base/benchmarks}
[ -d "$bench" ] || bench=$(dirname "$tree")/base/benchmarks
lease=$TOOLS/lease.sh
[ -x "$lease" ] || lease=$TOOLS/m2-lease.sh
mkdir -p "$2"
out=$(cd "$2" && pwd)
shift 2
src=$tree/src build=$tree/build prefix=$tree/prefix
c++ -O2 -std=gnu++17 -arch arm64 -isysroot "$(xcrun --show-sdk-path)" -shared -fPIC -stdlib=libc++ -w \
    -DMETALCPP_SYMBOL_VISIBILITY_HIDDEN \
    -I"$src/platforms/metal/include" -I"$src/platforms/metal/src" -I"$src/platforms/common/include" \
    -I"$src/openmmapi/include" -I"$src/serialization/include" -I"$src/olla/include" -I"$src/include" -I"$src/src" \
    -I"$src/libraries/metal-cpp" -I"$src/libraries/lepton/include" -I"$src/libraries/vecmath/include" \
    -I"$build/platforms/metal/src" -I"$build/platforms/common/src" \
    -L"$prefix/lib" -L"$prefix/lib/plugins" -lOpenMM -lOpenMMMetal \
    -Wl,-rpath,"$prefix/lib" -Wl,-rpath,"$prefix/lib/plugins" \
    -o "$out/.liblistcheck.dylib" "$TOOLS/listcheck.cpp"
mv "$out/.liblistcheck.dylib" "$out/liblistcheck.dylib"
status=0
"$lease" --correctness "${LISTCHECK_LANE:-listcheck}" "listcheck $(basename "$tree") $*" "$0" run "$tree" "$out" "$bench" "$@" || status=$?
cat "$out/listcheck.txt"
exit $status
