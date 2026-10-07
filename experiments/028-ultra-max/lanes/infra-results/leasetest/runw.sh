#!/bin/sh
# Scratch test of window.sh, lease.sh --cap and build.sh's window wait on the Studio: private lease,
# queue and window flag, fake ab.sh and summarize.py.
set -u
T=/tmp/openmm-metal-bench/ultra-infra/leasetest
N=/tmp/openmm-metal-bench/ultra-infra/next
B=/tmp/openmm-metal-bench/ultra-base
rm -rf $T/tools $T/lease $T/queue $T/window $T/wout $T/log
mkdir -p $T/tools $T/queue
: > $T/log
sed -e "s|^LEASE=.*|LEASE=$T/lease|" -e "s|^QUEUE=.*|QUEUE=$T/queue|" $N/lease.sh > $T/tools/lease.sh
sed -e "s|^TOOLS=.*|TOOLS=$T/tools|" -e "s|^QUEUE=.*|QUEUE=$T/queue|" -e "s|^WINDOW=.*|WINDOW=$T/window|" $N/window.sh > $T/tools/window.sh
sed -e "s|^WINDOW=.*|WINDOW=$T/window|" $N/build.sh > $T/tools/build.sh
cat > $T/tools/ab.sh <<EOF
#!/bin/sh
echo "\$(perl -MTime::HiRes=time -e 'printf q(%.1f), time') start window-ab" >> $T/log
echo "  fake ab.sh \$1 rounds \$2 seconds \$3 tests \$4, flag: \$(cat $T/window 2>/dev/null)"
sleep 3
mkdir -p "\$1"
echo "\$(perl -MTime::HiRes=time -e 'printf q(%.1f), time') end window-ab" >> $T/log
EOF
echo 'print("  fake summary")' > $T/tools/summarize.py
chmod +x $T/tools/*.sh
L=$T/tools/lease.sh
job() {
    echo "/bin/sh -c 'echo \"\$(perl -MTime::HiRes=time -e \"printf q(%.1f), time\") start $1\" >> $T/log; sleep $2; echo \"\$(perl -MTime::HiRes=time -e \"printf q(%.1f), time\") end $1\" >> $T/log'"
}

echo "W1 the window goes after the current hold, ahead of the queue; build.sh waits while it runs"
eval "$L h h $(job holder 3)" &
sleep 0.3; eval "$L w1 w1 $(job waiter1 1)" &
sleep 0.3; eval "$L --correctness w2 w2 $(job waiter2 1)" &
sleep 0.3
$T/tools/window.sh --smoke $T/wout gbsa a=$B:single,opencl b=$B:single > $T/w.out 2>&1 &
sleep 4.5
echo "  flag during the window: $(cat $T/window 2>/dev/null || echo none)"
mkdir -p /tmp/openmm-metal-bench/ultra-infra/leasetest/fakebuild/src && touch /tmp/openmm-metal-bench/ultra-infra/leasetest/fakebuild/src/CMakeLists.txt
$T/tools/build.sh /tmp/openmm-metal-bench/ultra-infra/leasetest/fakebuild > $T/b.out 2>&1 & bp=$!
sleep 2; kill $bp 2>/dev/null; wait $bp 2>/dev/null
echo "  build.sh said: $(cat $T/b.out)"
wait
sort -n $T/log | awk 'NR == 1 { t0 = $1 } { printf "  %5.1f %s %s\n", $1 - t0, $2, $3 }'
sed 's/^/  window.sh: /' $T/w.out
echo "  flag after: $(cat $T/window 2>/dev/null || echo none), lease dir left: $(ls -d $T/lease 2>/dev/null | wc -l | tr -d ' ')"

echo "W2 --cap"
$L --cap 3 c "cap 3" sleep 10; echo "  exit $?"
$L --cap abc c "bad cap" true; echo "  bad cap exit $?"
$L --cap 30 --correctness c "cap then correctness" sh -c 'cat '"$T"'/lease/correctness > /dev/null && echo "  correctness marker set with --cap first"'
rm -rf $T/tools $T/lease $T/queue $T/window $T/wout $T/log $T/w.out $T/b.out /tmp/openmm-metal-bench/ultra-infra/leasetest/fakebuild
