#!/bin/sh
# Runs on the mini under the lease: step 1 (Langevin mixed reruns on the two 024 builds), then the
# venvs and the screening build (Metal only, no tests) with temporary FB_* knobs.
# usage: phase1.sh
t="$HOME/lab/fast/tools"
out="$HOME/lab/fast/out"
mkdir -p "$out"
echo "start $(date -u +%H:%M:%SZ) load $(sysctl -n vm.loadavg)"
sh "$t/langevin.sh" > "$out/langevin.txt" 2>&1
cat "$out/langevin.txt"
sh "$t/mkvenv.sh" "$HOME/lab/fast/scr/venv" || exit 1
sh "$t/mkvenv.sh" "$HOME/lab/fast/venv-base" || exit 1
cp -R "$HOME/lab/hipdelta/build/venv/lib/python3.13/site-packages/openmm" \
      "$HOME/lab/hipdelta/build/venv/lib/python3.13/site-packages/simtk" \
      "$HOME/lab/hipdelta/build/venv/lib/python3.13/site-packages/OpenMM-8.6.0-py3.13.egg-info" \
      "$HOME/lab/fast/venv-base/lib/python3.13/site-packages/" || exit 1
sh "$t/build.sh" "$HOME/lab/fast/scr" -DBUILD_TESTING=OFF -DOPENMM_BUILD_OPENCL_LIB=OFF \
    -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF || exit 1
echo "end $(date -u +%H:%M:%SZ)"
