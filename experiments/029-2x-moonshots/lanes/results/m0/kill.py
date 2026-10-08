"""M0(2) readout and bet 1 kill test: computeNonbonded on apoa1rf single, ultra-r1 against the sub-tile tree p.

Reads <label>/target.jsonl written by gdtarget.py. Per label: the shader's static stats, the dynamic instruction
count per dispatch (/performance/commands/dispN info), the dispatch's compute_kernel counters, and the counter groups
of every encoder that holds a computeNonbonded dispatch (median over those encoders; nonbonded is about 94% of each
one's cost, the rest is the concurrent bonded dispatch). Kill test (round3-plan bet 1): sub instructions per pair
slot over r1's, where sub runs LANE_STEPS of r1's pair slots (accum-nb emulator, apoa1rf, 8x4 sub-tiles, flushed
chunks sorted). Kill at 1.3x or worse at equal occupancy.
usage: python kill.py [r1 sub]
"""
import json
import statistics
import sys

M = "/tmp/openmm-metal-bench/ultra-infra/m0"
LANE_STEPS = 0.638  # accum-nb lane log 06:45Z: 8x4 sorted lane steps over today's, apoa1rf
KILL = 1.3


def docs(s):
    dec, i, found = json.JSONDecoder(), 0, []
    while i < len(s):
        if s[i] in " \r\n\t":
            i += 1
            continue
        try:
            obj, i = dec.raw_decode(s, i)
            found.append(obj)
        except ValueError:
            nl = s.find("\n", i)
            if nl < 0:
                break
            i = nl + 1
    return found


def num(v):
    if v is None:
        return None
    s = str(v).replace(",", "").replace("%", "").split()[0]
    try:
        return float(s)
    except ValueError:
        return None


def load(label):
    lists, infos = {}, {}
    for line in open(f"{M}/{label}/target.jsonl"):
        r = json.loads(line)
        for d in docs(r["out"]):
            if not isinstance(d, dict):
                continue
            if isinstance(d.get("children"), list):
                if len(d["children"]) >= len(lists.get(r["path"], [])):
                    lists[r["path"]] = d["children"]
            elif r["cmd"][-1] == "info --all":
                infos[r["path"]] = d
    return lists, infos


def values(children):
    out = {}
    for c in children:
        vals = [v.get("value") for v in c.get("values") or [] if isinstance(v, dict)]
        out[c["name"]] = vals[0] if vals else None
    return out


def readout(label):
    lists, infos = load(label)
    comp = next(name for name, fn in values(lists["/performance/shaders"]).items() if fn == "computeNonbonded")
    shader = infos[f"/performance/shaders/{comp}"]
    disp = [p for p in infos if p.startswith("/performance/commands/disp") and infos[p].get("Shaders") == "computeNonbonded"]
    instr = [num(infos[p]["Instructions"]) for p in disp]
    ck = {}
    for p in disp:
        for k, v in values(lists.get(p + "/counters/compute_kernel", [])).items():
            if num(v) is not None:
                ck.setdefault(k, []).append(num(v))
    enc = [p.rsplit("/", 1)[0] for p, kids in lists.items() if p.endswith("/commands") and p.startswith(
        "/performance/encoders/") and any('computeNonbonded' in json.dumps(c) for c in kids)]
    groups = {}
    for e in enc:
        for g in ("performance_limiters", "memory", "compute_kernel"):
            for k, v in values(lists.get(f"{e}/counters/{g}", [])).items():
                if num(v) is not None:
                    groups.setdefault(k, []).append(num(v))
    tl = {}
    for p, kids in lists.items():
        if p.startswith("/performance/timeline/counters/"):
            for k, v in values(kids).items():
                if num(v) is not None:
                    tl[k] = num(v)
    enc_names = {e.rsplit("/", 1)[1] for e in enc}
    durs = [c["values"][3]["value"] for c in lists["/performance/timeline/encoders"] if c["name"] in enc_names]
    return {"shader": shader, "instr": instr, "dur": durs, "ck": {k: statistics.median(v) for k, v in ck.items()},
            "enc": {k: statistics.median(v) for k, v in groups.items()}, "n_enc": len(enc), "tl": tl}


labels = sys.argv[1:] or ["r1", "sub"]
R = {l: readout(l) for l in labels}
print("computeNonbonded, apoa1rf single, gpudebug profile of 12 command buffers (gpucapture), M3 Ultra\n")
print("| metric | " + " | ".join(labels) + " |")
print("|---|" + "---:|" * len(labels))


def row(name, f):
    print(f"| {name} | " + " | ".join(f(R[l]) for l in labels) + " |")


for key in ("Instructions", "ALU", "FP32", "INT32", "INT16", "Branch", "Device atomics", "Device loads",
            "Temp registers", "Uniform registers", "Spilled bytes", "SIMD groups"):
    row(f"static {key}", lambda r, k=key: str(r["shader"].get(k, "-")))
row("dispatches", lambda r: str(len(r["instr"])))
row("dynamic instructions per dispatch (median)", lambda r: f"{statistics.median(r['instr']):.4g}")
row("encoder GPU time, us (median)", lambda r: f"{statistics.median(r['dur']) / 1000:.1f}")
for key in ("kernel_invocations", "kernel_alu_instructions", "kernel_alu_float_instructions",
            "kernel_alu_integer_and_conditional_instructions", "kernel_alu_inefficiency"):
    row(f"dispatch {key} (median)", lambda r, k=key: f"{r['ck'][k]:.4g}" if k in r["ck"] else "-")
for key in ("kernel_occupancy", "occupancy_manager_target", "alu_utilization", "f32_limiter",
            "integer_and_conditional_limiter", "instruction_throughput_limiter", "instruction_throughput_utilization",
            "l1_total_residency", "l1_register_residency", "l1_buffer_residency", "l1_eviction_rate",
            "buffer_l1_miss_rate", "l1_cache_limiter", "buffer_l1_read_accesses", "stack_l1_read_accesses",
            "stack_l1_write_accesses", "register_l1_read_accesses", "compute_shader_launch_limiter"):
    row(f"encoder {key} (median)", lambda r, k=key: f"{r['enc'][k]:.4g}" if k in r["enc"] else "-")
row("encoders with computeNonbonded", lambda r: str(r["n_enc"]))

if "r1" in R and "sub" in R:
    a, b = R["r1"], R["sub"]
    ratios = {
        "instructions (dispatch info)": statistics.median(b["instr"]) / statistics.median(a["instr"]),
        "ALU instructions (dispatch counter)": b["ck"]["kernel_alu_instructions"] / a["ck"]["kernel_alu_instructions"],
        "GPU time (encoder)": statistics.median(b["dur"]) / statistics.median(a["dur"]),
    }
    print(f"\nPair slots, sub over r1: {LANE_STEPS} (accum-nb emulator, apoa1rf, sorted 8x4). Kill at {KILL}x per slot.")
    for name, r in ratios.items():
        print(f"- {name}: sub/r1 {r:.3f} per dispatch, {r / LANE_STEPS:.2f}x per pair slot")
    per_slot = min(r / LANE_STEPS for name, r in ratios.items() if "instructions" in name)
    print(f"Occupancy (encoder median): sub {b['enc']['kernel_occupancy']:.1f}%, r1 {a['enc']['kernel_occupancy']:.1f}%; "
          f"occupancy manager target sub {b['enc']['occupancy_manager_target']:.1f}%, r1 {a['enc']['occupancy_manager_target']:.1f}%.")
    print("Verdict: " + ("KILL" if per_slot >= KILL else "PASS") + f" (lower of the two instruction measures {per_slot:.2f}x per slot).")
