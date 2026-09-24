#!/bin/sh
# Runs on the laptop: puts one commit's tree into <studio dir>/src on the M3 Ultra and checks every
# file against git. Only files whose contents changed are rewritten, so ninja rebuilds only what the
# commit touched. src/.commit records the commit.
# usage: sync.sh <worktree> <commit> <studio dir>
#   sync.sh /Users/amir/code/mini/ultra-pme HEAD /tmp/openmm-metal-bench/ultra-pme
set -eu
[ $# -eq 3 ] || { echo "usage: sync.sh <worktree> <commit> <studio dir>" >&2; exit 2; }
worktree="$1"
dir="$3"
case "$dir" in
/tmp/openmm-metal-bench/ultra-*) ;;
*) echo "the studio dir must be /tmp/openmm-metal-bench/ultra-<lane>, not $dir" >&2; exit 2 ;;
esac
. "$(dirname "$0")/../hosts.env"
commit="$(git -C "$worktree" rev-parse --verify "$2^{commit}")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$worktree" archive --format=tar.gz -o "$tmp/src.tar.gz" "$commit"
# Symlinks (mode 120000) are left out: git hash-object would hash their targets.
git -C "$worktree" ls-tree -r "$commit" | awk -F '\t' '{ split($1, m, " "); if (m[1] != "120000") print m[3] "\t" $2 }' > "$tmp/blobs.txt"
retry() {
    for attempt in 1 2 3 4 5; do
        "$@" && return 0
        echo "attempt $attempt failed: $*" >&2
        sleep 5
    done
    return 1
}
retry timeout 60 ssh -o ConnectTimeout=15 "$STUDIO" "mkdir -p '$dir'"
cat > "$tmp/unpack.sh" <<EOF
set -eu
cd '$dir'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo $commit > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=\$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '\$1 != \$2 { print \$3 }')
[ -z "\$mismatch" ] || { echo "files differ from git: \$mismatch" >&2; exit 1; }
echo "$dir/src is $commit, \$(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
EOF
retry timeout 600 rsync --partial --inplace -e "ssh -o ConnectTimeout=15" "$tmp/src.tar.gz" "$tmp/blobs.txt" "$tmp/unpack.sh" "$STUDIO:$dir/"
retry timeout 600 ssh -o ConnectTimeout=15 "$STUDIO" "/bin/sh '$dir/unpack.sh'"
