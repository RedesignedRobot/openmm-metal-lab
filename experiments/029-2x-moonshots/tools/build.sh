#!/bin/sh
# Runs on the M3 Ultra: configures, builds and installs the tree in <dir>/src (put there by sync.sh)
# the way ultra-base is built: Xcode-beta's toolchain, Release, Metal, OpenCL, Python and tests on,
# C and Fortran wrappers off. Builds use normal policy, nice 10 and eight jobs.
# A timing hold pauses registered ninja phases (SIGSTOP, then SIGCONT at its release), and no configure or
# ninja phase starts while one is up, the same as for a dedicated window. After a hold, the next timing
# hold waits up to 15 minutes for the builds that were paused or waiting. It makes <dir>/build,
# <dir>/prefix and <dir>/venv, whose python imports this tree's openmm and sees numpy, scipy, Cython
# and setuptools from the shared env. A build dir configured with another SDK is removed and
# configured again; prefix stays until the install overwrites it, so runs of the old build keep
# working until the last minute. It ends by writing <dir>/BUILT with a hash of src and the
# compiler, which gate.sh and ab.sh check so nobody tests a stale build. Logs go to <dir>/logs.
# Launch detached, since a build outlives a flaky ssh:
#   ultra-tools/bg.sh ultra-<lane>/build.out ultra-tools/build.sh /tmp/openmm-metal-bench/ultra-<lane>
# usage: build.sh <dir>
set -eu
if [ "${1:-}" != --locked ]; then
    [ $# -eq 1 ] || { echo "usage: build.sh <dir>" >&2; exit 2; }
    exec /tmp/openmm-metal-bench/env/bin/python3 /tmp/openmm-metal-bench/ultra-tools/locked.py "$1/.build.lock" "$0" --locked "$1"
fi
shift
[ $# -eq 1 ] || { echo "usage: build.sh <dir>" >&2; exit 2; }
dir="${1%/}"
case "$dir" in
/tmp/openmm-metal-bench/ultra-*) ;;
*) echo "the dir must be /tmp/openmm-metal-bench/ultra-<lane>, not $dir" >&2; exit 2 ;;
esac
[ ! -e "$dir/PINNED" ] || { echo "refusing to rebuild pinned $dir" >&2; exit 2; }
ENV=/tmp/openmm-metal-bench/env
# Under gpuqd (its socket is up and /tmp/openmm-metal-bench/gpuq/OFF is absent) the build is a gpuq build
# job: it starts when no timing job or window runs, and gpuqd stops its process group and every compile
# under it while one does. The waits below then find nothing to wait for.
if [ -z "${GPUQ_JOB:-}" ] && [ -S /tmp/openmm-gpuq.sock ] && [ ! -e /tmp/openmm-metal-bench/gpuq/OFF ]; then
    exec "$ENV/bin/python3" /tmp/openmm-metal-bench/ultra-tools/gpuq/gpuq hold --class build \
        --lane "${dir##*/ultra-}" --what "build.sh $dir" -- "$0" --locked "$dir"
fi
WINDOW=/tmp/openmm-window
POLICY=/tmp/openmm-metal-bench/ultra-tools/build-policy.py
# Marks this build as pending while it waits or builds: after a timing hold, the next one waits up to 15
# minutes for it (the build gap in build-policy.py).
echo $$ > "$dir/.build.sh.pid"
trap 'rm -f "$dir/.build.sh.pid"' EXIT
SITE=$ENV/lib/python3.13/site-packages
JOBS=8
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=$ENV/bin:$PATH
unset PYTHONPATH
# The cache is installed by infra after READY; existing builds keep their loaded configuration.
cache_args=""
if [ -x "$ENV/bin/ccache" ]; then
    export CCACHE_BASEDIR=/tmp/openmm-metal-bench CCACHE_NOHASHDIR=1
    export CCACHE_DIR=/tmp/openmm-metal-bench/ccache CCACHE_COMPILERCHECK=content
    cache_args="-DCMAKE_C_COMPILER_LAUNCHER=$ENV/bin/ccache -DCMAKE_CXX_COMPILER_LAUNCHER=$ENV/bin/ccache"
fi
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
# A timing hold (lease.sh without --correctness) pauses builds, so none starts while one is up.
# build-policy.py active is false inside the hold itself, so a build run from its own hold can't deadlock.
wait_for_timing() {
    told_hold=""
    while python3 "$POLICY" active; do
        [ -n "$told_hold" ] || echo "$(date -u +%H:%M:%SZ) waiting for the timing hold to end: $(cat /tmp/openmm-lease/owner 2>/dev/null)"
        told_hold=1
        sleep 10
    done
}
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
wait_for_timing
nice -n 10 cmake -S "$dir/src" -B "$dir/build" -G Ninja $cache_args \
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
# Register every ninja phase so a timing hold pauses it, including one that starts as the hold begins.
run_ninja() {
    log=$1
    shift
    wait_for_timing
    # Keep PWD on the public symlink path so ccache rewrites source paths to ../src.
    PWD="$dir/build" nice -n 10 ninja -C "$dir/build" "$@" > "$dir/logs/$log" 2>&1 &
    ninja_pid=$!
    python3 "$POLICY" register "$dir" "$ninja_pid"
    result=0
    wait "$ninja_pid" || result=$?
    python3 "$POLICY" unregister "$dir" "$ninja_pid"
    [ "$result" = 0 ] || { tail -30 "$dir/logs/$log"; return "$result"; }
}
run_ninja build.log -j "$JOBS"
run_ninja install.log install
run_ninja python.log PythonInstall
cd /
"$dir/venv/bin/python" - "$dir" <<'PY'
import os, sys
import openmm
names = sorted(openmm.Platform.getPlatform(i).getName() for i in range(openmm.Platform.getNumPlatforms()))
print(openmm.__file__, openmm.version.git_revision, names)
assert os.path.realpath(openmm.__file__).startswith(os.path.realpath(sys.argv[1]) + "/venv/"), "openmm imported from outside the venv"
assert names == ["CPU", "Metal", "OpenCL", "Reference"], "a platform failed to load: " + str(openmm.Platform.getPluginLoadFailures())
PY
hash="$(/tmp/openmm-metal-bench/ultra-tools/srchash.sh "$dir")"
printf 'commit %s\nsrc %s\ntoolchain %s\nbuilt %s\n' "$(cat "$dir/src/.commit" 2>/dev/null || echo unknown)" "$hash" "$toolchain" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/BUILT"
echo "built $dir"
cat "$dir/BUILT"
