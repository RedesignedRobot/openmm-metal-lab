#!/bin/sh
while kill -0 62563 2>/dev/null; do sleep 15; done
cd /tmp/openmm-metal-bench
G=/tmp/openmm-metal-bench/ultra-r2-accum-nb-g/venv/bin/python
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
./ultra-tools/bg.sh ultra-r2-accum-nb/probe5.out ultra-tools/ab.sh /tmp/openmm-metal-bench/ultra-r2-accum-nb/probe5 2 15 amber20-cellulose,apoa1rf base_s=/tmp/openmm-metal-bench/ultra-r1/venv/bin/python:Metal:single sub_s=$G:Metal:single sub160_s=$G:Metal:single:P_NBMULT=160 sub20_s=$G:Metal:single:P_NBMULT=20 old_s=$G:Metal:single:P_OLDLOOP=1 old160_s=$G:Metal:single:P_OLDLOOP=1,P_NBMULT=160 manc_s=$Q:Metal:single manc160_s=$Q:Metal:single:P_NBMULT=160
echo queued $(date -u)
