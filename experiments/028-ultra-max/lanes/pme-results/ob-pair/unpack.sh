set -eu
cd '/tmp/openmm-metal-bench/ultra-pme/ob-pair'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo e24a8c4b64cd4936fc5d9aa8ff29f3b7b2c6dd2a > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-pme/ob-pair/src is e24a8c4b64cd4936fc5d9aa8ff29f3b7b2c6dd2a, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
