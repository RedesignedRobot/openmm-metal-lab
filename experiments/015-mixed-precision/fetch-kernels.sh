#!/bin/sh
# Export OpenMM's Common kernel sources at the pinned commit into openmm-kernels/ (gitignored),
# so the census reads the same files on every machine. Run on the Mac that holds the checkout.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
repo="${OPENMM_REPO:-$HOME/code/mini/openmm-metal}"
commit="${OPENMM_COMMIT:-3c9effc96}"
rm -rf "$here/openmm-kernels"
mkdir -p "$here/openmm-kernels"
git -C "$repo" archive "$commit" platforms/common/src/kernels | tar -x -C "$here/openmm-kernels" --strip-components=4
git -C "$repo" rev-parse "$commit" > "$here/openmm-kernels/COMMIT"
ls "$here/openmm-kernels" | wc -l
