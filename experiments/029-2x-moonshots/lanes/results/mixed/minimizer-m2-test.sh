#!/bin/sh
set -eu
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
M=$HOME/lab/ultra-m2.noindex/cand-m29-mixed-minimizer-source-b60e2c40f9
export OPENMM_PLUGIN_DIR="$M/prefix/lib/plugins"
ctest --test-dir "$M/build" --no-tests=error --output-on-failure -R '^TestMetalLocalEnergyMinimizerMixed$'
