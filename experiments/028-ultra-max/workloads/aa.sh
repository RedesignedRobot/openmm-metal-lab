#!/bin/sh
# The lead's A/A test of abw.py on amber20-cellulose mixed, one lease.sh hold, about 9 minutes.
# Part 1 interleaves two cold arms and one warm arm of the same build, so |coldA/coldB - 1| is the noise
# floor. Part 2 compares a whole cold ab.sh screen against a whole warm abw.py screen, which part 1 can't
# (interleaving hides duty-cycle effects). The nested ab.sh and abw.py run inside this hold.
set -eu
W=/tmp/openmm-metal-bench/ultra-workloads
P=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
"$P" "$W/abw.py" --cold coldA,coldB "$W/aa1-inter" 2 15 amber20-cellulose \
    coldA=$P:Metal:mixed warm=$P:Metal:mixed coldB=$P:Metal:mixed
/tmp/openmm-metal-bench/ultra-tools/ab.sh "$W/aa1-cold" 2 15 amber20-cellulose base=$P:Metal:mixed
"$P" "$W/abw.py" "$W/aa1-warm" 2 15 amber20-cellulose base=$P:Metal:mixed
echo done
