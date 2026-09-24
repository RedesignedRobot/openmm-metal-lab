#!/bin/sh
# Counts how far platforms/metal is from a mechanically renamed copy of platforms/hip.
# usage: delta.sh <openmm repo> [ref]   (ref defaults to HEAD; "-" reads the working tree)
# Prints, per file, the lines diff -w adds relative to the renamed HIP file,
# then the files that exist only in Metal with their full line counts, then the HIP files Metal
# dropped. Removed lines never count. The last line counts all of platforms/metal the same way,
# CMake files and tests included.
set -eu
repo="$1"
ref="${2:-HEAD}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
if [ "$ref" = "-" ]; then
  (cd "$repo" && tar -cf - platforms/hip platforms/metal) | tar -x -C "$work"
else
  git -C "$repo" archive "$ref" platforms/hip platforms/metal | tar -x -C "$work"
fi
hip="$work/platforms/hip"
metal="$work/platforms/metal"
renamed="$work/renamed"
for dir in src src/kernels include; do
  mkdir -p "$renamed/$dir"
  for f in "$hip/$dir"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f" | sed 's/Hip/Metal/; s/\.hip$/.metal/')"
    cp "$f" "$renamed/$dir/$name"
  done
done
find "$renamed" -type f -exec perl -pi -e 's/Hip/Metal/g; s/HIP/METAL/g; s/\bhip/metal/g' {} +
shared=0
only=0
printf '%-45s %7s %7s\n' file added removed
for dir in src src/kernels include; do
  for f in "$metal/$dir"/*; do
    [ -f "$f" ] || continue
    rel="$dir/$(basename "$f")"
    if [ -f "$renamed/$rel" ]; then
      added=$(diff -w "$renamed/$rel" "$f" | grep -c '^>' || true)
      removed=$(diff -w "$renamed/$rel" "$f" | grep -c '^<' || true)
      shared=$((shared + added))
      printf '%-45s %7d %7d\n' "$rel" "$added" "$removed"
    fi
  done
done
echo
printf '%-45s %7s\n' "metal-only file" lines
for dir in src src/kernels include; do
  for f in "$metal/$dir"/*; do
    [ -f "$f" ] || continue
    rel="$dir/$(basename "$f")"
    if [ ! -f "$renamed/$rel" ]; then
      lines=$(wc -l < "$f" | tr -d ' ')
      only=$((only + lines))
      printf '%-45s %7d\n' "$rel" "$lines"
    fi
  done
done
echo
printf '%-45s %7s\n' "hip file with no metal counterpart" lines
for dir in src src/kernels include; do
  for f in "$renamed/$dir"/*; do
    [ -f "$f" ] || continue
    rel="$dir/$(basename "$f")"
    [ -f "$metal/$rel" ] || printf '%-45s %7d\n' "$rel" "$(wc -l < "$f" | tr -d ' ')"
  done
done
echo
printf '%-45s %7d\n' "added lines in shared files" "$shared"
printf '%-45s %7d\n' "lines in metal-only files" "$only"
full="$work/full"
cp -R "$hip" "$full"
find "$full" -type f -name '*Hip*' | while read -r f; do mv "$f" "$(dirname "$f")/$(basename "$f" | sed 's/Hip/Metal/')"; done
find "$full" -type f -name '*.hip' | while read -r f; do mv "$f" "${f%.hip}.metal"; done
find "$full" -type f -exec perl -pi -e 's/Hip/Metal/g; s/HIP/METAL/g; s/\bhip/metal/g' {} +
printf '%-45s %7d\n' "added lines in all of platforms/metal" "$(diff -rwN "$full" "$metal" | grep -c '^>' || true)"
