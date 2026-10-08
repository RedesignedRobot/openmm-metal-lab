set -eu
cd '/tmp/openmm-metal-bench/ultra-pme/ob-pass'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo a7d76b55dcbecf8ef4d194ad9a95cc5accdf6ddb > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-pme/ob-pass/src is a7d76b55dcbecf8ef4d194ad9a95cc5accdf6ddb, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
