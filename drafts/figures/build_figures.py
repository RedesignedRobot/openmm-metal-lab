"""Build the SVG figures for the Metal platform PR and report from the raw 017 results.

usage: python3 build_figures.py
Reads experiments/017-three-chips/results and writes one SVG per figure next to this script.
The SVGs carry classes, not colours (c-ms, c-m2, ax, grid, ...): the page that inlines them sets
the palette, so the same file works in light and dark themes. No dependencies beyond the stdlib.
"""
import glob
import json
import math
import os
import statistics as st
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "../../experiments/017-three-chips/results")
CHIPS = [("m2", "M2", 10), ("m3pro", "M3 Pro", 18), ("m3ultra", "M3 Ultra", 60)]
CONFIGS = [("Metal", "single", "Metal single", "c-ms"), ("Metal", "mixed", "Metal mixed", "c-mm"),
           ("OpenCL", "single", "OpenCL single", "c-ocl"), ("CPU", "native", "CPU", "c-cpu")]
WUS = [("dhfr-implicit", "dhfr-implicit · 2.5k atoms"), ("dhfr", "dhfr · 23.6k atoms, PME"),
       ("nav", "nav · 173k atoms, PME")]
FONT = 'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Inter,sans-serif"'


def jsonl(pattern):
    (path,) = glob.glob(os.path.join(RESULTS, pattern))
    return [json.loads(line) for line in open(path) if line.strip()]


def fah():
    runs = defaultdict(list)
    for key, _, _ in CHIPS:
        for r in jsonl(f"results-{key}-*/fah.jsonl"):
            runs[(key, r["wu"], r["platform"], r["precision"])].append(r)
    return runs


def scaling():
    rows = defaultdict(list)
    for key, _, _ in CHIPS:
        for r in jsonl(f"scaling-{key}-*/scaling-*.jsonl"):
            rows[(key, r["platform"], r["precision"])].append(r)
    return rows


class Svg:
    def __init__(self, w, h, label):
        self.w, self.h, self.parts = w, h, []
        self.head = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="100%" '
                     f'role="img" aria-label="{label}" {FONT}>')

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, cls="lbl", anchor="start", size=12, weight=400):
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}" '
                 f'font-size="{size}" font-weight="{weight}">{s}</text>')

    def line(self, x1, y1, x2, y2, cls="grid", extra=""):
        self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" class="{cls}" {extra}/>')

    def rect(self, x, y, w, h, cls):
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 0):.1f}" height="{max(h, 0):.1f}" '
                 f'class="{cls}"/>')

    def save(self, name):
        with open(os.path.join(HERE, f"{name}.svg"), "w") as f:
            f.write(self.head + "".join(self.parts) + "</svg>\n")


def nice_ticks(hi, n=5):
    step = 10 ** math.floor(math.log10(hi / n))
    for m in (1, 2, 2.5, 5, 10):
        if hi / (step * m) <= n:
            step *= m
            break
    return [i * step for i in range(int(hi / step) + 2) if i * step <= hi * 1.001 + step]


def fmt(v):
    return f"{v:g}" if v < 1000 else f"{v / 1000:g}k"


def legend(svg, items, x, y):
    for label, cls in items:
        svg.rect(x, y - 9, 11, 11, cls)
        svg.text(x + 16, y, label, size=12)
        x += 34 + 7.2 * len(label)


