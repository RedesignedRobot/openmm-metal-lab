#!/bin/sh
# covers: gpuprof.sh gpuprof.patch profsum.py prof.py   (install.sh runs this test when one of these changes)
# No GPU. gpuprof.patch applies to trunk's source (the pinned ultra-r2-fah-trunk tree, dry run), prof.py and
# gpuprof.sh parse, and profsum.py gets known numbers back from made-up records of 100 steps:
# - buffers: windows 100/102/100 us, one 80 us command buffer per step, so busy 80, idle 22, ratio 1.020.
# - split: windows 100/107/100, so the split price is +0.050 of a step, +5.00 us.
# - counters: windows 100/110/100, one 88 us buffer per step holding k1 0-50 us, k2 40-80 us (10 us overlap),
#   an indirect encoder u with no stamps (zeros on even steps, stale ticks on odd ones, as the M3 Ultra leaves
#   them) and a blit 83-85 us. u gets the 80-83 us bracket. Union 85, sum 95, attributed k1 45, k2 35, u 3,
#   blit 2. Validation 85 against 110-22 = 88, -3.4%, PASS; against the buffers run's busy 80, +6.2%.
# - a second target whose counters cover only 40 us of the 88 fails validation. Its unstamped encoder u has a
#   zero-length bracket (k1 ends at 40 us, k3 starts there), which must not keep a share of later time.
# usage: tests/gpuprof.sh [scratch dir]
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
scratch=${1:-$(mktemp -d /tmp/openmm-metal-bench/gpuprof-test.XXXXXX)}
tree=${INSTALL_TEST_TREE:-/tmp/openmm-metal-bench/ultra-r2-fah-trunk}
PY=/tmp/openmm-metal-bench/env/bin/python3
mkdir -p "$scratch"
fails=0
check() {
    if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails+1)); fi
}

check "gpuprof.patch applies to $tree/src" "patch -p1 --dry-run -s -d '$tree/src' < '$here/gpuprof.patch' > '$scratch/patch.out' 2>&1"
check "prof.py compiles" "'$PY' -m py_compile '$here/prof.py'"
check "gpuprof.sh parses" "sh -n '$here/gpuprof.sh'"
check "gpuprof.sh run refuses a tree with no build" "! sh '$here/gpuprof.sh' run no-such-tree '$scratch/out' mixed pme 2> /dev/null"

"$PY" - "$scratch" <<'PY'
import os, sys
out = sys.argv[1]
def windows(tag, mode, a, b, c):
    with open(f"{out}/{tag}-{mode}.txt", "w") as f:
        for name, us in zip("ABC", (a, b, c)):
            f.write(f"window {name} {tag} mixed Metal steps 100 host_s {us*1e-4:.6f} us_per_step {us:.2f} ns_per_day 1 cpu_per_host 1.00\n")
def records(tag, mode, gpu_us, encoders):
    with open(f"{out}/{tag}-{mode}.rec", "w") as f:
        f.write("t 1 1\n")
        if encoders:
            f.write("c 0 0\nc 1000 1000\n")
        for i in range(100):
            start = 1e-3+i*100e-6
            f.write(f"b {start:.9f} {start+gpu_us*1e-6:.9f} {start:.9f} k1 k2 {start:.9f} 2 1 0\n")
            for name, t0, t1 in encoders:
                if name.startswith("u "):
                    f.write(f"e {name} {0 if i % 2 == 0 else 5000} {0 if i % 2 == 0 else 6000}\n")
                    continue
                f.write(f"e {name} {int(10**6+i*100000+t0*1000)} {int(10**6+i*100000+t1*1000)}\n")
            f.write("w finish 0.000002 0\n")
for tag in ("sys-mixed", "bad-mixed"):
    windows(tag, "buffers", 100, 102, 100)
    records(tag, "buffers", 80, [])
    windows(tag, "split", 100, 107, 100)
    records(tag, "split", 84, [])
    windows(tag, "counters", 100, 110, 100)
encoders = [("k1 10 64", 0, 50), ("k2 20 64", 40, 80), ("u 0 32", 0, 0), ("blit 1 1", 83, 85)]
records("sys-mixed", "counters", 88, encoders)
records("bad-mixed", "counters", 88, [("k1 10 64", 0, 40), ("u 0 32", 0, 0), ("k3 30 64", 40, 40)])
PY
"$PY" "$here/profsum.py" "$scratch" sys-mixed > "$scratch/sys.sum" 2>&1
"$PY" "$here/profsum.py" "$scratch" bad-mixed > "$scratch/bad.sum" 2>&1
has() { grep -qF -- "$2" "$scratch/$1"; }
check "buffers busy and idle" "has sys.sum 'buffers: us/step A 100.00 B 102.00 C 100.00, B/mean(A,C) 1.020; GPU busy 80.00, idle 22.00'"
check "host waits" "has sys.sum 'host waits: finish 2.00 us (1.00/step)'"
check "split price" "has sys.sum 'split price: +0.050 of step time, +5.00 us/step'"
check "encoder sum and union" "has sys.sum 'encoder sum 95.00 us/step, union 85.00 us/step'"
check "validation passes" "has sys.sum 'validation: union 85.00 against window B minus idle 88.00 us/step, -3.4%: PASS'"
check "against buffers busy" "has sys.sum 'against the buffers run'\"'\"'s GPU busy 80.00 us/step: +6.2%'"
check "k1 attributed 45" "has sys.sum '| k1 10x64 | 1.00 | 45.00 | 52.9% | 50.00 | 50.00 |'"
check "k2 attributed 35" "has sys.sum '| k2 20x64 | 1.00 | 35.00 | 41.2% | 40.00 | 40.00 |'"
check "unstamped u gets its bracket" "has sys.sum '| unstamped u | 1.00 | 3.00 | 3.5% | 3.00 | 3.00 |'"
check "blit attributed 2" "has sys.sum '| blit 1x1 | 1.00 | 2.00 | 2.4% | 2.00 | 2.00 |'"
check "json line" "grep -q '^json {' '$scratch/sys.sum'"
check "a zero-length bracket keeps no share" "has bad.sum '| k1 10x64 | 1.00 | 40.00 | 100.0% | 40.00 | 40.00 |'"
check "short coverage fails validation" "has bad.sum 'validation: union 40.00 against window B minus idle 88.00 us/step, -54.5%: FAIL'"

[ -n "${1:-}" ] || rm -rf "$scratch"
[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
