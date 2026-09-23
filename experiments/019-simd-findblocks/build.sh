#!/bin/sh
# Runs on the mini.  Builds and installs the two trees of experiment 019 one after the other
# (8 GB of RAM), each into ~/lab/prefix-<tree> and its own venv ~/lab/venv-<tree>, with
# ~/lab/bin/build-openmm.sh, the same method as every other lab install.
# CCACHE_BASEDIR makes the second tree reuse the first tree's objects for unchanged sources.
# Launch detached from sh:  sh -c "nohup sh build.sh > build.log 2>&1 &"
set -eu
export PATH="$HOME/lab/bin:/opt/homebrew/bin:$PATH"
export CCACHE_BASEDIR="$HOME/lab"
out="$HOME/lab/simd-019"
for tree in openmm-simd-base openmm-simd; do
    cd "$HOME/lab/$tree"
    start=$(date +%s)
    build-openmm.sh -DPYTHON_EXECUTABLE="$HOME/lab/venv-$tree/bin/python" > "$out/build-$tree.log" 2>&1
    echo "$tree BUILD_OK $(( $(date +%s) - start )) s" >> "$out/build.status"
done
echo ALL_OK >> "$out/build.status"
