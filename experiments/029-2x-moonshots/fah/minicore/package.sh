#!/bin/sh
# package.sh <prefix> <bundle dir>
# Builds minicore against an installed OpenMM prefix and lays it out the way a core ships:
#   minicore, lib/libOpenMM.dylib, plugins/{Metal,CPU,PME}.
# Every Mach-O is re-signed ad hoc with the hardened runtime. The bundle must not reference the
# prefix, the build tree or Homebrew; the otool check at the end fails the script if it does.
set -eu
prefix=$1
bundle=$2
src=$(cd "$(dirname "$0")" && pwd)

# Nothing on the Studio gets deleted without the owner's yes (2026-09-28), so the bundle dir must be new.
[ -e "$bundle" ] && { echo "$bundle exists; pick a new bundle dir"; exit 2; }
mkdir -p "$bundle/lib" "$bundle/plugins"
clang++ -std=c++17 -O2 -mmacosx-version-min=15.0 -Wall -Wno-reorder-ctor -Wno-unused-function -I"$prefix/include" \
    "$src/minicore.cpp" "$src/compiletime.cpp" -L"$prefix/lib" -lOpenMM -lobjc -framework Metal -Wl,-rpath,@executable_path/lib -o "$bundle/minicore"
cp "$prefix/lib/libOpenMM.dylib" "$bundle/lib/"
for p in Metal CPU PME; do
    cp "$prefix/lib/plugins/libOpenMM$p.dylib" "$bundle/plugins/"
done

# Ad hoc signatures carry no Team ID, so the hardened runtime's library validation would refuse the
# bundle's own dylibs. adhoc.entitlements turns that check off for this test only; a core signed
# with FAH's Developer ID keeps library validation, since every file then has the same Team ID.
for f in "$bundle"/lib/*.dylib "$bundle"/plugins/*.dylib; do
    codesign --force --sign - --options runtime "$f"
done
codesign --force --sign - --options runtime --entitlements "$src/adhoc.entitlements" "$bundle/minicore"

status=0
for f in "$bundle/minicore" "$bundle"/lib/*.dylib "$bundle"/plugins/*.dylib; do
    if otool -L "$f" | tail -n +2 | grep -v -e '@rpath/' -e '/usr/lib/' -e '/System/Library/'; then
        echo "FAIL: $f links outside the bundle and the OS"
        status=1
    fi
    if otool -l "$f" | grep -A2 LC_RPATH | grep ' path ' | grep -v '@executable_path\|@loader_path'; then
        echo "FAIL: $f has an absolute rpath"
        status=1
    fi
    vtool -show-build "$f" | grep minos
done
exit $status
