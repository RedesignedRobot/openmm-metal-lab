set -eu
cd '/tmp/openmm-metal-bench/ultra-plugins/head'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 95373278b69eb95437f6b9f5c5d901568676b17f > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-plugins/head/src is 95373278b69eb95437f6b9f5c5d901568676b17f, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
