#!/bin/sh
# Scratch test of ab.sh --rerun-builds, the per-run VM field and the during-run build check on the
# Studio: private lease and queue, fake python and bench, and a fake build process under a name no
# real tool counts, so no lane's run gets marked.
set -u
T=/tmp/openmm-metal-bench/ultra-infra/leasetest/ab
N=/tmp/openmm-metal-bench/ultra-infra/next
rm -rf $T
mkdir -p $T/tools $T/bench $T/queue $T/fake
sed -e "s|^LEASE=.*|LEASE=$T/lease|" -e "s|^QUEUE=.*|QUEUE=$T/queue|" $N/lease.sh > $T/tools/lease.sh
sed -e "s|^TOOLS=.*|TOOLS=$T/tools|" -e "s|^BENCH=.*|BENCH=$T/bench|" $N/ab.sh > $T/tools/ab.sh
sed -e "s|^BUILDS=.*|BUILDS='infrafakebuild'|" $N/ab-test.sh > $T/tools/ab-test.sh
chmod +x $T/tools/*.sh
touch $T/bench/benchmark.py
# A copied Apple platform binary gets SIGKILLed, so the fake build is a renamed ninja running sleep.
cp /tmp/openmm-metal-bench/env/bin/ninja $T/fake/infrafakebuild
for secs in 1.2 3; do
    mkdir -p $T/fake/b$secs
    printf "rule wait\n  command = sleep %s\nbuild never: wait\n" $secs > $T/fake/b$secs/build.ninja
done
cat > $T/fake/python <<'EOF'
#!/bin/sh
[ "$1" = -c ] && { echo "/fake/openmm/__init__.py fakerev"; exit 0; }
while [ $# -gt 0 ]; do
    case "$1" in
    --test) test="$2"; shift ;;
    --seconds) seconds="$2"; shift ;;
    --outfile) outfile="$2"; shift ;;
    esac
    shift
done
sleep "$seconds"
printf '{"benchmarks": [{"test": "%s", "ns_per_day": %s}]}\n' "$test" "$(perl -e 'printf "%.1f", 100 + rand(10)')" > "$outfile"
EOF
chmod +x $T/fake/python
cd /
/bin/sh $T/tools/lease.sh infra "ab rerun test" $T/tools/ab.sh --rerun-builds $T/out 2 2 gbsa,pme a=$T/fake/python:Metal:single b=$T/fake/python:Metal:single > $T/ab.out 2>&1 &
sleep 1; $T/fake/infrafakebuild -C $T/fake/b1.2 > /dev/null
sleep 7; $T/fake/infrafakebuild -C $T/fake/b3 > /dev/null
wait
echo "ab.sh output:"; sed 's/^/  /' $T/ab.out
echo "loads.txt:"; cut -c1-150 $T/out/loads.txt | sed 's/^/  /'
echo "results: $(ls $T/out/*.json | wc -l | tr -d ' '), replaced: $(ls $T/out/replaced 2>/dev/null | tr '\n' ' ')"
echo "summary:"; /tmp/openmm-metal-bench/ultra-base/venv/bin/python $N/summarize.py $T/out b/a | tail -6 | sed 's/^/  /'
rm -rf $T
