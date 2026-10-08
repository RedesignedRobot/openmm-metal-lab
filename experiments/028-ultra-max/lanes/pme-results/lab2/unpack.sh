set -eu
cd '/tmp/openmm-metal-bench/ultra-pme/lab2'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo bf09b5e99062173f048b0e828438aff31550d96d > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-pme/lab2/src is bf09b5e99062173f048b0e828438aff31550d96d, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
