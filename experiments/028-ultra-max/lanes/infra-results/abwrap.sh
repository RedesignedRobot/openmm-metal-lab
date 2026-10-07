#!/bin/sh
# Scratch test of ab.sh's one ticket per screen: private lease, queue and tools, a fake python and a
# fake ab-test.sh that record the lease state. No GPU work.
set -u
GT=/tmp/openmm-metal-bench/ultra-infra/abw
N=/tmp/openmm-metal-bench/ultra-infra/next
rm -rf "$GT" /tmp/infra-abw-E
mkdir -p "$GT/tools" "$GT/bench" "$GT/py" "$GT/queue"
sed -e "s|^LEASE=.*|LEASE=$GT/lease|" -e "s|^QUEUE=.*|QUEUE=$GT/queue|" /tmp/openmm-metal-bench/ultra-tools/lease.sh > "$GT/tools/lease.sh"
sed -e "s|^TOOLS=.*|TOOLS=$GT/tools|" -e "s|^BENCH=.*|BENCH=$GT/bench|" "$N/ab.sh" > "$GT/tools/ab.sh"
cp /tmp/openmm-metal-bench/ultra-tools/srchash.sh "$GT/tools/"
state='echo "$(date +%H:%M:%S) $1 owner=[$(cat '"$GT"'/lease/owner 2>/dev/null | cut -c1-60)] queue=[$(ls '"$GT"'/queue | sed "s/^[0-9]*-//" | tr "\n" " ")]" >> '"$GT"'/trace.txt'
cat > "$GT/tools/ab-test.sh" <<FAKE
#!/bin/sh
labels="\$(echo "\$*" | sed 's/=[^ ]*//g')"
set -- "r\$AB_ROUND \$AB_TEST \$labels"; $state
for label in \$labels; do
    mark=""
    [ "\${AB_MARK:-}" = "\$AB_ROUND:\$AB_TEST" ] && [ ! -d "\$AB_OUT/replaced" ] && mark=" BUILD RUNNING"
    echo "\$(date -u +%H:%M:%SZ) round \$AB_ROUND \$AB_TEST \$label load 1\$mark" >> "\$AB_OUT/loads.txt"
    echo '{}' > "\$AB_OUT/\$label-\$AB_TEST-round\$AB_ROUND.json"
done
sleep 0.4
FAKE
printf '#!/bin/sh\necho /fake/openmm/__init__.py fakerev\n' > "$GT/py/python"
chmod +x "$GT/tools/"*.sh "$GT/py/python"
L="$GT/tools/lease.sh"
AB="$GT/tools/ab.sh"
P="$GT/py/python"
tickets() { ls "$GT/queue" | sed 's/^[0-9]*-//' | tr '\n' ' '; }

echo "== A: unwrapped 2x2x2 screen behind a 3 s timing hold, a timing ticket queued behind the screen"
"$L" timing1 "timing hold" sleep 3 2> /dev/null &
sleep 0.5
"$AB" "$GT/A" 2 5 gbsa,rf a="$P:Metal:single" b="$P:Metal:mixed" > "$GT/A.out" 2>&1 &
ab=$!
sleep 0.5
"$L" tafter "timing after" sh -c "set -- tafter-start; $state" 2> /dev/null &
sleep 0.5
echo "queue while the screen waits: $(tickets)"
wait $ab; echo "ab.sh exit $?"
wait
cat "$GT/trace.txt"; cat "$GT/A.out"
echo "configs.txt lines: $(wc -l < "$GT/A/configs.txt" | tr -d ' '), results: $(ls "$GT/A"/*.json | wc -l | tr -d ' ')"
: > "$GT/trace.txt"

echo "== B: a screen over 18 minutes is refused before it queues"
"$AB" "$GT/B" 3 30 gbsa,rf,pme,apoa1pme,amber20-stmv a="$P:Metal:single" b="$P:Metal:single" > "$GT/B.out" 2>&1
echo "ab.sh exit $?, queue [$(tickets)], outdir entries $(ls -A "$GT/B" | wc -l | tr -d ' ')"
cat "$GT/B.out"

echo "== C: the same screen inside a window hold runs at once, no ticket; --rerun-builds reruns inside it"
OPENMM_WINDOW=1 "$L" --cap 3600 window "window" sh -c "sleep 0.3; echo \"queue during the window: \$(ls $GT/queue | wc -l | tr -d ' ') tickets\" > $GT/C-queue.txt & AB_MARK=1:gbsa $AB --rerun-builds $GT/C 3 30 gbsa,rf,pme,apoa1pme,amber20-stmv a=$P:Metal:single b=$P:Metal:single" > "$GT/C.out" 2>&1
echo "exit $?"; cat "$GT/C-queue.txt" "$GT/trace.txt" "$GT/C.out"; ls "$GT/C/replaced"
: > "$GT/trace.txt"

echo "== D: a lane that wraps ab.sh in its own lease.sh keeps one ticket"
"$L" ultra-infra "my own wrapper" "$AB" "$GT/D" 1 5 gbsa a="$P:Metal:single" > "$GT/D.out" 2>&1 &
sleep 0.2
echo "queue while it runs: $(tickets)"
wait
cat "$GT/trace.txt"; tail -2 "$GT/D.out"
: > "$GT/trace.txt"

echo "== E: AB_LANE names the lane outside ultra-<lane>/; with neither, ab.sh refuses"
"$L" timing3 "timing hold" sleep 1.5 2> /dev/null &
sleep 0.3
AB_LANE=ultra-elane "$AB" /tmp/infra-abw-E/one 1 5 gbsa a="$P:Metal:single" > "$GT/E1.out" 2>&1 &
sleep 0.5
echo "queue: $(tickets)"
wait
"$AB" /tmp/infra-abw-E/two 1 5 gbsa a="$P:Metal:single"; echo "exit $?"
echo "leftovers: lease $(ls -d "$GT/lease" 2>/dev/null || echo none), queue $(ls "$GT/queue" | wc -l | tr -d ' ')"
rm -rf /tmp/infra-abw-E
