#!/bin/sh
# Sync a local source tree to the Mac mini and run a command inside it.
# usage: mini.sh <local-tree> <command...>
# The tree lands at ~/lab/<basename> on the mini. build/ and .git stay out of the sync,
# so the remote build directory survives between runs and ccache stays warm.
# The lab scripts land in ~/lab/bin, which is on PATH for the command.
set -eu
MINI="${MINI:-amir@10.10.10.11}"
here="$(cd "$(dirname "$0")" && pwd)"
tree="$1"
shift
name="$(basename "$tree")"
ssh -o BatchMode=yes "$MINI" "mkdir -p lab/bin lab/$name"
rsync -az "$here/build-openmm.sh" "$here/bench.sh" "$MINI:lab/bin/"
rsync -az --delete --exclude .git --exclude build "$tree/" "$MINI:lab/$name/"
ssh -o BatchMode=yes "$MINI" "export PATH=\$HOME/lab/bin:\$HOME/lab/venv/bin:/opt/homebrew/bin:\$PATH; cd lab/$name && $*"
