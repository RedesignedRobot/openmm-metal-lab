#!/bin/sh
# fake build.sh: marks the tree and idles
echo $$ > "$2/.build.sh.pid"
while :; do sleep 1; done
