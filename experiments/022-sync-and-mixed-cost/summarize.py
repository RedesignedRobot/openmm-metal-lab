"""Turn the JSON lines written by run.sh into the Markdown tables in README.md.

usage: summarize.py <out-dir>
Reads whichever of p1.jsonl, bits.jsonl, energy.jsonl, time.jsonl, ab.jsonl, census.jsonl and p3diag.jsonl
exist in <out-dir>.
Speeds are the host wall clock (fahwu.py or benchmark.py); profile numbers are per step inside the profiler's window
(after 200 steps), with blocked-wait times on the host's mach_absolute_time clock and GPU busy
time and gaps from the command buffers' GPUStartTime/GPUEndTime.
"""
import json
import os
import statistics
import sys
from collections import defaultdict

WUS = ["dhfr", "nav", "dhfr-implicit", "dhfr-hbonds"]
PRECISIONS = ["single", "mixed"]
CCMA_ITERATION = "updateCCMAAtomPositionsKernel"
CCMA_CALL = "computeCCMAConstraintDirectionsKernel"


def read(out, name):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return []
    return [json.loads(line) for line in open(path) if line.strip()]


def table(header, rows):
    lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    lines += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(lines)


def wall_us(run):
    return 1e6 * run["run"]["wall_s"] / run["run"]["steps"]


def sync_summary(syncs):
    """Total per-step count and wait of a finish or event_wait map, plus its largest entries."""
    count = sum(s["per_step"] for s in syncs.values())
    wait = sum(s["wait_us_per_step"] for s in syncs.values())
    top = sorted(syncs.items(), key=lambda kv: -kv[1]["wait_us_per_step"])[:3]
    detail = "; ".join(f"{k} {v['per_step']:.2f}/{v['wait_us_per_step']:.0f}us" for k, v in top)
    return count, wait, detail


def ccma_iterations(profile):
    d = profile["dispatch_per_step"]
    return f"{d[CCMA_ITERATION] / d[CCMA_CALL]:.1f}" if d.get(CCMA_CALL) else "-"


def p1(runs):
    by = defaultdict(list)
    for r in runs:
        by[(r["run"]["wu"], r["run"]["precision"], r["mode"])].append(r)
    rows, overhead = [], []
    for wu in WUS:
        for prec in PRECISIONS:
            off, census = by.get((wu, prec, "0")), by.get((wu, prec, "1"))
            if not off or not census:
                continue
            off, census = off[0], census[0]
            p = census["profile"]
            fin_n, fin_us, fin_top = sync_summary(p["finish"])
            ev_n, ev_us, ev_top = sync_summary(p["event_wait"])
            g = p["gpu"]
            rows.append([wu, prec, f"{off['run']['ns_per_day']:.1f}", f"{wall_us(off):.0f}",
                         f"{p['wall_us_per_step']:.0f}", f"{p['commits_per_step']:.2f}", f"{p['dispatches_per_step']:.0f}",
                         f"{fin_n:.2f}", f"{fin_us:.0f}", fin_top, f"{ev_n:.2f}", f"{ev_us:.0f}", ev_top,
                         ccma_iterations(p), f"{g['busy_us_per_step']:.0f}", f"{g['busy_fraction']:.3f}",
                         f"{g['gaps_per_step']:.2f}", f"{g['gap_us_per_step']:.0f}"])
            overhead.append([wu, prec, f"{wall_us(off):.0f}", f"{wall_us(census):.0f}",
                             f"{100 * (wall_us(census) / wall_us(off) - 1):+.1f}%"])
    out = ["### Per-step census (OPENMM_METAL_PROFILE=1; ns/day and wall from the profiling-off run)", "",
           table(["WU", "precision", "ns/day (off)", "wall us/step (off)", "wall us/step (census)", "commits",
                  "dispatches", "finish()", "finish wait us", "top finish: cause:array n/wait", "event waits",
                  "event wait us", "top event: n/wait", "CCMA iter/call", "GPU busy us", "busy fraction",
                  "gaps", "gap us"], rows), "",
           "### Census overhead (host wall us/step)", "",
           table(["WU", "precision", "off", "census", "change"], overhead), ""]
    for wu in WUS:
        for prec in PRECISIONS:
            census = by.get((wu, prec, "1"))
            if census:
                sites = census[0]["profile"]["gpu"]["gap_sites"][:6]
                out += [f"#### Gap sites, {wu} {prec}", "",
                        table(["after", "before", "per step", "us/step"],
                              [[s["after"], s["before"], f"{s['per_step']:.2f}", f"{s['us_per_step']:.1f}"] for s in sites]), ""]
    out += kernels(by)
    return out


