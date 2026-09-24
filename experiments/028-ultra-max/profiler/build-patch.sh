#!/bin/sh
# Runs on the M3 Ultra: builds the profiling tree plus one patch into its own prefix, then restores the tree.
# usage: build-patch.sh <patch file, -p1> <prefix dir name under ultra-profiler>
# Only the OpenMMMetal target is rebuilt. cmake --install into a separate prefix strips the build-tree rpath, so the
# patched plugin loads against the venv's libOpenMM. Run the patched build with OPENMM_PLUGIN_DIR=<prefix>/lib/plugins.
# cmake reruns after the patch and after the revert, because the kernel list is globbed at configure time
# (platforms/metal/CMakeLists.txt:89) and a patch may add or remove a .metal file. The revert deletes added files (-E)
# and the generated MetalKernelSources files: ninja doesn't rerun a step when one of its inputs is only removed.
set -e
D=/tmp/openmm-metal-bench/ultra-profiler
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
patch_file="$1"; out="$D/$2"
cd "$D/src"
patch -p1 --dry-run < "$patch_file" > /dev/null
patch -p1 < "$patch_file"
trap 'cd "$D/src" && patch -p1 -R -E < "$patch_file" > /dev/null && cmake build-xb > /dev/null 2>&1 && rm -f build-xb/platforms/metal/src/MetalKernelSources.cpp build-xb/platforms/metal/src/MetalKernelSources.h && nice -n 10 ninja -C build-xb -j6 OpenMMMetal > /dev/null && echo "restored $(date -u +%H:%M:%SZ)"' EXIT
cmake build-xb > "$out.cmake.log" 2>&1
nice -n 10 ninja -C build-xb -j6 OpenMMMetal > "$out.build.log" 2>&1 || { grep -E "error|FAILED" "$out.build.log" | head -20; exit 1; }
cmake --install build-xb --prefix "$out" > /dev/null
OPENMM_PLUGIN_DIR="$out/lib/plugins" "$D/venv/bin/python" -c "import openmm as m; print([m.Platform.getPlatform(i).getName() for i in range(m.Platform.getNumPlatforms())])"
echo "BUILD_DONE $out $(date -u +%H:%M:%SZ)"
