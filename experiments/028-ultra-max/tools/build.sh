#!/bin/sh
# Runs on the M3 Ultra: configures, builds and installs the tree in <dir>/src (put there by sync.sh)
# the way ultra-base is built: Xcode-beta's toolchain, Release, Metal, OpenCL, Python and tests on,
# C and Fortran wrappers off, `nice -n 10` and 6 jobs as RULES.md asks. It makes <dir>/build,
# <dir>/prefix and <dir>/venv, whose python imports this tree's openmm and sees numpy, scipy, Cython
# and setuptools from the shared env. A build dir configured with another SDK is removed and
# configured again; prefix stays until the install overwrites it, so runs of the old build keep
# working until the last minute. It ends by writing <dir>/BUILT with a hash of src and the
# compiler, which gate.sh and ab.sh check so nobody tests a stale build. Logs go to <dir>/logs.
# Launch detached, since a build outlives a flaky ssh:
#   /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/build.sh /tmp/openmm-metal-bench/ultra-<lane> > /tmp/openmm-metal-bench/ultra-<lane>/build.out 2>&1 < /dev/null &'
# usage: build.sh <dir>
set -eu
[ $# -eq 1 ] || { echo "usage: build.sh <dir>" >&2; exit 2; }
dir="${1%/}"
case "$dir" in
/tmp/openmm-metal-bench/ultra-*) ;;
*) echo "the dir must be /tmp/openmm-metal-bench/ultra-<lane>, not $dir" >&2; exit 2 ;;
esac
ENV=/tmp/openmm-metal-bench/env
WINDOW=/tmp/openmm-window
SITE=$ENV/lib/python3.13/site-packages
JOBS=6
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=$ENV/bin:$PATH
unset PYTHONPATH
case "$(xcrun --find clang 2>/dev/null)" in
"$DEVELOPER_DIR"/*) ;;
*) echo "xcrun doesn't find clang in $DEVELOPER_DIR; is Xcode-beta installed?" >&2; exit 2 ;;
esac
sdk="$(xcrun --show-sdk-path)"
toolchain="$(xcrun clang --version | head -1), SDK $sdk"
[ -f "$dir/src/CMakeLists.txt" ] || { echo "$dir/src has no CMakeLists.txt; run sync.sh first" >&2; exit 2; }
# A dedicated window (window.sh) keeps builds off the machine while it runs.
while [ -f "$WINDOW" ] && kill -0 "$(cut -d' ' -f1 "$WINDOW" 2>/dev/null)" 2>/dev/null; do
    [ -n "${told:-}" ] || echo "$(date -u +%H:%M:%SZ) waiting for the dedicated window to end: $(cat "$WINDOW" 2>/dev/null)"
    told=1
    sleep 30
done
rm -f "$dir/BUILT"
if [ -f "$dir/build/CMakeCache.txt" ] && ! grep -qx "CMAKE_OSX_SYSROOT:STRING=$sdk" "$dir/build/CMakeCache.txt"; then
    echo "$dir/build was configured with another SDK ($(sed -n 's/^CMAKE_OSX_SYSROOT:STRING=//p' "$dir/build/CMakeCache.txt")); removing it"
    rm -rf "$dir/build"
fi
mkdir -p "$dir/logs" "$dir/pydeps"
for p in numpy scipy Cython cython.py pyximport setuptools _distutils_hack; do
    ln -sfn "$SITE/$p" "$dir/pydeps/$p"
done
# No pip and no system site-packages, so setup.py never sees, or removes, the shared env's openmm.
[ -x "$dir/venv/bin/python" ] || "$ENV/bin/python3" -m venv --without-pip "$dir/venv"
echo "$dir/pydeps" > "$dir/venv/lib/python3.13/site-packages/ultra-pydeps.pth"
nice -n 10 cmake -S "$dir/src" -B "$dir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$dir/prefix" \
    -DPYTHON_EXECUTABLE="$dir/venv/bin/python" \
    -DOPENMM_BUILD_METAL_LIB=ON \
    -DOPENMM_BUILD_OPENCL_LIB=ON \
    -DOPENMM_BUILD_PYTHON_WRAPPERS=ON \
    -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF \
    -DOPENMM_BUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=ON \
    > "$dir/logs/configure.log" 2>&1 || { tail -30 "$dir/logs/configure.log"; exit 1; }
grep -qx "CMAKE_OSX_SYSROOT:STRING=$sdk" "$dir/build/CMakeCache.txt" || { echo "cmake didn't pick up $sdk" >&2; exit 1; }
nice -n 10 ninja -C "$dir/build" -j $JOBS > "$dir/logs/build.log" 2>&1 \
    || { grep -E "error|FAILED" "$dir/logs/build.log" | head -20; exit 1; }
nice -n 10 ninja -C "$dir/build" install > "$dir/logs/install.log" 2>&1 || { tail -30 "$dir/logs/install.log"; exit 1; }
nice -n 10 ninja -C "$dir/build" PythonInstall > "$dir/logs/python.log" 2>&1 || { tail -30 "$dir/logs/python.log"; exit 1; }
cd /
"$dir/venv/bin/python" - "$dir" <<'PY'
import os, sys
import openmm
names = sorted(openmm.Platform.getPlatform(i).getName() for i in range(openmm.Platform.getNumPlatforms()))
print(openmm.__file__, openmm.version.git_revision, names)
assert openmm.__file__.startswith(sys.argv[1] + "/venv/"), "openmm imported from outside the venv"
assert names == ["CPU", "Metal", "OpenCL", "Reference"], "a platform failed to load: " + str(openmm.Platform.getPluginLoadFailures())
PY
hash="$(/tmp/openmm-metal-bench/ultra-tools/srchash.sh "$dir")"
printf 'commit %s\nsrc %s\ntoolchain %s\nbuilt %s\n' "$(cat "$dir/src/.commit" 2>/dev/null || echo unknown)" "$hash" "$toolchain" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/BUILT"
echo "built $dir"
cat "$dir/BUILT"
