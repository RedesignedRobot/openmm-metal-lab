set -eu
cd '/tmp/openmm-metal-bench/ultra-infra-synctest'
rm -rf .stage
mkdir .stage
tar -xzf src.tar.gz -C .stage
echo 89d7f17fc471bfc39109c9f90b7754fae2aff7d9 > .stage/.commit
cd .stage
mismatch=$(cut -f2 ../blobs.txt | git hash-object --stdin-paths | paste - ../blobs.txt | awk -F '\t' '$1 != $2 { print $3 }')
[ -z "$mismatch" ] || { echo "files differ from git, src left as it was: $mismatch" >&2; exit 1; }
cd ..
mkdir -p src
rsync -rlpc --delete .stage/ src/
rm -rf .stage
echo "/tmp/openmm-metal-bench/ultra-infra-synctest/src is 89d7f17fc471bfc39109c9f90b7754fae2aff7d9, $(wc -l < blobs.txt | tr -d ' ') files checked against git"
