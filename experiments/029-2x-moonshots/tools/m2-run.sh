#!/bin/sh
# Run only through locked.py: transfer, build and checks share one M2 lock.
set -eu
ROOT=$HOME/lab/ultra-m2.noindex
upload=$1
tree=$ROOT/$2
shift 2
if [ "$tree" != "$ROOT/base" ]; then
    [ "$(sed -n 's/^commit //p' "$ROOT/base/BUILT")" = 8ae6cf17bef6a6084f4f0d12fa6aa5705dd73374 ] || { echo "M2 base is not 8ae6cf17b" >&2; exit 2; }
    [ -f "$ROOT/BASE_READY" ] || { echo "M2 forces baseline is not ready" >&2; exit 2; }
else
    rm -f "$ROOT/BASE_READY"
fi
mkdir -p "$upload/stage" "$tree/src"
tar -xzf "$upload/src.tar.gz" -C "$upload/stage"
/opt/homebrew/bin/python3 "$ROOT/tools/m2-verify.py" "$upload/stage"
rsync -rlpc --delete "$upload/stage/src/" "$tree/src/"
cp "$upload/stage/blobs.txt" "$tree/blobs.txt"
/opt/homebrew/bin/python3 "$ROOT/tools/m2-verify.py" "$tree"
"$ROOT/tools/m2build.sh" "$tree"
if [ "$tree" = "$ROOT/base" ]; then
    mkdir -p "$tree/benchmarks"
    rsync -rlpc "$tree/src/examples/benchmarks/" "$tree/benchmarks/"
    "$ROOT/tools/m2check.sh" --baseline
    cp "$tree/BUILT" "$ROOT/BASE_READY.new"
    mv "$ROOT/BASE_READY.new" "$ROOT/BASE_READY"
else
    "$ROOT/tools/m2check.sh" "$@" "$tree"
fi
