#!/bin/sh
# Creates plugins/<plugin>/platforms/metal from platforms/hip with experiment 024's renames:
# Hip to Metal and .hip to .metal in file names, then Hip to Metal, HIP to METAL and hip to metal
# in the text. Run from the root of an OpenMM checkout.
# usage: port.sh <plugin>
set -eu
src="plugins/$1/platforms/hip"
dst="plugins/$1/platforms/metal"
[ -d "$src" ] || { echo "no $src" >&2; exit 1; }
[ -e "$dst" ] && { echo "$dst exists" >&2; exit 1; }
cp -R "$src" "$dst"
find "$dst" -type f -name '*Hip*' | while read -r f; do mv "$f" "$(dirname "$f")/$(basename "$f" | sed 's/Hip/Metal/')"; done
find "$dst" -type f -name '*.hip' | while read -r f; do mv "$f" "${f%.hip}.metal"; done
find "$dst" -type f -exec perl -pi -e 's/Hip/Metal/g; s/HIP/METAL/g; s/\bhip/metal/g' {} +
find "$dst" -type f | sort
