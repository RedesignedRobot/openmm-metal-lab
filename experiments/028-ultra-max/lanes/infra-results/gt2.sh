#!/bin/sh
# Scratch test of gate.sh's one hold: private lease, queue and tools, a fake tree, a fake ctest and a
# fake python that record the lease state. No GPU work.
set -u
GT=/tmp/openmm-metal-bench/ultra-infra/gt2
N=/tmp/openmm-metal-bench/ultra-infra/next
rm -rf "$GT"
mkdir -p "$GT/tools" "$GT/bin" "$GT/base/benchmarks" "$GT/dir/src" "$GT/dir/build" "$GT/dir/venv/bin"
sed -e "s|^LEASE=.*|LEASE=$GT/lease|" -e "s|^QUEUE=.*|QUEUE=$GT/queue|" "$N/lease.sh" > "$GT/tools/lease.sh"
sed -e "s|^TOOLS=.*|TOOLS=$GT/tools|" -e "s|^BASE=.*|BASE=$GT/base|" -e "s|^export PATH=.*|export PATH=$GT/bin:\$PATH|" "$N/gate.sh" > "$GT/tools/gate.sh"
cp "$N/gate-ctest.sh" /tmp/openmm-metal-bench/ultra-tools/srchash.sh "$GT/tools/"
chmod +x "$GT/tools/"*.sh
touch "$GT/base/forces.txt" "$GT/tools/forces.py" "$GT/dir/build/CTestTestfile.cmake"
echo one > "$GT/dir/src/a.txt"
printf 'commit fake\nsrc %s\n' "$("$GT/tools/srchash.sh" "$GT/dir")" > "$GT/dir/BUILT"
state='echo "$(date +%H:%M:%S) $1 owner=[$(cat '"$GT"'/lease/owner 2>/dev/null)] members=$(ls '"$GT"'/lease/members 2>/dev/null | wc -l | tr -d " ") queue=[$(ls '"$GT"'/queue | sed "s/^[0-9]*-//" | tr "\n" " ")]" >> '"$GT"'/trace.txt'
cat > "$GT/dir/venv/bin/python" <<FAKE
#!/bin/sh
set -- forces; $state
sleep 2
echo "forces ok"
FAKE
cat > "$GT/bin/ctest" <<FAKE
#!/bin/sh
case "\$*" in
*" -N "*) i=1; while [ \$i -le 65 ]; do echo "  Test #\$i: TestMetalFake\$i"; i=\$((i+1)); done; exit 0 ;;
*--tests-from-file*) f=\$(echo "\$*" | sed 's/.*--tests-from-file \([^ ]*\).*/\1/'); set -- "ctest \${f##*/}"; $state; sleep 2
    echo "100% tests passed, 0 tests failed out of \$(wc -l < \$f | tr -d ' ')" ;;
esac
FAKE
chmod +x "$GT/dir/venv/bin/python" "$GT/bin/ctest"
L="$GT/tools/lease.sh"

echo "== A: gate behind a 4 s timing hold, then a correctness ticket and a timing ticket queued behind it"
"$L" timing1 "timing hold" sleep 4 2> /dev/null &
sleep 0.5
"$GT/tools/gate.sh" "$GT/dir" > "$GT/gateA.out" 2>&1 &
gate=$!
sleep 0.5
"$L" --correctness cjoin "joins the gate" sh -c "set -- cjoin-start; $state; sleep 3; set -- cjoin-end; $state" 2> /dev/null &
sleep 0.3
"$L" tafter "timing after" sh -c "set -- tafter-start; $state" 2> /dev/null &
sleep 1
ls "$GT/queue" | sed 's/^[0-9]*-//'
wait $gate; echo "gate exit $?"
wait
cat "$GT/trace.txt"; tail -4 "$GT/gateA.out"
grep -c "gate.sh" "$GT/gateA.out" > /dev/null
: > "$GT/trace.txt"

echo "== B: LEASE_TICKET_US keeps a place ahead of a later waiter"
"$L" timing2 "timing hold" sleep 3 2> /dev/null &
sleep 0.3
"$L" waiter "queued before the restart" sh -c "set -- waiter-start; $state" 2> /dev/null &
sleep 0.3
w_us=$(ls "$GT/queue" | grep -- '-waiter-' | cut -d- -f1)
LEASE_TICKET_US=$((w_us - 1)) "$GT/tools/gate.sh" --quick "$GT/dir" > "$GT/gateB.out" 2>&1 &
sleep 0.5
echo "queue (oldest first): $(ls "$GT/queue" | sed 's/^[0-9]*-//' | tr '\n' ' ')"
ls "$GT/queue" | grep -q "^$((w_us - 1))-dir-" && echo "gate ticket carries LEASE_TICKET_US"
wait
cat "$GT/trace.txt"; tail -2 "$GT/gateB.out"
: > "$GT/trace.txt"

echo "== C: gate.sh inside an outer timing hold (window.sh) runs at once, no ticket of its own"
"$L" window "window" sh -c "sleep 0.5; ls $GT/queue | wc -l | sed 's/^ */queue files during the nested gate: /' > $GT/nested.txt & $GT/tools/gate.sh --quick $GT/dir" > "$GT/gateC.out" 2>&1
cat "$GT/nested.txt" "$GT/trace.txt"; tail -2 "$GT/gateC.out"
echo "leftovers: lease $(ls -d "$GT/lease" 2>/dev/null || echo none), queue $(ls "$GT/queue" | wc -l | tr -d ' ')"