def kernels(by):
    out = []
    for wu in WUS:
        single, mixed = by.get((wu, "single", "kernels")), by.get((wu, "mixed", "kernels"))
        if not single or not mixed:
            continue
        s, m = single[0]["profile"]["kernel_gpu_us_per_step"], mixed[0]["profile"]["kernel_gpu_us_per_step"]
        names = sorted(set(s) | set(m), key=lambda k: -(m.get(k, 0) - s.get(k, 0)))
        total_s, total_m = sum(s.values()), sum(m.values())
        rows = [[k, f"{s.get(k, 0):.1f}", f"{m.get(k, 0):.1f}", f"{m.get(k, 0) - s.get(k, 0):+.1f}",
                 f"{100 * (m.get(k, 0) - s.get(k, 0)) / (total_m - total_s):.0f}%" if total_m != total_s else "-"]
                for k in names[:15]]
        rows.append(["(all kernels)", f"{total_s:.1f}", f"{total_m:.1f}", f"{total_m - total_s:+.1f}", "100%"])
        out += [f"### Kernel GPU time per step, {wu} (OPENMM_METAL_PROFILE=kernels, one buffer per dispatch)", "",
                table(["kernel", "single us", "mixed us", "mixed - single", "share of gap"], rows), ""]
    return out


def bits(runs):
    """Digests per variant and repeat, and whether the state matches base's first repeat bit for bit.

    Energies are listed but not part of the match: the platform's energy sum is not reproducible from
    one context to the next even for one build (see energy())."""
    fields = ["positions_sha256", "velocities_sha256", "forces_sha256"]
    rows = []
    groups = defaultdict(list)
    for r in runs:
        groups[(r["wu"], r["precision"])].append(r)
    for (wu, prec), rs in sorted(groups.items()):
        ref = next((r for r in rs if r["variant"] == "base" and r["rep"] == 1), None)
        for r in sorted(rs, key=lambda r: (r["variant"] != "base", r["variant"], r["rep"])):
            same = "-" if ref is None else "yes" if all(r[f] == ref[f] for f in fields) else \
                "NO: " + ", ".join(f.split("_")[0] for f in fields if r[f] != ref[f])
            rows.append([wu, prec, r["variant"], r["rep"]] + [r[f][:8] for f in fields] +
                        [r["energies_sha256"][:8], f"{r['final_potential_kj']:.6f}", same])
    return ["### State after 1000 steps (energy requested every 100), SHA-256 prefixes", "",
            table(["WU", "precision", "variant", "rep", "positions", "velocities", "forces",
                   "energies (10 x PE, KE)", "final PE kJ/mol", "positions, velocities, forces = base rep 1"],
                  rows), ""]


def energy(runs):
    """Start-state potential energy: the values seen in each context, per variant."""
    groups = defaultdict(lambda: defaultdict(list))
    for r in runs:
        groups[(r["wu"], r["precision"])][r["variant"]].append(r)
    rows = []
    for (wu, prec), variants in sorted(groups.items()):
        everything = [float.fromhex(v) for rs in variants.values() for r in rs for v in r["values_hex"]]
        for variant, rs in sorted(variants.items(), key=lambda kv: (kv[0] != "base", kv[0])):
            rows.append([wu, prec, variant, len(rs), " ".join(str(r["distinct"]) for r in rs),
                         " ".join(f"{float.fromhex(r['values_hex'][0]):.6f}" for r in rs),
                         f"{max(everything) - min(everything):.3g}"])
    return ["### Start-state potential energy, 50 evaluations per context (kJ/mol)", "",
            table(["WU", "precision", "variant", "contexts", "distinct values per context",
                   "value per context", "spread over all variants and contexts"], rows), ""]


