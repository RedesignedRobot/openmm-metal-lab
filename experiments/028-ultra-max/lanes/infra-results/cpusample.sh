#!/bin/sh
# Scratch test of the CPU-run sampling in ab-test.sh and the CPU BUSY rerun in ab.sh: private lease,
# queue and tools, the staged ab.sh, ab-test.sh and summarize.py, a fake python that sleeps. No GPU work.
set -u
GT=/tmp/openmm-metal-bench/ultra-infra/cpus
N=/tmp/openmm-metal-bench/ultra-infra/next
rm -rf "$GT"
mkdir -p "$GT/tools" "$GT/bench" "$GT/py" "$GT/queue"
sed -e "s|^LEASE=.*|LEASE=$GT/lease|" -e "s|^QUEUE=.*|QUEUE=$GT/queue|" /tmp/openmm-metal-bench/ultra-tools/lease.sh > "$GT/tools/lease.sh"
sed -e "s|^TOOLS=.*|TOOLS=$GT/tools|" -e "s|^BENCH=.*|BENCH=$GT/bench|" "$N/ab.sh" > "$GT/tools/ab.sh"
cp "$N/ab-test.sh" "$N/summarize.py" /tmp/openmm-metal-bench/ultra-tools/srchash.sh "$GT/tools/"
cat > "$GT/py/python" <<'FAKE'
#!/bin/sh
case "$1" in
-c) case "$2" in *Threads*) echo "${OPENMM_CPU_THREADS:-28}" ;; *) echo /fake/openmm/__init__.py fakerev ;; esac; exit 0 ;;
esac
out=""; secs=5; test=x
while [ $# -gt 0 ]; do
    case "$1" in --outfile) out="$2"; shift ;; --seconds) secs="$2"; shift ;; --test) test="$2"; shift ;; esac
    shift
done
sleep $((secs + 1))
printf '{"benchmarks": [{"test": "%s", "ns_per_day": 1.0}]}' "$test" > "$out"
FAKE
chmod +x "$GT/tools/"*.sh "$GT/py/python"
P="$GT/py/python"
SUM=/tmp/openmm-metal-bench/ultra-base/venv/bin/python

echo "== A: threshold 100000 (never busy), OPENMM_CPU_THREADS=3 in the caller's env, one config sets 4"
sed -i '' 's/^CPU_BUSY_PERCENT=.*/CPU_BUSY_PERCENT=100000/' "$GT/tools/ab-test.sh"
OPENMM_CPU_THREADS=3 "$GT/tools/ab.sh" --rerun-builds "$GT/A" 1 6 pme cpu="$P:CPU:mixed" cpu4="$P:CPU:mixed:OPENMM_CPU_THREADS=4" metal="$P:Metal:single" > "$GT/A.out" 2>&1
echo "exit $?"; grep -v '^estimate\|^[a-z0-9]* [A-Z]' "$GT/A.out"
cat "$GT/A/loads.txt" | cut -d' ' -f1-12 | grep -v ' top ' ; grep -c ' top ' "$GT/A/loads.txt" | sed 's/^/start-of-run lines: /'
echo "-- summarize"; "$SUM" "$GT/tools/summarize.py" "$GT/A" | tail -4

echo "== B: threshold 0 (always busy): CPU runs get CPU BUSY and rerun once, Metal runs aren't sampled"
sed -i '' 's/^CPU_BUSY_PERCENT=.*/CPU_BUSY_PERCENT=-1/' "$GT/tools/ab-test.sh"
"$GT/tools/ab.sh" --rerun-builds "$GT/B" 1 6 pme cpu="$P:CPU:mixed" metal="$P:Metal:single" > "$GT/B.out" 2>&1
echo "exit $?"; grep rerun "$GT/B.out"
grep -v ' top ' "$GT/B/loads.txt"
ls "$GT/B" "$GT/B/replaced"
echo "-- summarize"; "$SUM" "$GT/tools/summarize.py" "$GT/B" | tail -4
echo "leftovers: lease $(ls -d "$GT/lease" 2>/dev/null || echo none), queue $(ls "$GT/queue" | wc -l | tr -d ' '), samples $(ls -a "$GT"/A "$GT"/B | grep -c cpu-samples)"
