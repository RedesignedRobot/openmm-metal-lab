set -eu
cd '/tmp/openmm-metal-bench/ultra-pme/cand3'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 5bfc934b622ca4950bc585953de03bd41ee12a4c > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-pme/cand3/src is 5bfc934b622ca4950bc585953de03bd41ee12a4c, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
