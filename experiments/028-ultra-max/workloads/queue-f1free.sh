#!/bin/sh
# f1-independent tickets on ultra-base, same forms as the 22:55Z tickets the lead pruned, with item 1's CPU arm
# split into its own timing ticket.
D=/tmp/openmm-metal-bench/ultra-workloads
T=/tmp/openmm-metal-bench/ultra-tools
P=/tmp/openmm-metal-bench/ultra-base/venv/bin/python
for d in item1-cell-m item1-cell-cpu; do [ -e "$D/$d" ] && { echo "$D/$d exists" >&2; exit 1; }; done
q() {
    name=$1; shift
    nohup "$T/lease.sh" ultra-workloads "$@" > "$D/$name.q2.out" 2>&1 < /dev/null &
    echo "$(date -u +%H:%M:%SZ) $name $!" | tee -a "$D/tickets.pid"
    sleep 2
}
q item1-cell-m "item1 round1 amber20-cellulose: Metal mixed, Metal single, 30 s, ~4 min" \
    "$T/ab.sh" "$D/item1-cell-m" 1 30 amber20-cellulose "mmixed=$P:Metal:mixed" "msingle=$P:Metal:single"
q item1-cell-cpu "item1 round1 amber20-cellulose: CPU platform (28 threads) only, 30 s, ~4 min" \
    "$T/ab.sh" "$D/item1-cell-cpu" 1 30 amber20-cellulose "cpu=$P:CPU:mixed"
q sync "item3 host-sync probe: gbsa, 5 modes x Metal/OpenCL single, 3 rounds, ~7 min" \
    "$D/wl-run.sh" "$D/sync.jsonl" 3 "sync Metal custom-sum" "sync OpenCL custom-sum" "sync Metal custom-nosum" "sync OpenCL custom-nosum" \
    "sync Metal loop-energy" "sync OpenCL loop-energy" "sync Metal loop-nosync" "sync OpenCL loop-nosync" "sync Metal pipelined" "sync OpenCL pipelined"
q ctx "item4 context creation: pme,apoa1pme x Metal/OpenCL x unique/proc, 3 rounds, ~10 min" \
    "$D/wl-run.sh" "$D/ctx.jsonl" 3 "ctx Metal pme unique" "ctx OpenCL pme unique" "ctx Metal apoa1pme unique" "ctx OpenCL apoa1pme unique" \
    "ctx Metal pme proc" "ctx OpenCL pme proc" "ctx Metal apoa1pme proc" "ctx OpenCL apoa1pme proc"
q min200 "item5 minimize apoa1pme 200 iterations: Metal mixed/single, OpenCL single, CPU, 3 rounds, ~6 min" \
    "$D/wl-run.sh" "$D/min200.jsonl" 3 "min Metal mixed 200" "min CPU mixed 200" "min Metal single 200" "min OpenCL single 200"
q minconv "item5 minimize apoa1pme to convergence: Metal mixed/single, OpenCL single, CPU, 2 rounds, ~12 min" \
    "$D/wl-run.sh" "$D/minconv.jsonl" 2 "min Metal mixed 0" "min CPU mixed 0" "min Metal single 0" "min OpenCL single 0"
