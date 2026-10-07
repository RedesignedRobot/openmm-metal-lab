#!/bin/sh
for config in "$@"; do
    label="${config%%=*}"
    echo "$(date -u +%H:%M:%SZ) round $AB_ROUND $AB_TEST $label load 1 queue $(ls /tmp/openmm-metal-bench/ultra-infra/wcpu/queue | wc -l | tr -d ' ')" >> "$AB_OUT/loads.txt"
    echo '{}' > "$AB_OUT/$label-$AB_TEST-round$AB_ROUND.json"
done
sleep 0.3
