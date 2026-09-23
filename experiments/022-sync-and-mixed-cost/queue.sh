#!/bin/sh
# Run block files one after another through chain.sh, after process <pid> (an earlier chain) exits.
# usage: queue.sh <pid> <blocks-file>...
here=$(cd "$(dirname "$0")" && pwd)
pid=$1; shift
while kill -0 "$pid" 2>/dev/null; do sleep 20; done
for blocks in "$@"; do
    sh "$here/chain.sh" "$blocks"
done
echo "QUEUE-DONE"
