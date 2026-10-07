#!/bin/sh
# abw.py refusals and lease self-wrap against a private copy whose TOOLS dir holds a fake lease.sh that
# records its arguments and runs the command. Never touches the real lease or queue.
set -u
T=/tmp/openmm-metal-bench/ultra-workloads/abwtest
P=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
rm -rf "$T"
mkdir -p "$T/tools"
sed "s|^TOOLS = .*|TOOLS = '$T/tools'|" /tmp/openmm-metal-bench/ultra-workloads/abw.py > "$T/abw.py"
cp /tmp/openmm-metal-bench/ultra-tools/srchash.sh "$T/tools/"
cat > "$T/tools/lease.sh" <<FAKE
#!/bin/sh
echo "lease.sh \$1 | \$2 | AB_HELD=\${AB_HELD:-unset}" >> $T/lease-calls.txt
shift 2
exec "\$@"
FAKE
chmod +x "$T/tools/lease.sh"
O=/tmp/openmm-metal-bench/ultra-workloads/abwtest/out
C="cpu=$P:CPU:mixed:OPENMM_CPU_THREADS=2"
try() {
    name="$1"; shift
    printf '%s: ' "$name"
    out="$("$@" 2>&1)"
    code=$?
    echo "exit $code $(echo "$out" | tail -1)"
}
try "nice 5" nice -n 5 "$P" "$T/abw.py" "$O/a" 1 3 gbsa "$C"
try "relative outdir" "$P" "$T/abw.py" rel/a 1 3 gbsa "$C"
try "no lane" env -u AB_LANE "$P" "$T/abw.py" /tmp/abw-nolane 1 3 gbsa "$C"
mkdir -p "$O/full" && touch "$O/full/x"
try "non-empty outdir" "$P" "$T/abw.py" "$O/full" 1 3 gbsa "$C"
try "bad label" "$P" "$T/abw.py" "$O/b" 1 3 gbsa "c:pu=$P:CPU:mixed"
try "label twice" "$P" "$T/abw.py" "$O/c" 1 3 gbsa "$C" "$C"
try "relative python" "$P" "$T/abw.py" "$O/d" 1 3 gbsa "x=venv/bin/python:CPU:mixed"
try "cold unknown label" "$P" "$T/abw.py" --cold nope "$O/e" 1 3 gbsa "$C"
try "Metal under --validate" "$P" "$T/abw.py" --validate "$O/f" 1 3 gbsa "m=$P:Metal:single"
try "Reference without --validate" "$P" "$T/abw.py" "$O/g" 1 3 gbsa "r=$P:Reference:double"
try "OpenCL mixed" "$P" "$T/abw.py" "$O/h" 1 3 gbsa "o=$P:OpenCL:mixed"
try "over 18 min" "$P" "$T/abw.py" "$O/i" 10 60 gbsa,rf "$C" "cpu2=$P:CPU:mixed"
echo "lease calls so far: $(cat "$T/lease-calls.txt" 2>/dev/null | wc -l | tr -d ' ')"
echo "self-wrap run:"
"$P" "$T/abw.py" "$O/wrap" 1 3 gbsa "$C" 2>&1 | grep -v '^ *$' | cut -c1-110
cat "$T/lease-calls.txt"
ls "$O/wrap"