def timed(runs, title):
    """ns/day per round, median and range per cell, relative to base and to OpenCL single."""
    groups = defaultdict(list)
    for r in runs:
        groups[(r["run"]["wu"], r["run"]["precision"], r["run"]["platform"], r["variant"])].append(r["run"]["ns_per_day"])
    median = {k: statistics.median(v) for k, v in groups.items()}
    opencl = {w: m for (w, q, p, _), m in median.items() if (q, p) == ("single", "OpenCL")}
    rows = []
    order = lambda k: (WUS.index(k[0]) if k[0] in WUS else 99, k[1] != "single", k[2] != "Metal", k[3])
    for key in sorted(groups, key=order):
        wu, precision, platform, variant = key
        base = median.get((wu, precision, "Metal", "base"))
        rows.append([wu, precision, platform, variant, " ".join(f"{n:.1f}" for n in groups[key]),
                     f"{median[key]:.1f}", f"{max(groups[key]) - min(groups[key]):.1f}",
                     f"{median[key] / base:.3f}" if base and platform == "Metal" else "-",
                     f"{median[key] / opencl[wu]:.3f}" if wu in opencl else "-"])
    return [f"### {title}", "",
            table(["WU", "precision", "platform", "variant", "ns/day per round", "median", "range",
                   "/ base", "/ OpenCL single"], rows), ""]


def census(runs, title):
    """Sync census of every mode-1 run, one row per run."""
    rows = []
    for r in runs:
        if r["mode"] != "1":
            continue
        p = r["profile"]
        fin_n, fin_us, _ = sync_summary(p["finish"])
        ev_n, ev_us, _ = sync_summary(p["event_wait"])
        rows.append([r["variant"], r["run"]["wu"], r["run"]["precision"], f"{p['wall_us_per_step']:.0f}",
                     f"{p['commits_per_step']:.2f}", f"{fin_n:.2f}", f"{fin_us:.0f}", f"{ev_n:.2f}", f"{ev_us:.0f}",
                     ccma_iterations(p), f"{p['gpu']['busy_us_per_step']:.0f}", f"{p['gpu']['busy_fraction']:.3f}",
                     f"{p['gpu']['gap_us_per_step']:.0f}"])
    return [f"### {title}", "",
            table(["variant", "WU", "precision", "wall us/step (census)", "commits", "finish()", "finish wait us",
                   "event waits", "event wait us", "CCMA iter/call (dispatched)", "GPU busy us", "busy fraction",
                   "gap us"], sorted(rows, key=lambda r: (r[1], r[2], r[0]))), ""]


def guard_kernels(runs):
    """computeNonbonded and total kernel GPU time, base-prof against p3-prof."""
    kernels = {(r["variant"], r["run"]["wu"], r["run"]["precision"]): r["profile"]["kernel_gpu_us_per_step"]
               for r in runs if r["mode"] == "kernels"}
    rows = []
    for (v, wu, prec), k in sorted(kernels.items()):
        if v != "p3-prof" or ("base-prof", wu, prec) not in kernels:
            continue
        b = kernels[("base-prof", wu, prec)]
        rows.append([wu, prec, f"{b.get('computeNonbonded', 0):.1f}", f"{k.get('computeNonbonded', 0):.1f}",
                     f"{sum(b.values()):.1f}", f"{sum(k.values()):.1f}"])
    return ["### Energy guard: kernel GPU us/step (OPENMM_METAL_PROFILE=kernels), base-prof vs p3-prof", "",
            table(["WU", "precision", "computeNonbonded base", "computeNonbonded p3", "all kernels base",
                   "all kernels p3"], rows), ""]


def main():
    out = sys.argv[1]
    lines = []
    if runs := read(out, "p1.jsonl"):
        lines += p1(runs)
    if runs := read(out, "bits.jsonl"):
        lines += bits(runs)
    if runs := read(out, "energy.jsonl"):
        lines += energy(runs)
    if runs := read(out, "time.jsonl"):
        lines += timed(runs, "End-to-end speed, ns/day (host wall clock: fahwu.py time.perf_counter over whole "
                             "steps, 60 s after 200 warm-up steps, 3 interleaved rounds)")
    if runs := read(out, "ab.jsonl"):
        lines += timed(runs, "CCMA A/B, ns/day (host wall clock as above; dhfr-hbonds = heavy-atom constraints "
                             "as bonds, 3 interleaved rounds)")
    if runs := read(out, "census.jsonl"):
        p1_runs = [r for r in read(out, "p1.jsonl") if r["run"]["wu"] in ("dhfr", "nav")]
        lines += census(runs + p1_runs, "Census per variant (OPENMM_METAL_PROFILE=1, 30 s)")
        lines += guard_kernels(runs + p1_runs)
    if runs := read(out, "p3diag.jsonl"):
        lines += timed(runs, "p3 alone on dhfr single: ns/day (host wall clock as above, 30 s runs, 3 interleaved "
                             "rounds; the -prof variants have the census on)")
        lines += census(runs, "p3 alone on dhfr single: census per round")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
