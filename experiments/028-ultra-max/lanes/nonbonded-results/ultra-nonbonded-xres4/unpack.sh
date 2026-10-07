set -eu
cd '/tmp/openmm-metal-bench/ultra-nonbonded-xres4'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo dcf45d451fa9e37a603ac816c624a64cc739bc1d > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-nonbonded-xres4/src is dcf45d451fa9e37a603ac816c624a64cc739bc1d, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
