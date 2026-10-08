#!/bin/sh
# Scratch test of lease.sh on the Studio: private LEASE, QUEUE and a 6 s cap.
set -u
T=/tmp/openmm-metal-bench/ultra-infra/leasetest
L=$T/lease.sh
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
fresh() { rm -rf $T/lease $T/queue; mkdir -p $T/queue; }
sed -e "s|^LEASE=.*|LEASE=$T/lease|" -e "s|^QUEUE=.*|QUEUE=$T/queue|" -e 's|^CAP_SECONDS=1200|CAP_SECONDS=6|' \
    /tmp/openmm-metal-bench/ultra-infra/next/lease.sh > $L
chmod +x $L

echo "T1 handoff latency"
fresh
$L a "hold 2 s" /bin/sh -c "sleep 2; perl -MTime::HiRes=time -e 'printf \"%.2f\n\", time' > $T/a.end" &
sleep 0.3
$L b "next" /bin/sh -c "perl -MTime::HiRes=time -e 'printf \"%.2f\n\", time' > $T/b.start"
wait
echo "  handoff $(echo "$(cat $T/b.start) - $(cat $T/a.end)" | bc) s"

echo "T2 build running, no wait"
fresh
mkdir -p $T/fake && cp /tmp/openmm-metal-bench/env/bin/ninja $T/fake/ninja
printf 'rule s\n  command = sleep 8\nbuild x: s\n' > $T/fake/build.ninja
(cd $T/fake && ./ninja > /dev/null 2>&1) &
sleep 1
echo "  build processes: $(pgrep -x 'clang|clang\+\+|ninja|cc1plus' | wc -l | tr -d ' ')"
s=$(now); $L t "timing" /bin/sh -c "cat $T/lease/owner"; echo "  timing waited $(echo "$(now) - $s" | bc) s"
$L --correctness c "correctness" /bin/sh -c "cat $T/lease/owner"
wait

echo "T3 hand lease cleared after cap + 60 s"
fresh
mkdir $T/lease && echo "by hand" > $T/lease/owner && touch -t "$(date -v-70S +%Y%m%d%H%M.%S)" $T/lease
$L h "after hand lease" /bin/sh -c "echo '  got the lease'"
mkdir $T/lease && echo "fresh hand" > $T/lease/owner
$L h2 "behind a fresh hand lease" true & p=$!
sleep 2; kill -0 $p 2>/dev/null && echo "  still waiting behind a fresh hand lease: ok"
kill $p; wait $p 2>/dev/null; rm -rf $T/lease

echo "T4 reused pids"
fresh
sleep 30 & fake=$!
touch $T/queue/1000000000000000-reused-$fake
$L r "behind a reused ticket pid" /bin/sh -c "echo '  got the lease past ticket pid $fake'"
mkdir $T/lease && echo "reused holder" > $T/lease/owner && echo $fake > $T/lease/pid
$L r2 "behind a reused holder pid" /bin/sh -c "echo '  got the lease past holder pid $fake'"
kill $fake

echo "T5 nesting and the cap"
fresh
cat > $T/outer.sh <<EOF
#!/bin/sh
for i in 1 2 3; do
    s=\$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    $L inner "inner \$i" true
    echo "  inner \$i took \$(echo "\$(perl -MTime::HiRes=time -e 'printf "%.2f", time') - \$s" | bc) s"
done
$L inner "inner sleep" sleep 31.7
EOF
chmod +x $T/outer.sh
$L outer "wrapped screen" $T/outer.sh & p=$!
sleep 1
$L --status | sed 's/^/  /'
wait $p; echo "  outer exit $?"
sleep 1
echo "  sleep 31.7 left: $(pgrep -f 'sleep 31.7' | wc -l | tr -d ' '), lease dir left: $(ls -d $T/lease 2>/dev/null | wc -l | tr -d ' ')"

echo "T6 LEASE_TICKET_US"
fresh
$L x "hold 3 s" sleep 3 &
sleep 0.3
$L y "normal ticket" /bin/sh -c "echo '  y ran'" &
sleep 0.3
LEASE_TICKET_US=1000000000000001 $L z "priority ticket" /bin/sh -c "echo '  z ran'; env | grep -c LEASE_TICKET_US"
wait
LEASE_TICKET_US=12ab $L z bad true; echo "  bad value exit $?"
LEASE_TICKET_US=123 $L z short true; echo "  short value exit $?"

echo "T7 odd names and exit code"
fresh
touch "$T/queue/0-with space-1" "$T/queue/$(printf '1-a\n-2')" $T/queue/notaticket
$L --status | sed 's/^/  /'
$L e "exit 7" sh -c 'exit 7'; echo "  exit $?"
rm -rf $T/fake $T/lease $T/queue $T/*.end $T/*.start
