#!/bin/sh
# Run lease-sized blocks one after another, each under its own lease, with a pause between blocks so
# the other lanes waiting on the lease can take it.
# usage: chain.sh <blocks-file>
# Each line of <blocks-file> is "<what> <command...>"; blank lines and lines starting with # are skipped.
here=$(cd "$(dirname "$0")" && pwd)
grep -v '^#' "$1" | grep -v '^ *$' | while read -r what cmd; do
    sh "$here/leased.sh" "$what" sh -c "$cmd" < /dev/null
    sleep "${PAUSE:-60}"
done
echo "CHAIN-DONE $1"
