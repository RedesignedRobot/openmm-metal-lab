set -eu
cd '/tmp/openmm-metal-bench/ultra-pme/cand'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo c5f2cb6ed6375bdcf0e04747f01b7a6630ed71e9 > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-pme/cand/src is c5f2cb6ed6375bdcf0e04747f01b7a6630ed71e9, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
