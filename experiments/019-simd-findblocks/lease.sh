# Shared machine lease: hold it around every build and every GPU run or timed measurement.
# Sourced by pipeline.sh and fb.sh; run.py has the same two functions.
LEASE=/tmp/openmm-lease
LEASE_OWNER=simd-findblocks-019
lease() {
    until mkdir "$LEASE" 2>/dev/null; do sleep 20; done
    echo "$LEASE_OWNER $(date -u +%H:%MZ) $1" > "$LEASE/owner"
}
unlease() {
    if grep -q "^$LEASE_OWNER " "$LEASE/owner" 2>/dev/null; then rm -rf "$LEASE"; fi
}
trap unlease EXIT
trap 'exit 1' INT TERM HUP
