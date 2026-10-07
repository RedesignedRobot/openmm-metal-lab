set -eu
cd '/tmp/openmm-metal-bench/ultra-plugins/prec'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 1f29eafe15a507b0fef84fbb04b952112f68f2fb > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-plugins/prec/src is 1f29eafe15a507b0fef84fbb04b952112f68f2fb, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
