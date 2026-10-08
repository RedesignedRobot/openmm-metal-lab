set -eu
cd '/tmp/openmm-metal-bench/ultra-pme/cand2'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 17929e631e15235aecc240d82b973199a09a8add > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-pme/cand2/src is 17929e631e15235aecc240d82b973199a09a8add, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
