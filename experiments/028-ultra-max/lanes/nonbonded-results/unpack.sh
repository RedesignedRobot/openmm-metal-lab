set -eu
cd '/tmp/openmm-metal-bench/ultra-nonbonded'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 6d72c3ae9bbd0945c70994e01d95398bbb3d64f7 > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-nonbonded/src is 6d72c3ae9bbd0945c70994e01d95398bbb3d64f7, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
