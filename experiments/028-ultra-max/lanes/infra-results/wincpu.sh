#!/bin/sh
# Scratch test of window.sh --cpu: private lease, queue, window marker and tools, the staged ab.sh
# and window.sh, a fake python, ab-test.sh and summarize.py. No GPU work.
set -u
GT=/tmp/openmm-metal-bench/ultra-infra/wcpu
N=/tmp/openmm-metal-bench/ultra-infra/next
rm -rf "$GT"
mkdir -p "$GT/tools" "$GT/bench" "$GT/basedir/venv/bin" "$GT/queue"
sed -e "s|^LEASE=.*|LEASE=$GT/lease|" -e "s|^QUEUE=.*|QUEUE=$GT/queue|" /tmp/openmm-metal-bench/ultra-tools/lease.sh > "$GT/tools/lease.sh"
sed -e "s|^TOOLS=.*|TOOLS=$GT/tools|" -e "s|^BENCH=.*|BENCH=$GT/bench|" /tmp/openmm-metal-bench/ultra-tools/ab.sh > "$GT/tools/ab.sh"
sed -e "s|^TOOLS=.*|TOOLS=$GT/tools|" -e "s|^QUEUE=.*|QUEUE=$GT/queue|" -e "s|^WINDOW=.*|WINDOW=$GT/window-marker|" \
    -e "s|^LOAD_MAX=.*|LOAD_MAX=1000|" -e "s|^BUILDS=.*|BUILDS='no-such-build-process'|" "$N/window.sh" > "$GT/tools/window.sh"
cp /tmp/openmm-metal-bench/ultra-tools/srchash.sh "$GT/tools/"
cat > "$GT/tools/ab-test.sh" <<'FAKE'
#!/bin/sh
for config in "$@"; do
    label="${config%%=*}"
    echo "$(date -u +%H:%M:%SZ) round $AB_ROUND $AB_TEST $label load 1 queue $(ls /tmp/openmm-metal-bench/ultra-infra/wcpu/queue | wc -l | tr -d ' ')" >> "$AB_OUT/loads.txt"
    echo '{}' > "$AB_OUT/$label-$AB_TEST-round$AB_ROUND.json"
done
sleep 0.3
FAKE
printf 'import sys\nprint("summarize", *sys.argv[1:])\n' > "$GT/tools/summarize.py"
printf '#!/bin/sh\necho /fake/openmm/__init__.py fakerev\n' > "$GT/basedir/venv/bin/python"
chmod +x "$GT/tools/"*.sh "$GT/basedir/venv/bin/python"

echo "== estimate, staged window.sh with the real trees"
"$N/window.sh" --estimate /tmp/x all base=/tmp/openmm-metal-bench/ultra-base:single,mixed,opencl int=/tmp/openmm-metal-bench/ultra-integrated:single,mixed
"$N/window.sh" --estimate --cpu /tmp/x all base=/tmp/openmm-metal-bench/ultra-base:single,mixed,opencl int=/tmp/openmm-metal-bench/ultra-integrated:single,mixed
"$N/window.sh" --estimate --cpu --smoke /tmp/x gbsa base=/tmp/openmm-metal-bench/ultra-base:single

echo "== smoke window with --cpu on the private queue"
"$GT/tools/window.sh" --smoke --cpu "$GT/w" gbsa,rf base="$GT/basedir:single,opencl" > "$GT/w.out" 2>&1
echo "window.sh exit $?"
grep -vE '^ *[0-9.]+ +[0-9]+ ' "$GT/w.out" | grep -v '^holder\|^build processes\|^queue'
echo "-- ab/configs.txt"; cat "$GT/w/ab/configs.txt"
echo "-- cpu/configs.txt"; cat "$GT/w/cpu/configs.txt"
echo "-- cpu/loads.txt"; cat "$GT/w/cpu/loads.txt"
echo "-- files"; ls "$GT/w" "$GT/w/cpu"
echo "leftovers: lease $(ls -d "$GT/lease" 2>/dev/null || echo none), queue $(ls "$GT/queue" | wc -l | tr -d ' '), marker $(ls "$GT/window-marker" 2>/dev/null || echo none)"
