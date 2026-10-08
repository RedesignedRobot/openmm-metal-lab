#!/bin/sh
# Scratch test of lease.sh's shared correctness holds on the Studio: private LEASE and QUEUE.
set -u
T=/tmp/openmm-metal-bench/ultra-infra/leasetest
L=$T/lease.sh
fresh() { rm -rf $T/lease $T/queue $T/log; mkdir -p $T/queue; : > $T/log; }
job() {  # job <name> <seconds>: logs start and end with a timestamp
    echo "/bin/sh -c 'echo \"\$(perl -MTime::HiRes=time -e \"printf q(%.1f), time\") start $1\" >> $T/log; sleep $2; echo \"\$(perl -MTime::HiRes=time -e \"printf q(%.1f), time\") end $1\" >> $T/log'"
}
show() { sort -n $T/log | awk 'NR == 1 { t0 = $1 } { printf "  %5.1f %s %s\n", $1 - t0, $2, $3 }'; }

if [ "${1:-}" != T10 ]; then
echo "T8 three correctness jobs share, the fourth waits for a slot, the timing job waits for an empty lease"
fresh
eval "$L --correctness c1 c1 $(job c1 3)" &
sleep 0.3; eval "$L --correctness c2 c2 $(job c2 3)" &
sleep 0.3; eval "$L --correctness c3 c3 $(job c3 3)" &
sleep 0.3; eval "$L --correctness c4 c4 $(job c4 2)" &
sleep 0.3; eval "$L tm tm $(job timing 1)" &
sleep 0.3; eval "$L --correctness c5 c5 $(job c5 1)" &
sleep 0.5; $L --status | sed 's/^/  /'
wait; show
echo "  lease dir left: $(ls -d $T/lease 2>/dev/null | wc -l | tr -d ' ')"

echo "T9 the first member leaves first: pid handed to a live member, lease kept until the last leaves"
fresh
eval "$L --correctness p p $(job p 1)" &
sleep 0.3; eval "$L --correctness q q $(job q 3)" &
sleep 2; echo "  pid file $(cat $T/lease/pid), q's lease.sh is $(pgrep -f 'lease.sh --correctness q q' | head -1)"; $L --status | sed 's/^/  /'
wait; echo "  lease dir left: $(ls -d $T/lease 2>/dev/null | wc -l | tr -d ' ')"

fi
echo "T10 a killed member is removed by the head; the lease survives while one member lives"
fresh
eval "$L --correctness k1 k1 $(job k1 4)" &
sleep 0.3; eval "$L --correctness k2 k2 $(job k2 2)" &
sleep 0.5; k1=$(pgrep -f "lease.sh --correctness k1 k1" | head -1); kill -9 $k1; echo "  killed k1's lease.sh $k1 with -9; its command runs on"
eval "$L tm tm $(job timing 1)"
wait; show
echo "  lease dir left: $(ls -d $T/lease 2>/dev/null | wc -l | tr -d ' ')"

[ "${1:-}" = T10 ] && exit 0
echo "T11 nested call inside a joined member, exit code of a member"
fresh
eval "$L --correctness n1 n1 $(job n1 2)" &
sleep 0.3
cat > $T/inner.sh <<EOF
#!/bin/sh
s=\$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
$L inner inner true
echo "  nested call in a member took \$(echo "\$(perl -MTime::HiRes=time -e 'printf "%.2f", time') - \$s" | bc) s"
exit 5
EOF
chmod +x $T/inner.sh
$L --correctness n2 n2 $T/inner.sh; echo "  member exit $?"
wait
echo "  lease dir left: $(ls -d $T/lease 2>/dev/null | wc -l | tr -d ' ')"

echo "T12 a timing holder is never joined"
fresh
eval "$L tm tm $(job timing 2)" &
sleep 0.3; eval "$L --correctness c c $(job c 1)"
wait; show
rm -rf $T/lease $T/queue $T/log $T/inner.sh
