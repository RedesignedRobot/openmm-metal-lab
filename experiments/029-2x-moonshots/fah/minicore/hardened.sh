#!/bin/sh
# hardened.sh <bundle> <wu dir> <work dir>
# What the hardened runtime does to the packaged core, as a signed core would ship it.
# Copies the bundle three times, signs each copy ad hoc with the hardened runtime and a different
# entitlement set, then runs 1000 steps of the given unit on each:
#   hr        no entitlements: library validation on, JIT off
#   hr-dlv    com.apple.security.cs.disable-library-validation: plugins may load, JIT still off
#   hr-jit    disable-library-validation and com.apple.security.cs.allow-jit
# Use the neq unit: its CustomIntegrator evaluates globals on the host with Lepton, which JITs on arm64.
# Every run uses an empty environment and the core's priority (nice 19, darwin background).
set -u
bundle=$1
wu=$2
work=$3

[ -e "$work" ] && { echo "$work exists; pick a new work dir"; exit 2; }
mkdir -p "$work"

entitlements() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    for key in "$@"; do
        printf '<key>%s</key><true/>\n' "$key"
    done
    printf '</dict></plist>\n'
}

for variant in hr hr-dlv hr-jit; do
    case $variant in
    hr) keys= ;;
    hr-dlv) keys=com.apple.security.cs.disable-library-validation ;;
    hr-jit) keys="com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-jit" ;;
    esac
    copy=$work/bundle-$variant
    cp -R "$bundle" "$copy"
    entitlements $keys > "$work/$variant.plist"
    for lib in "$copy"/lib/*.dylib "$copy"/plugins/*.dylib; do
        codesign --force -s - -o runtime "$lib" 2> /dev/null
    done
    codesign --force -s - -o runtime --entitlements "$work/$variant.plist" "$copy/minicore" 2> /dev/null
    echo "== $variant: $(codesign -d --entitlements - "$copy/minicore" 2>/dev/null | grep -c '<key>') entitlements, flags $(codesign -dv "$copy/minicore" 2>&1 | grep -o 'flags=[^ ]*')"
    start=$(date +%s)
    env -i PATH=/usr/bin:/bin nice -n 19 /usr/sbin/taskpolicy -b "$copy/minicore" --wu "$wu" \
        --out "$work/run-$variant" --steps 1000 --checkpoint-steps 100 --seed 2029 > "$work/$variant.log" 2>&1
    echo "exit $?, $(( $(date +%s) - start )) s"
    grep -e '^plugin' -e '^force check' -e '^done' -e 'error' -e 'rror' "$work/$variant.log" | head -n 8
done