def fig_fah_throughput(runs):
    """Three panels, one per work unit: ns/day by chip, one bar per configuration, ±1 sd."""
    svg = Svg(960, 330, "FAHBench throughput on three Apple chips")
    pw, top, bottom = 280, 54, 280
    legend(svg, [(c[2], c[3]) for c in CONFIGS], 60, 20)
    for p, (wu, title) in enumerate(WUS):
        x0 = 60 + p * (pw + 20)
        hi = max(st.mean(r["ns_per_day"] for r in runs[(k, wu, c[0], c[1])])
                 for k, _, _ in CHIPS for c in CONFIGS) * 1.08
        ticks = nice_ticks(hi)
        hi = ticks[-1]
        y = lambda v: bottom - v / hi * (bottom - top)
        for t in ticks:
            svg.line(x0, y(t), x0 + pw, y(t))
            svg.text(x0 - 6, y(t) + 4, fmt(t), anchor="end", size=11)
        svg.text(x0, top - 12, title, cls="ttl", size=13, weight=600)
        gw = pw / 3
        for g, (key, name, _) in enumerate(CHIPS):
            bw = (gw - 18) / 4
            for i, (plat, prec, _, cls) in enumerate(CONFIGS):
                vals = [r["ns_per_day"] for r in runs[(key, wu, plat, prec)]]
                m, sd = st.mean(vals), st.stdev(vals)
                bx = x0 + g * gw + 9 + i * bw
                svg.rect(bx + 1, y(m), bw - 2, bottom - y(m), cls)
                svg.line(bx + bw / 2, y(m + sd), bx + bw / 2, y(m - sd), "err")
            svg.text(x0 + g * gw + gw / 2, bottom + 17, name, anchor="middle", size=12)
        svg.line(x0, bottom, x0 + pw, bottom, "ax")
    svg.text(18, (top + bottom) / 2, "ns/day", anchor="middle", size=11,
             cls="lbl\" transform=\"rotate(-90 18 167)")
    svg.save("fah-throughput")


def fig_ratios(runs):
    """Two dot strips: Metal single / OpenCL single, and Metal mixed / CPU, per work unit and chip."""
    svg = Svg(960, 250, "Speed ratios: Metal against OpenCL and against CPU")
    chip_cls = {"m2": "c-m2", "m3pro": "c-pro", "m3ultra": "c-ultra"}
    mean = lambda k, wu, pl, pr: st.mean(r["ns_per_day"] for r in runs[(k, wu, pl, pr)])
    panels = [("Metal single ÷ OpenCL single", ("Metal", "single"), ("OpenCL", "single"), 0.95, 1.35,
               [1.0, 1.1, 1.2, 1.3]),
              ("Metal mixed ÷ CPU", ("Metal", "mixed"), ("CPU", "native"), 0, 12, [0, 3, 6, 9, 12])]
    for p, (title, a, b, lo, hi, ticks) in enumerate(panels):
        x0, pw = 150 + p * 420, 360
        x = lambda v: x0 + (v - lo) / (hi - lo) * pw
        svg.text(x0, 34, title, cls="ttl", size=13, weight=600)
        for t in ticks:
            svg.line(x(t), 48, x(t), 200)
            svg.text(x(t), 218, f"{t:g}×", anchor="middle", size=11)
        if lo > 0:
            svg.line(x(1), 48, x(1), 200, "ax")
        for w, (wu, _) in enumerate(WUS):
            yy = 72 + w * 52
            if p == 0:
                svg.text(x0 - 12, yy + 4, wu, anchor="end", size=12)
            svg.line(x0, yy, x0 + pw, yy, "grid")
            for key, _, _ in CHIPS:
                r = mean(key, wu, *a) / mean(key, wu, *b)
                svg.add(f'<circle cx="{x(r):.1f}" cy="{yy}" r="6.5" class="{chip_cls[key]}"/>')
    legend(svg, [("M2", "c-m2"), ("M3 Pro", "c-pro"), ("M3 Ultra", "c-ultra")], 150, 244)
    svg.save("ratios")


