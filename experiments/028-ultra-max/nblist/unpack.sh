set -eu
cd '/tmp/openmm-metal-bench/ultra-nblist'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo ec464a4845a1001e8b0798069383c51af6a68789 > .stage/.commit
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
cd src
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git: $mismatch" >&2; exit 1; }
echo "/tmp/openmm-metal-bench/ultra-nblist/src is ec464a4845a1001e8b0798069383c51af6a68789, $(wc -l < ../blobs.txt | tr -d ' ') files checked against git"
