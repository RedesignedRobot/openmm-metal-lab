#!/bin/sh
# covers: gate.sh gate-ctest.sh srchash.sh   (install.sh runs this test when one of these changes)
# gate.sh's flow on a fake tree, no GPU: the CPU-only setup (log dir, ctest listing, cost data) happens
# before the one outer lease.sh call, ctest runs every test in one run with the longest first, forces.py
# runs beside ctest, and a forces or ctest failure still fails the gate. lease.sh, forces.py and the
# tests are fakes; ctest and srchash.sh are real.
# usage: tests/gate-flow.sh [scratch dir]
set -u
TOOLS_SRC=$(cd "$(dirname "$0")/.." && pwd)
S=${1:-/tmp/openmm-metal-bench/ultra-r3-tools/gate-test}
TT=$S/tools
TREE=$S/tree
PY=/tmp/openmm-metal-bench/env/bin/python3
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
unset GATE_HELD GATE_OUT GPUQ_PREFLIGHT GPUQ_JOB OPENMM_LEASE_PID FAKE_FORCES_FAIL
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }

rm -rf "$S"
mkdir -p $TT $TREE/venv/bin $TREE/build $TREE/src
for f in $TOOLS_SRC/*; do [ -f "$f" ] && ln -s "$f" "$TT/"; done
rm $TT/gate.sh $TT/forces.py $TT/gate-cost.txt
sed "s|^TOOLS=.*|TOOLS=$TT|" $TOOLS_SRC/gate.sh > $TT/gate.sh
# The fake lease.sh logs each call with whether the gate's log dir and ctest list already exist, then runs
# the command at once.
cat > $TT/lease.sh <<EOF
#!/bin/sh
while :; do case "\$1" in --correctness|--merge-path) shift ;; --cap) shift 2 ;; *) break ;; esac; done
echo "lease \$2 | tests.txt \$([ -s "\${GATE_OUT:-/nonexistent}/tests.txt" ] && echo yes || echo no)" >> $S/lease.log
shift 2
exec "\$@"
EOF
# The fake forces.py records its start and end, sleeps 2 s, and fails when FAKE_FORCES_FAIL is set.
cat > $TT/forces.py <<'EOF'
import os, sys, time
out = sys.argv[2]
open(out + ".start", "w").write(f"{time.time()}\n")
time.sleep(2)
open(out, "w").write("gbsa fake row\n")
print("gbsa fake row  " + ("FAIL fake" if os.environ.get("FAKE_FORCES_FAIL") else "ok"))
open(out + ".end", "w").write(f"{time.time()}\n")
sys.exit(1 if os.environ.get("FAKE_FORCES_FAIL") else 0)
EOF
chmod +x $TT/gate.sh $TT/lease.sh
echo "TestMetalLong 1 100" > $TT/gate-cost.txt
ln -s $PY $TREE/venv/bin/python
echo x > $TREE/src/file.cpp
printf 'commit fake0000\nsrc %s\n' "$($TOOLS_SRC/srchash.sh $TREE)" > $TREE/BUILT
# Four short tests, then the long one last in number order; each records its start time.
{
    for t in Short1 Short2 Short3 Short4 Long; do
        len=0.2; [ $t = Long ] && len=3
        echo "add_test(TestMetal$t \"/bin/sh\" \"-c\" \"date +%s > $S/start-$t; sleep $len\")"
    done
    echo "add_test(OtherTest \"/bin/sh\" \"-c\" \"exit 1\")"
} > $TREE/build/CTestTestfile.cmake

gate() { /bin/sh -c "$TT/gate.sh $* > $S/gate.out 2>&1"; }

echo "== 1: the preflight lists the tests and creates nothing"
: > $S/lease.log
GPUQ_PREFLIGHT=1 $TT/gate.sh $TREE > $S/pre.out 2>&1 && grep -q "preflight ok" $S/pre.out \
    && ok "preflight ok" || bad "preflight: $(cat $S/pre.out)"
[ -z "$(/bin/ls -d $TREE/gate-* 2>/dev/null)" ] && [ ! -s $S/lease.log ] && [ ! -e $TREE/build/Testing/Temporary/CTestCostData.txt ] \
    && ok "no log dir, no cost data, no lease call" || bad "the preflight left files or called lease.sh"

echo "== 2: full gate"
: > $S/lease.log
gate $TREE; code=$?
out=$(/bin/ls -d $TREE/gate-* | tail -1)
[ $code = 0 ] && [ "$(tail -1 $S/gate.out)" = PASS ] && ok "PASS, exit 0" || bad "exit $code: $(cat $S/gate.out)"
head -1 $S/lease.log | grep -q "^lease gate.sh $TREE | tests.txt yes" \
    && ok "the log dir and ctest list existed before the outer lease.sh call" || bad "lease log: $(cat $S/lease.log)"
grep -q "^TestMetalLong 2 " $TREE/build/Testing/Temporary/CTestCostData.txt 2>/dev/null \
    && ok "gate-cost.txt seeded the tree's ctest cost data (ctest counts TestMetalLong's run as its second)" || bad "cost data not seeded"
[ "$(wc -l < $out/tests.txt | tr -d ' ')" = 5 ] && grep -q "100% tests passed.* out of 5$" $out/ctest-1.txt \
    && ok "one ctest run over all 5 TestMetal tests" || bad "ctest: $(tail -3 $out/ctest-1.txt)"
first=$(grep -m1 -E "Start +[0-9]+:" $out/ctest-1.txt | sed 's/.*: //')
[ "$first" = TestMetalLong ] && ok "the longest test started first" || bad "first test: $first"
fs=$(cut -d. -f1 $out/forces.txt.start); ls_=$(cat $S/start-Long)
[ $((fs - ls_)) -le 1 ] && [ $((ls_ - fs)) -le 1 ] && ok "forces.py started beside ctest (${fs} and ${ls_})" \
    || bad "forces started at $fs, the long test at $ls_"
grep -q "gbsa fake row  ok" $S/gate.out && grep -q "ctest: 5 tests, 0 failed" $S/gate.out \
    && ok "forces verdict and ctest count printed" || bad "output: $(cat $S/gate.out)"

echo "== 3: a failing forces row fails the gate after ctest finishes"
(FAKE_FORCES_FAIL=1; export FAKE_FORCES_FAIL; gate $TREE); code=$?
out=$(/bin/ls -d $TREE/gate-* | tail -1)
[ $code = 1 ] && [ "$(tail -1 $S/gate.out)" = FAIL ] && grep -q "done part 1" $out/verdict-1.txt \
    && ok "FAIL, exit 1, ctest still ran" || bad "exit $code: $(cat $S/gate.out)"

echo "== 4: a failing test fails the gate"
sed -i '' '/TestMetalShort2/s/.*/add_test(TestMetalShort2 "\/bin\/sh" "-c" "exit 1")/' $TREE/build/CTestTestfile.cmake
gate $TREE; code=$?
[ $code = 1 ] && grep -q "FAIL TestMetalShort2 failed in the -j2 run" $S/gate.out \
    && ok "FAIL on TestMetalShort2" || bad "exit $code: $(cat $S/gate.out)"

echo "== 5: --quick runs forces only"
: > $S/lease.log
sleep 1
gate --quick $TREE; code=$?
out=$(/bin/ls -d $TREE/gate-* | tail -1)
[ $code = 0 ] && [ -e $out/forces.txt ] && [ ! -e $out/tests.txt ] && [ ! -e $out/ctest-1.txt ] \
    && ok "PASS with no ctest" || bad "exit $code: $(cat $S/gate.out)"

echo "== 6: a tree with no TestMetal tests is refused before the hold"
: > $S/lease.log
sed -i '' '/TestMetal/d' $TREE/build/CTestTestfile.cmake
gate $TREE; code=$?
[ $code = 2 ] && grep -q "lists no TestMetal tests" $S/gate.out && [ ! -s $S/lease.log ] \
    && ok "exit 2, no lease call" || bad "exit $code: $(cat $S/gate.out)"

rm -rf "$S"
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
