#!/bin/sh
# Runs on the M2: configures, builds and installs <dir>/src (put there by m2sync.sh) the way the
# M3 Ultra's build.sh builds ultra-base: Xcode-beta's toolchain, Release, Metal, OpenCL, CPU and
# Reference on, Python wrappers and tests on, C and Fortran wrappers and examples off. It adds ccache
# (cache in /Users/amir/lab/ultra-m2/ccache, keyed on the compiler's --version under Xcode-beta) and
# builds at nice 10 with 4 jobs, 3 when another build runs, 2 when memory is short. The build dir is
# kept, so a later commit synced into the same src rebuilds only what changed. It makes <dir>/build,
# <dir>/prefix and <dir>/venv (Homebrew python3 with numpy, scipy, Cython and setuptools from pip,
# inside the venv only), checks that all four platforms load from the venv and from this prefix, and
# writes <dir>/BUILT with the commit, a hash of src, the toolchain and the step times.
# Launch detached:
#   /bin/sh -c 'nohup /Users/amir/lab/ultra-m2/tools/m2build.sh /Users/amir/lab/ultra-m2/cand > /Users/amir/lab/ultra-m2/cand/build.out 2>&1 < /dev/null &'
# The last line of the output is "built <dir>" or "BUILD FAILED".
# usage: m2build.sh <dir>
set -eu
[ $# -eq 1 ] || { echo "usage: m2build.sh <dir>" >&2; exit 2; }
dir="${1%/}"
ROOT=/Users/amir/lab/ultra-m2
case "$dir" in
"$ROOT"/*) ;;
*) echo "the dir must be under $ROOT, not $dir" >&2; exit 2 ;;
esac
trap '[ $? = 0 ] || echo "BUILD FAILED"' EXIT
BUILDS='clang|clang\+\+|ninja|cc1plus'
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export CCACHE_DIR="$ROOT/ccache" CCACHE_BASEDIR="$ROOT" CCACHE_MAXSIZE=5G CCACHE_COMPILERCHECK='%compiler% --version'
unset PYTHONPATH OPENMM_PLUGIN_DIR DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
case "$(xcrun --find clang 2>/dev/null)" in
"$DEVELOPER_DIR"/*) ;;
*) echo "xcrun doesn't find clang in $DEVELOPER_DIR; is Xcode-beta installed?" >&2; exit 2 ;;
esac
sdk="$(xcrun --show-sdk-path)"
case "$sdk" in "$DEVELOPER_DIR"/*) ;; *) echo "the SDK $sdk is not Xcode-beta's" >&2; exit 2 ;; esac
toolchain="$(xcrun clang --version | head -1), $(xcodebuild -version | tr '\n' ' ' | sed 's/ $//'), SDK $sdk"
[ -f "$dir/src/CMakeLists.txt" ] || { echo "$dir/src has no CMakeLists.txt; run m2sync.sh first" >&2; exit 2; }
now() { date +%s; }
free_pct() { memory_pressure -Q | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p'; }
rm -f "$dir/BUILT"
mkdir -p "$dir/logs"
if [ -f "$dir/build/CMakeCache.txt" ] && ! grep -qx "CMAKE_OSX_SYSROOT:STRING=$sdk" "$dir/build/CMakeCache.txt" \
    && ! grep -qx "CMAKE_OSX_SYSROOT:PATH=$sdk" "$dir/build/CMakeCache.txt"; then
    echo "$dir/build was configured with another SDK; removing it"
    rm -rf "$dir/build"
fi
t0=$(now)
if [ ! -x "$dir/venv/bin/python" ]; then
    /opt/homebrew/bin/python3 -m venv "$dir/venv"
    "$dir/venv/bin/python" -m pip install -q --disable-pip-version-check numpy scipy Cython setuptools > "$dir/logs/pip.log" 2>&1 \
        || { tail -20 "$dir/logs/pip.log"; exit 1; }
fi
t_venv=$(( $(now) - t0 ))

# Memory first: wait up to 10 minutes for 25% free, then pick the job count.
waited=0
while [ "$(free_pct)" -lt 25 ] && [ $waited -lt 600 ]; do sleep 15; waited=$((waited+15)); done
jobs=4
others="$(pgrep -x "$BUILDS" | wc -l | tr -d ' ')"
[ "$others" -gt 0 ] && jobs=3
[ "$(free_pct)" -lt 25 ] && jobs=2
echo "$(date -u +%H:%M:%SZ) memory free $(free_pct)%, $others other build processes, load $(sysctl -n vm.loadavg), -j$jobs"

ccache -z > /dev/null
t0=$(now)
nice -n 10 cmake -S "$dir/src" -B "$dir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$dir/prefix" \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DPYTHON_EXECUTABLE="$dir/venv/bin/python" \
    -DOPENMM_BUILD_METAL_LIB=ON \
    -DOPENMM_BUILD_OPENCL_LIB=ON \
    -DOPENMM_BUILD_CPU_LIB=ON \
    -DOPENMM_BUILD_PYTHON_WRAPPERS=ON \
    -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF \
    -DOPENMM_BUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=ON \
    > "$dir/logs/configure.log" 2>&1 || { tail -30 "$dir/logs/configure.log"; exit 1; }
grep -Eqx "CMAKE_OSX_SYSROOT:(STRING|PATH)=$sdk" "$dir/build/CMakeCache.txt" || { echo "cmake didn't pick up $sdk" >&2; exit 1; }
t_configure=$(( $(now) - t0 ))
t0=$(now)
nice -n 10 ninja -C "$dir/build" -j $jobs > "$dir/logs/build.log" 2>&1 \
    || { grep -E "error|FAILED" "$dir/logs/build.log" | head -20; exit 1; }
t_ninja=$(( $(now) - t0 ))
edges="$(grep -c '^\[' "$dir/logs/build.log" || true)"
t0=$(now)
nice -n 10 ninja -C "$dir/build" install > "$dir/logs/install.log" 2>&1 || { tail -30 "$dir/logs/install.log"; exit 1; }
# setup.py compiles the SWIG wrapper with the compiler in CC, so ccache covers it too.
CC="ccache clang" CXX="ccache clang++" nice -n 10 ninja -C "$dir/build" PythonInstall > "$dir/logs/python.log" 2>&1 \
    || { tail -30 "$dir/logs/python.log"; exit 1; }
t_install=$(( $(now) - t0 ))
cd /
"$dir/venv/bin/python" - "$dir" <<'PY'
import sys
import openmm
from openmm import version
names = sorted(openmm.Platform.getPlatform(i).getName() for i in range(openmm.Platform.getNumPlatforms()))
print(openmm.__file__, version.git_revision, version.openmm_library_path, names)
assert openmm.__file__.startswith(sys.argv[1] + "/venv/"), "openmm imported from outside the venv"
assert version.openmm_library_path == sys.argv[1] + "/prefix/lib", "openmm_library_path is not this prefix"
assert names == ["CPU", "Metal", "OpenCL", "Reference"], "a platform failed to load: " + str(openmm.Platform.getPluginLoadFailures())
PY
hash="$(cd "$dir/src" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum | cut -c1-40)"
printf 'commit %s\nsrc %s\ntoolchain %s\nbuilt %s\nsteps venv %ss, configure %ss, ninja -j%s %ss (%s edges), install+python %ss\n' \
    "$(cat "$dir/src/.commit" 2>/dev/null || echo unknown)" "$hash" "$toolchain" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$t_venv" "$t_configure" "$jobs" "$t_ninja" "$edges" "$t_install" > "$dir/BUILT"
cat "$dir/BUILT"
ccache -s 2>/dev/null | grep -E '^ *(Hits|Misses):' | head -2 || true
echo "built $dir"
