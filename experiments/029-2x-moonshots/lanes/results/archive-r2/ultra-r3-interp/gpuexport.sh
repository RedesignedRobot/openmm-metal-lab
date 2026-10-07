#!/bin/sh
# Export metal-gpu-intervals (kick level) from the apoa1pme census traces.
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
O=/tmp/openmm-metal-bench/ultra-r3-interp/census
for t in mixed single ocl; do
    xcrun xctrace export --input $O/$t-apoa1pme.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' > $O/x-$t-gpu.xml 2> $O/x-$t-gpu.err
    echo "$t exit=$? $(grep -c '<row' $O/x-$t-gpu.xml)"
done
