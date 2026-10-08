set -eu
cd '/tmp/openmm-metal-bench/ultra-plugins/cand'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 6aac90ee3b4a1ccccdc4f724f909974eced67fa7 > .stage/.commit
cd .stage
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git, src left as it was: $mismatch" >&2; exit 1; }
cd ..
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
echo "/tmp/openmm-metal-bench/ultra-plugins/cand/src is 6aac90ee3b4a1ccccdc4f724f909974eced67fa7, $(wc -l < blobs.txt | tr -d ' ') files checked against git"
