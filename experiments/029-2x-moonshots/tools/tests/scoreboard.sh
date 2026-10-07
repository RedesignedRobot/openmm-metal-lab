#!/bin/sh
# covers: summarize.py scoreboard.py   (install.sh runs this test when one of these changes)
# summarize.py's result.json and scoreboard.py on a made-up window with known numbers, no GPU.
# usage: tests/scoreboard.sh [scratch dir]
set -u
TOOLS=$(cd "$(dirname "$0")/.." && pwd)
PY=/tmp/openmm-metal-bench/env/bin/python3
S=${1:-/tmp/openmm-metal-bench/ultra-r3-tools/scoreboard-test}
W=$S/w9
rm -rf "$S"
mkdir -p $W/ab
fail=0
ok() { echo "  PASS $*"; }
bad() { echo "  FAIL $*"; fail=1; }

# Two rounds of gbsa and rf. OpenCL is 100 (gbsa) and 50 (rf); a-single 210/190 and 110/110, a-mixed 150/170 and
# 100/100, b-single 220/220 and 100/100. Round 2 of rf ran again (a rerun drops the first round-2 lines).
$PY - $W/ab <<'EOF'
import json, sys
out = sys.argv[1]
ns = {"base-opencl": {"gbsa": (100, 100), "rf": (50, 50)}, "a-single": {"gbsa": (210, 190), "rf": (110, 110)},
      "a-mixed": {"gbsa": (150, 170), "rf": (100, 100)}, "b-single": {"gbsa": (220, 220), "rf": (100, 100)}}
for label, tests in ns.items():
    for test, values in tests.items():
        for r, v in enumerate(values, 1):
            json.dump({"benchmarks": [{"test": test, "ns_per_day": v}]}, open(f"{out}/{label}-{test}-round{r}.json", "w"))
trees = {"base": ("OpenCL", "single", "/tmp/openmm-metal-bench/ultra-t3", "c0ffee000", "5c0000"),
         "a": ("Metal", None, "/tmp/openmm-metal-bench/ultra-trunk", "aaaa11112", "5a0000"),
         "b": ("Metal", None, "/tmp/openmm-metal-bench/ultra-cand", "bbbb22223", "5b0000")}
with open(f"{out}/configs.txt", "w") as f:
    for label in ns:
        platform, precision, tree, commit, src = trees[label.rsplit("-", 1)[0]]
        f.write(f"{label} {platform} {precision or label.rsplit('-', 1)[1]} settings=none {tree}/venv/lib/openmm/__init__.py"
                f" Unknown commit {commit} src {src} toolchain clang built 2026-09-29T00:00:00Z\n")
lines, t = [], 0
for r in (1, 2):
    for test in ("gbsa", "rf"):
        for label in ns:
            t += 40
            mark = " FOREIGN GPU 8%" if (r, test, label) == (1, "gbsa", "a-mixed") else ""
            vm = 95 if (r, test, label) == (2, "gbsa", "b-single") else 5
            lines.append(f"2026-09-30T01:{t // 60:02d}:{t % 60:02d}Z round {r} {test} {label} load {{ 1.00 1.00 1.00 }}{mark} vm {vm}% top x 1%")
lines.insert(-2, "2026-09-30T01:40:00Z round 2 rf a-mixed load { 1.00 1.00 1.00 } BUILD RUNNING vm 5% top ninja 900%")
lines.append("2026-09-30T01:41:00Z rerun round 2 rf: a build or a busy CPU overlapped it")
open(f"{out}/loads.txt", "w").write("\n".join(lines) + "\n")
import sqlite3
db = sqlite3.connect(f"{out}/../../state.db")
db.execute("CREATE TABLE jobs(id INTEGER PRIMARY KEY, argv TEXT)")
db.execute("INSERT INTO jobs VALUES(6, ?)", (json.dumps(["/bin/sh", "-c", "window.sh /tmp/x/w9b all"]),))
db.execute("INSERT INTO jobs VALUES(7, ?)", (json.dumps(["/bin/sh", "-c", f"window.sh {out[:-3]} all a=x:single"]),))
db.commit()
EOF

echo "== 1: summarize.py writes result.json"
GPUQ_DB=$S/state.db GPUCLOCK_LOG=/dev/null $PY $TOOLS/summarize.py $W/ab a-single/base-opencl a-mixed/base-opencl b-single/base-opencl > $S/summary.txt \
    || bad "summarize.py exited $?"
$PY - $W/ab/result.json <<'EOF' || fail=1
import json, sys
r = json.load(open(sys.argv[1]))
row = {(x["test"], x["label"]): x for x in r["rows"]}
checks = [
    ("slot night", r["slot"] == "night"),
    ("gpuq job 7 from the window's command (not 6, w9b)", r["gpuq_job"] == 7),
    ("a-single gbsa median 200, spread 10%", row[("gbsa", "a-single")]["median"] == 200 and abs(row[("gbsa", "a-single")]["spread"] - 0.1) < 1e-9),
    ("arm b-single: tree, commit, src", r["arms"]["b-single"]["tree"] == "/tmp/openmm-metal-bench/ultra-cand"
     and r["arms"]["b-single"]["commit"] == "bbbb22223" and r["arms"]["b-single"]["src"] == "5b0000"),
    ("ratio a-mixed/base-opencl gbsa 1.6", any(x["num"] == "a-mixed" and x["test"] == "gbsa" and abs(x["ratio"] - 1.6) < 1e-9 for x in r["ratios"])),
    ("1 FOREIGN GPU run", len(r["hygiene"]["foreign_gpu"]) == 1),
    ("1 run with the VM at 90% or more", len(r["hygiene"]["vm_high"]) == 1),
    ("the rerun dropped the build overlap", r["hygiene"]["build_overlap"] == []),
]
for name, good in checks:
    print(f"  {'PASS' if good else 'FAIL'} {name}")
sys.exit(0 if all(good for _, good in checks) else 1)
EOF

echo "== 2: scoreboard.py"
$PY $TOOLS/scoreboard.py $W -o $S/SCOREBOARD.md || bad "scoreboard.py exited $?"
for want in "| gbsa | 2.000 | 1.600 | 2.200 |" "| rf | 2.200 | 2.000 | 2.000 |" "- a-single: 2 of 2 at or over 2x." \
    "- a-mixed: 1 of 2 at or over 2x." "| a-mixed | gbsa | 1.600 | 20.0% |" "## Against a, same precision" \
    "| gbsa | 1.100 (1.048..1.158) |" "| rf | 0.909 (0.909..0.909) |" "gpuq job 7" "Night slot, 2 interleaved rounds" \
    "- 1 FOREIGN GPU" "- 1 Background VM CPU at 90% or more:" "| b-single | /tmp/openmm-metal-bench/ultra-cand | bbbb22223 | 5b0000 |"; do
    grep -qF -- "$want" $S/SCOREBOARD.md && ok "$want" || bad "missing: $want"
done
$PY $TOOLS/scoreboard.py $W --ref b | grep -qF "## Against b, same precision" && ok "--ref b" || bad "--ref b"

rm -rf "$S"
echo "result: $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
