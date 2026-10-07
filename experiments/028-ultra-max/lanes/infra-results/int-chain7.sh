#!/bin/sh
# Final integrated tip 7484d7bef (u8, bonded chunks, wfcap, D3 on 7ed634ba3): build.sh, then the full gate as a
# merge-path ticket (its ctest -R TestMetal covers the Metal AMOEBA, Drude and RPMD tests), and the
# OpenCL check for plugins' common-kernel edits: ctest of OpenCL AMOEBA, HIPPO and WCA as a second
# merge-path correctness ticket (Apple OpenCL has no mixed, so only Single counts). build.sh itself
# compiles OpenCL and fails if any plugin fails to load.
# Pids go to int-chain7.pids so they can be stopped by pid.
B=/tmp/openmm-metal-bench
I=$B/ultra-integrated
echo "$(date -u +%H:%M:%SZ) build.sh $I"
$B/ultra-tools/build.sh $I > $I/build.out 2>&1 || { echo "BUILD FAILED"; tail -20 $I/build.out; exit 1; }
c=$(sed -n 's/^commit //p' $I/BUILT | cut -c1-9)
echo "$(date -u +%H:%M:%SZ) built $c"
cd /
nohup $B/ultra-tools/gate.sh --merge-path $I > $I/gate-full-$c.out 2>&1 < /dev/null &
echo "gate $!" | tee $B/ultra-infra/int-chain7.pids
sleep 5
nohup $B/ultra-tools/lease.sh --correctness --merge-path --cap 2700 ultra-integrated "infra: OpenCL AMOEBA/HIPPO/WCA ctest on integrated $c" \
    /bin/sh -c 'PATH=/tmp/openmm-metal-bench/env/bin:$PATH; ctest --test-dir "$1/build" -R "^TestOpenCL(Amoeba|Hippo|WcaDispersion).*Single$" -j2 --timeout 600 --output-on-failure; echo "OPENCL CTEST EXIT $?"' sh $I \
    > $I/oclcheck-$c.out 2>&1 < /dev/null &
echo "oclcheck $!" | tee -a $B/ultra-infra/int-chain7.pids
