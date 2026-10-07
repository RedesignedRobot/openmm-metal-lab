#!/bin/sh
# New refusals, then a worker killed by its recorded pid while idle: the driver must log it and finish.
P=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
A=/tmp/openmm-metal-bench/ultra-workloads/abw.py
T=/tmp/openmm-metal-bench/ultra-workloads/abwtest
for args in "$T/r1 1 3 dhfr r=$P:Reference:double" "$T/r2 1 3 gbsa,rf, r=$P:Reference:double" \
            "$T/r3 1 3 gbsa c=$P:CPU:mixed" "$T/r4 1 3 gbsa c=$P:CPU:mixed:OPENMM_CPU_THREADS"; do
    $P $A --validate $args > /dev/null 2> $T/err.txt
    echo "exit $? $(tail -1 $T/err.txt | cut -c1-150)"
done
O=$T/death2
/bin/sh -c "nohup $P $A --validate --cold rc $O 3 3 gbsa r=$P:Reference:double rc=$P:Reference:double > $O.out 2>&1 < /dev/null &"
until [ -s $O/r-gbsa-round1.json ]; do sleep 0.2; done
w=$(awk '$4 == "r" {print $3}' $O/workers.txt)
d=$(awk '$4 == "driver" {print $3}' $O/workers.txt)
echo "killing idle worker $w (recorded in workers.txt)"
kill $w
while kill -0 $d 2>/dev/null; do sleep 0.5; done
echo "driver $d exited"
grep -c Traceback $O.out
tail -1 $O.out
grep -v " load " $O/loads.txt | cut -c1-120
