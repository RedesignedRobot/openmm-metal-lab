#!/bin/sh
# Prints a hash of every file under <dir>/src. build.sh records it in <dir>/BUILT; gate.sh and ab.sh
# compare it with the tree as it is now.
# usage: srchash.sh <dir>
set -eu
cd "$1/src"
find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum | cut -c1-40
