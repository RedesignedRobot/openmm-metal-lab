#!/bin/sh
labels="$(echo "$*" | sed 's/=[^ ]*//g')"
set -- "r$AB_ROUND $AB_TEST $labels"; echo "$(date +%H:%M:%S) $1 owner=[$(cat /tmp/openmm-metal-bench/ultra-infra/abw/lease/owner 2>/dev/null | cut -c1-60)] queue=[$(ls /tmp/openmm-metal-bench/ultra-infra/abw/queue | sed "s/^[0-9]*-//" | tr "\n" " ")]" >> /tmp/openmm-metal-bench/ultra-infra/abw/trace.txt
for label in $labels; do
    mark=""
    [ "${AB_MARK:-}" = "$AB_ROUND:$AB_TEST" ] && [ ! -d "$AB_OUT/replaced" ] && mark=" BUILD RUNNING"
    echo "$(date -u +%H:%M:%SZ) round $AB_ROUND $AB_TEST $label load 1$mark" >> "$AB_OUT/loads.txt"
    echo '{}' > "$AB_OUT/$label-$AB_TEST-round$AB_ROUND.json"
done
sleep 0.4
