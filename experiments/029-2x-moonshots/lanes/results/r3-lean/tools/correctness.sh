#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-r3-lean
T=/tmp/openmm-metal-bench/ultra-tools
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
if [ -z "${OPENMM_LEASE_PID:-}" ]; then
    exec "$T/lease.sh" --correctness r3-lean "force-only targeted tests and bitwise comparison" /bin/sh "$D/tools/correctness.sh"
fi
case "$(date -u +%H)" in 00|01|02|03|04|05|06) echo 'No GPU work before 07:00Z'; exit 2;; esac
mkdir -p "$D/correctness"
ctest --test-dir "$D/build" --output-on-failure -j2 -R '^TestMetal(ForceOnly|HarmonicBondForce|HarmonicAngleForce|PeriodicTorsionForce|RBTorsionForce|CMAPTorsionForce|CustomBondForce|CustomAngleForce|CustomTorsionForce|CustomCompoundBondForce|CustomCentroidBondForce|CustomExternalForce|CustomHbondForce|CustomManyParticleForce|CustomNonbondedForce|NonbondedForce|GayBerneForce|LCPOForce|RGForce|CustomCVForce|ATMForce)(Single|Mixed)$' > "$D/correctness/ctest.txt" 2>&1
for round in 1 2; do
    for arm in base mine; do
        tree="$D"
        [ "$arm" = base ] && tree=/tmp/openmm-metal-bench/ultra-r2-bonded
        "$tree/venv/bin/python" "$D/tools/bitforces.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$D/correctness/$arm-$round" gbsa,rf,pme,apoa1rf,apoa1pme,amber20-cellulose,amber20-stmv > "$D/correctness/$arm-$round.txt" 2>&1
    done
done
"$D/venv/bin/python" "$D/tools/bitcompare.py" > "$D/correctness/bitcompare.txt"
cat "$D/correctness/bitcompare.txt"
echo CORRECTNESS_PASS
