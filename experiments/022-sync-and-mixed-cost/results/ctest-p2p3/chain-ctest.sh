#!/bin/sh
# After the builds, each variant's Metal ctest per precision, one lease per block.
cd /tmp/openmm-metal-bench/verify-p2p3 || exit 1
until grep -q CHAIN-DONE logs/chain-build.log; do sleep 10; done
echo "builds done $(date -u +%H:%M:%SZ)"
for b in base:Single p2p3:Single base:Mixed p2p3:Mixed; do
    v=${b%%:*} p=${b#*:}
    sh lab/leased.sh "ctest-$v-$p" sh lab/ctest.sh "$v" "$p"
    sleep 60
done
echo CHAIN-DONE
