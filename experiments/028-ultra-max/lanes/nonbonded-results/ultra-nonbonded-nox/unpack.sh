set -eu
cd '/tmp/openmm-metal-bench/ultra-nonbonded-nox'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 626652d2c613bb356aeda82a352a97babb8874ee > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-nonbonded-nox/src is 626652d2c613bb356aeda82a352a97babb8874ee, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