def log_axis(lo, hi, a, b):
    return lambda v: a + (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * (b - a)


def fig_scaling(rows):
    """Throughput (atoms x ns/day) against system size; solid single, dashed mixed, rings OpenCL."""
    svg = Svg(960, 380, "Throughput against system size")
    chip_cls = {"m2": "c-m2", "m3pro": "c-pro", "m3ultra": "c-ultra"}
    L, R, T, B = 70, 700, 30, 330
    x = log_axis(2000, 1e6, L, R)
    y = lambda v: B - v / 13 * (B - T)
    for t in range(0, 14, 2):
        svg.line(L, y(t), R, y(t))
        svg.text(L - 8, y(t) + 4, str(t), anchor="end", size=11)
    for v, s in [(3e3, "3k"), (1e4, "10k"), (3e4, "30k"), (1e5, "100k"), (3e5, "300k"), (1e6, "1M")]:
        svg.line(x(v), T, x(v), B)
        svg.text(x(v), B + 18, s, anchor="middle", size=11)
    svg.text((L + R) / 2, B + 38, "atoms (TIP3P water box, PME 0.9 nm, 2 fs)", anchor="middle", size=11)
    svg.text(20, (T + B) / 2, "M atom·ns/day", anchor="middle", size=11,
             cls=f"lbl\" transform=\"rotate(-90 20 {(T + B) / 2})")
    for key, name, cores in CHIPS:
        cls = chip_cls[key]
        for prec, dash in (("single", ""), ("mixed", 'stroke-dasharray="6 4"')):
            pts = sorted(rows[(key, "Metal", prec)], key=lambda r: r["atoms"])
            path = " ".join(f"{x(r['atoms']):.1f},{y(r['atoms'] * r['ns_per_day'] / 1e6):.1f}" for r in pts)
            svg.add(f'<polyline points="{path}" class="line {cls}" {dash}/>')
            for r in pts:
                svg.add(f'<circle cx="{x(r["atoms"]):.1f}" cy="{y(r["atoms"] * r["ns_per_day"] / 1e6):.1f}" '
                        f'r="{3.5 if prec == "single" else 2.5}" class="{cls}"/>')
        for r in rows[(key, "OpenCL", "single")]:
            svg.add(f'<circle cx="{x(r["atoms"]):.1f}" cy="{y(r["atoms"] * r["ns_per_day"] / 1e6):.1f}" '
                    f'r="7" class="ring {cls}"/>')
        peak = max(r["atoms"] * r["ns_per_day"] / 1e6 for r in rows[(key, "Metal", "single")])
        svg.text(R + 10, y(peak) + 4, f"{name}  {peak:.2f}", size=12, weight=600, cls=f"lbl t-{cls}")
    lx, ly = L + 14, T + 18
    for label, kind in [("Metal single", "solid"), ("Metal mixed", "dash"), ("OpenCL single", "ring")]:
        if kind == "ring":
            svg.add(f'<circle cx="{lx + 12}" cy="{ly - 4}" r="6" class="ring c-neutral"/>')
        else:
            dash = 'stroke-dasharray="6 4"' if kind == "dash" else ""
            svg.add(f'<line x1="{lx}" y1="{ly - 4}" x2="{lx + 24}" y2="{ly - 4}" class="line c-neutral" {dash}/>')
        svg.text(lx + 32, ly, label, size=12)
        ly += 22
    svg.save("scaling")


def fig_step_time(rows):
    """ms per step against atoms, log-log: the fixed per-step floor that small systems hit."""
    svg = Svg(620, 360, "Time per step against system size")
    chip_cls = {"m2": "c-m2", "m3pro": "c-pro", "m3ultra": "c-ultra"}
    L, R, T, B = 64, 600, 20, 300
    x = log_axis(2000, 1e6, L, R)
    y = lambda v: B - (math.log10(v) - math.log10(0.1)) / (math.log10(50) - math.log10(0.1)) * (B - T)
    for v in (0.1, 0.3, 1, 3, 10, 30):
        svg.line(L, y(v), R, y(v))
        svg.text(L - 8, y(v) + 4, f"{v:g}", anchor="end", size=11)
    for v, s in [(3e3, "3k"), (1e4, "10k"), (3e4, "30k"), (1e5, "100k"), (3e5, "300k"), (1e6, "1M")]:
        svg.line(x(v), T, x(v), B)
        svg.text(x(v), B + 18, s, anchor="middle", size=11)
    svg.text((L + R) / 2, B + 38, "atoms", anchor="middle", size=11)
    svg.text(18, (T + B) / 2, "ms / step (Metal single)", anchor="middle", size=11,
             cls=f"lbl\" transform=\"rotate(-90 18 {(T + B) / 2})")
    for key, _, _ in CHIPS:
        pts = sorted(rows[(key, "Metal", "single")], key=lambda r: r["atoms"])
        path = " ".join(f"{x(r['atoms']):.1f},{y(r['ms_per_step']):.1f}" for r in pts)
        svg.add(f'<polyline points="{path}" class="line {chip_cls[key]}"/>')
        for r in pts:
            svg.add(f'<circle cx="{x(r["atoms"]):.1f}" cy="{y(r["ms_per_step"]):.1f}" r="3.5" '
                    f'class="{chip_cls[key]}"/>')
    floor = min(r["ms_per_step"] for k, _, _ in CHIPS for r in rows[(k, "Metal", "single")])
    svg.line(L, y(floor), R, y(floor), "ax", 'stroke-dasharray="3 3"')
    svg.text(L + 8, y(floor) + 16, f"floor ≈ {floor:.2f} ms", size=11, weight=600)
    legend(svg, [("M2", "c-m2"), ("M3 Pro", "c-pro"), ("M3 Ultra", "c-ultra")], L + 8, T + 16)
    svg.save("step-time")


def fig_per_core(rows):
    """Plateau throughput per GPU core, single and mixed."""
    svg = Svg(620, 300, "Plateau throughput per GPU core")
    L, R, T, B = 64, 600, 40, 240
    hi = 0.35
    y = lambda v: B - v / hi * (B - T)
    for t in (0, 0.1, 0.2, 0.3):
        svg.line(L, y(t), R, y(t))
        svg.text(L - 8, y(t) + 4, f"{t:g}", anchor="end", size=11)
    gw = (R - L) / 3
    for g, (key, name, cores) in enumerate(CHIPS):
        for i, (prec, cls) in enumerate((("single", "c-ms"), ("mixed", "c-mm"))):
            v = max(r["atoms"] * r["ns_per_day"] / 1e6 for r in rows[(key, "Metal", prec)]) / cores
            bx = L + g * gw + 30 + i * (gw - 60) / 2
            bw = (gw - 60) / 2 - 6
            svg.rect(bx, y(v), bw, B - y(v), cls)
            svg.text(bx + bw / 2, y(v) - 6, f"{v:.3f}", anchor="middle", size=11, weight=600)
        svg.text(L + g * gw + gw / 2, B + 18, f"{name} · {cores} cores", anchor="middle", size=12)
    svg.line(L, B, R, B, "ax")
    svg.text(18, (T + B) / 2, "M atom·ns/day per core", anchor="middle", size=11,
             cls=f"lbl\" transform=\"rotate(-90 18 {(T + B) / 2})")
    legend(svg, [("Metal single", "c-ms"), ("Metal mixed", "c-mm")], L, 20)
    svg.save("per-core")


def fig_accuracy(runs):
    """Relative force error against Reference (double), every run on every chip."""
    svg = Svg(620, 300, "Force error against the Reference platform")
    L, R, T, B = 70, 600, 40, 250
    y = lambda v: B - (math.log10(v) + 7) / 3.5 * (B - T)
    for e in (1e-7, 1e-6, 1e-5):
        svg.line(L, y(e), R, y(e))
        svg.text(L - 8, y(e) + 4, f"1e{int(math.log10(e))}", anchor="end", size=11)
    gw = (R - L) / 3
    for w, (wu, _) in enumerate(WUS):
        for i, (plat, prec, _, cls) in enumerate(CONFIGS[:3]):
            cx = L + w * gw + 40 + i * (gw - 80) / 2
            for key, _, _ in CHIPS:
                for r in runs[(key, wu, plat, prec)]:
                    svg.add(f'<circle cx="{cx:.1f}" cy="{y(r["rel_force_err"]):.1f}" r="5" '
                            f'class="dot {cls}"/>')
        svg.text(L + w * gw + gw / 2, B + 18, wu, anchor="middle", size=12)
    svg.line(L, B, R, B, "ax")
    svg.text(18, (T + B) / 2, "‖F − F_ref‖ / ‖F_ref‖", anchor="middle", size=11,
             cls=f"lbl\" transform=\"rotate(-90 18 {(T + B) / 2})")
    legend(svg, [(c[2], c[3]) for c in CONFIGS[:3]], L, 20)
    svg.save("accuracy")


def fig_drift():
    """NVE drift on dhfr with a naive ±1 standard error of the slope (uncorrelated residuals)."""
    svg = Svg(620, 300, "Energy drift in constant-energy dynamics")
    L, R, T, B = 70, 600, 40, 250
    lo, hi = -220, 0
    y = lambda v: T + (v - hi) / (lo - hi) * (B - T)
    for t in range(0, -221, -50):
        svg.line(L, y(t), R, y(t))
        svg.text(L - 8, y(t) + 4, str(t), anchor="end", size=11)
    gw = (R - L) / 3
    order = [("Metal", "single", "c-ms"), ("Metal", "mixed", "c-mm"), ("CPU", "native", "c-cpu")]
    for g, (key, name, _) in enumerate(CHIPS):
        rows = {(r["platform"], r["precision"]): r for r in jsonl(f"results-{key}-*/drift.jsonl")}
        for i, (plat, prec, cls) in enumerate(order):
            r = rows[(plat, prec)]
            n = r["steps"] // 250 + 1
            se = r["rms_about_fit_kj_mol"] / (r["sim_ns"] * math.sqrt((n * n - 1) / (12 * n)))
            v = r["drift_kj_mol_per_ns"]
            bw = (gw - 40) / 3
            bx = L + g * gw + 20 + i * bw
            svg.rect(bx + 2, y(0), bw - 4, y(v) - y(0), cls)
            svg.line(bx + bw / 2, y(v - se), bx + bw / 2, y(v + se), "err")
        svg.text(L + g * gw + gw / 2, B + 18, name, anchor="middle", size=12)
    svg.line(L, y(0), R, y(0), "ax")
    svg.text(18, (T + B) / 2, "kJ/mol/ns", anchor="middle", size=11,
             cls=f"lbl\" transform=\"rotate(-90 18 {(T + B) / 2})")
    legend(svg, [("Metal single", "c-ms"), ("Metal mixed", "c-mm"), ("CPU", "c-cpu")], L, 20)
    svg.save("drift")


def fig_minimizer():
    """nav (173k atoms) energy minimization wall time, from 016 NOTES (single-block mixed path)."""
    svg = Svg(620, 170, "Energy minimization time on nav")
    L, R = 130, 560
    data = [("Metal single", 58, "c-ms"), ("Metal mixed", 264, "c-mm"), ("CPU", 300, "c-cpu")]
    x = lambda v: L + v / 320 * (R - L)
    for t in (0, 100, 200, 300):
        svg.line(x(t), 16, x(t), 130)
        svg.text(x(t), 148, f"{t} s", anchor="middle", size=11)
    for i, (label, v, cls) in enumerate(data):
        yy = 22 + i * 36
        svg.rect(L, yy, x(v) - L, 24, cls)
        svg.text(L - 10, yy + 16, label, anchor="end", size=12)
        svg.text(x(v) + 8, yy + 16, f"{v} s", size=12, weight=600)
    svg.save("minimizer")


def main():
    runs, rows = fah(), scaling()
    fig_fah_throughput(runs)
    fig_ratios(runs)
    fig_scaling(rows)
    fig_step_time(rows)
    fig_per_core(rows)
    fig_accuracy(runs)
    fig_drift()
    fig_minimizer()


if __name__ == "__main__":
    main()
