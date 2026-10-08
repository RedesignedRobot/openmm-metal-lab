set -eu
cd '/tmp/openmm-metal-bench/ultra-nonbonded-xres'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 761d5a666104d03ad9a218f04ca5a632e0466fbe > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-nonbonded-xres/src is 761d5a666104d03ad9a218f04ca5a632e0466fbe, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
