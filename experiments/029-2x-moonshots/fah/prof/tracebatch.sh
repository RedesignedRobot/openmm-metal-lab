#!/bin/sh
# One gpuq timing job (r3-fah): shader timelines of the FAH units and pme45k, Metal mixed and single against OpenCL
# single. usage: tracebatch.sh <fresh out dir> <build dir> <corpus dir> [seconds]
# Submit: gpuq submit --class timing --lane r3-fah --est 30m --cap 60m -- sh tracebatch.sh <out> <tree> <corpus>
set -u
out=$1 tree=$2 corpus=$3 seconds=${4:-1}
here=$(cd "$(dirname "$0")" && pwd)
[ ! -e "$out" ] || { echo "refusing: $out exists"; exit 1; }
mkdir -p "$out"
failed=0
while read -r tag platform precision wu variants; do
    [ -n "$tag" ] || continue
    PLATFORM=$platform PRECISION=$precision sh "$here/tracewu.sh" "$out" "$tag" "$corpus/$wu" "$tree" "$seconds" $variants \
        || { echo "FAILED $tag"; failed=$((failed + 1)); }
done <<EOF
m-gbsa Metal mixed gbsa
o-gbsa OpenCL single gbsa
m-gbsa-obc Metal mixed gbsa obc
o-gbsa-obc OpenCL single gbsa obc
s-gbsa Metal single gbsa
m-tip3p Metal mixed tip3p-hmr
o-tip3p OpenCL single tip3p-hmr
s-tip3p Metal single tip3p-hmr
m-tip4p Metal mixed tip4pew
o-tip4p OpenCL single tip4pew
m-neq Metal mixed neq
o-neq OpenCL single neq
m-pme45k Metal mixed pme45k
o-pme45k OpenCL single pme45k
EOF
echo "tracebatch done $(date -u +%H:%M:%SZ), $failed failed"
[ $failed = 0 ]
