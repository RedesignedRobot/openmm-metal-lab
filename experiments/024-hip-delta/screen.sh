#!/bin/sh
# Runs on the mini: one screening round per knob setting. Each argument is a space separated
# list of VAR=value settings for the hipdelta build (the reference build ignores them).
# usage: screen.sh <tests> "<settings>"...
tests="$1"
shift
for config in "$@"; do
    echo "== $config"
    env $config sh ~/lab/024-hip-delta/bench.sh 1 15 "$tests" | tail -1
done
