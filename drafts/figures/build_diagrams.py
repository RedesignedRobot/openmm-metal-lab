"""Build the explanatory diagrams for the technical report: architecture, command buffers, df64.

usage: python3 build_diagrams.py
Same conventions as build_figures.py: class names only, the page sets the palette.
"""
from build_figures import Svg


def box(svg, x, y, w, h, label, sub="", hi=False):
    svg.rect(x, y, w, h, "box-hi" if hi else "box")
    cls = "t-hi" if hi else "ttl"
    if sub:
        svg.text(x + w / 2, y + h / 2 - 3, label, cls, "middle", 13, 600)
        svg.text(x + w / 2, y + h / 2 + 14, sub, "lbl", "middle", 11)
    else:
        svg.text(x + w / 2, y + h / 2 + 4.5, label, cls, "middle", 13, 600)


def fig_architecture():
    """OpenMM's layers, with the Metal column added beside CUDA, HIP and OpenCL."""
    svg = Svg(960, 400, "OpenMM platform architecture with the Metal platform")
    L, W, G = 40, 880, 12
    col = (W - 5 * G) / 6
    xs = [L + i * (col + G) for i in range(6)]
    box(svg, L, 20, W, 44, "Applications", "Folding@home cores · OpenMM Python API · FAHBench")
    box(svg, L, 80, W, 44, "OpenMM API", "System · Context · Integrator · Force")
    names = [("Reference", "double, CPU"), ("CPU", "SIMD, threads"), ("CUDA", "NVIDIA"),
             ("HIP", "AMD"), ("OpenCL", "any GPU"), ("Metal", "this work")]
    for x, (n, s) in zip(xs, names):
        box(svg, x, 140, col, 50, n, s, hi=n == "Metal")
    cc = xs[2]
    svg.rect(cc, 206, xs[5] + col - cc, 58, "box")
    svg.text(cc + (xs[5] + col - cc) / 2, 230, "Common Compute", "ttl", "middle", 13, 600)
    svg.text(cc + (xs[5] + col - cc) / 2, 248, "one set of GPU kernels, compiled unchanged for each platform",
             "lbl", "middle", 11)
    backs = [("CUDA driver", False), ("HIP runtime", False), ("OpenCL ICD", False), ("metal-cpp", True)]
    for x, (n, hi) in zip(xs[2:], backs):
        box(svg, x, 280, col, 40, n, hi=hi)
    hw = [("NVIDIA GPUs", False), ("AMD GPUs", False), ("GPUs, CPUs", False), ("Apple GPUs", True)]
    for x, (n, hi) in zip(xs[2:], hw):
        box(svg, x, 336, col, 40, n, hi=hi)
    for x in xs[:2]:
        svg.rect(x, 206, col, 170, "box-faint")
        svg.text(x + col / 2, 296, "C++ host code", "lbl", "middle", 11)
    svg.save("architecture")


def fig_command_buffers():
    """Per-kernel command buffers against one open command buffer, on a shared time axis."""
    svg = Svg(960, 300, "Command buffer strategies compared on a time axis")
    L, R = 90, 920
    unit = (R - L) / 100

    def lane(y, title, sub, kernels, gap, tail):
        svg.text(L, y - 14, title, "ttl", "start", 13, 600)
        svg.text(L + 7.4 * len(title) + 14, y - 14, sub, "lbl", "start", 12)
        svg.text(L - 12, y + 13, "CPU", "lbl", "end", 11)
        svg.text(L - 12, y + 45, "GPU", "lbl", "end", 11)
        t = 0
        for i in range(kernels):
            if gap:
                svg.rect(L + t * unit, y + 2, 2.2 * unit, 14, "c-neutral")
                t += 2.2
                svg.rect(L + (t + gap) * unit, y + 34, 5 * unit, 14, "c-ultra")
                t += gap + 5
            else:
                svg.rect(L + t * unit, y + 2, 0.8 * unit, 14, "c-neutral")
                t += 0.8
        if not gap:
            svg.rect(L + t * unit, y + 2, 2.2 * unit, 14, "c-pro")
            start = t + 2.2 + tail
            for i in range(kernels):
                svg.rect(L + (start + i * 5.2) * unit, y + 34, 5 * unit, 14, "c-ultra")
        return t

    lane(40, "One buffer per kernel", "15 to 24 µs of host cost per dispatch", 6, 9, 0)
    lane(146, "One open buffer, this platform", "0.11 to 0.12 µs per dispatch, one commit", 6, 0, 2)
    y = 236
    svg.line(L, y, R, y, "ax")
    svg.text(R, y + 18, "time", "lbl", "end", 11)
    legend = [("encode", "c-neutral"), ("commit", "c-pro"), ("kernel on GPU", "c-ultra")]
    x = L
    for label, cls in legend:
        svg.rect(x, y + 34, 11, 11, cls)
        svg.text(x + 17, y + 44, label, "lbl", "start", 12)
        x += 40 + 7.2 * len(label)
    svg.save("command-buffers")


def fig_df64():
    """How a mixed-precision value travels: IEEE double in memory, a float pair in registers."""
    svg = Svg(960, 330, "Double-float representation and its precision")
    steps = [("Device memory", "IEEE double, 64 bits"), ("Load", "split into hi + lo"),
             ("Registers", "float hi, float lo"), ("Arithmetic", "error-free sums, fma"),
             ("Store", "hi + lo to double")]
    w, g, L = 160, 20, 40
    for i, (a, b) in enumerate(steps):
        x = L + i * (w + g)
        box(svg, x, 24, w, 52, a, b, hi=i in (2, 3))
        if i:
            svg.line(x - g + 3, 50, x - 3, 50, "ax")
    svg.text(40, 128, "Significand bits and unit roundoff", "ttl", "start", 13, 600)
    bars = [("double", 53, "53 bits · 1.1e-16", "c-neutral"),
            ("double-float", 48, "about 48 bits · 3.6e-15", "c-ultra"), ("float", 24, "24 bits · 6.0e-8", "c-cpu")]
    BL, scale = 170, 12
    for i, (n, bits, label, cls) in enumerate(bars):
        y = 150 + i * 44
        svg.text(BL - 12, y + 19, n, "lbl", "end", 13)
        svg.rect(BL, y + 4, bits * scale, 22, cls)
        svg.text(BL + bits * scale + 10, y + 20, label, "ttl", "start", 12, 600)
    svg.text(40, 310, "Measured over one step against a double closed form: 6.7e-15 in position, "
             "4.5e-15 in velocity.", "lbl", "start", 12)
    svg.save("df64")


def fig_code_size():
    """Lines in platforms/<name>/src and include at f9347f6c5, without OpenCL's vendored opencl.hpp.

    Counted with git show | wc -l over git ls-tree of each directory.
    """
    svg = Svg(960, 210, "Platform source size in lines")
    rows = [("OpenCL", 8779, "c-neutral"), ("CUDA", 7828, "c-neutral"), ("HIP", 7604, "c-neutral"),
            ("Metal", 6507, "c-ultra")]
    L, scale = 110, 700 / 10000
    for v in (0, 2500, 5000, 7500, 10000):
        x = L + v * scale
        svg.line(x, 16, x, 180, "grid")
        svg.text(x, 198, f"{v:,}", "lbl", "middle", 11)
    for i, (n, v, cls) in enumerate(rows):
        y = 20 + i * 40
        svg.text(L - 12, y + 17, n, "t-hi" if n == "Metal" else "lbl", "end", 13, 600 if n == "Metal" else 400)
        svg.rect(L, y + 2, v * scale, 22, cls)
        svg.text(L + v * scale + 10, y + 18, f"{v:,}", "ttl", "start", 12, 600)
    svg.save("code-size")


def fig_native_kernels():
    """Standalone Metal-native kernels against OpenCL, GPU timestamps (experiments 009, 010b, 010c).

    findBlocksWithInteractions: 009-neighbour-list/results.md (OpenCL / native ms).
    computeNonbonded, forces only: 010b (M2) and 010c (M3 Ultra).
    """
    svg = Svg(960, 330, "Speed of Metal-native kernels relative to OpenCL")
    rows = [("findBlocks · apoa1 RF", 4.637 / 1.990, 1.684 / 0.589),
            ("findBlocks · apoa1 PME", 4.181 / 1.772, 1.582 / 0.509),
            ("computeNonbonded · apoa1 RF", 2.663 / 2.886, 1.046 / 0.621)]
    L, R, T = 230, 900, 30
    scale = (R - L) / 3.5
    for v in (0, 1, 2, 3):
        x = L + v * scale
        svg.line(x, T - 6, x, 262, "ax" if v == 1 else "grid")
        svg.text(x, 282, f"{v}×", "lbl", "middle", 11)
    for i, (name, m2, ultra) in enumerate(rows):
        y = T + i * 78
        svg.text(L - 14, y + 30, name, "ttl", "end", 13, 600)
        for j, (v, cls) in enumerate(((m2, "c-m2"), (ultra, "c-ultra"))):
            yy = y + j * 26
            svg.rect(L, yy + 6, v * scale, 20, cls)
            svg.text(L + v * scale + 8, yy + 21, f"{v:.2f}×", "ttl", "start", 12, 600)
    x = L
    for label, cls in (("M2", "c-m2"), ("M3 Ultra", "c-ultra")):
        svg.rect(x, 306, 11, 11, cls)
        svg.text(x + 17, 316, label, "lbl", "start", 12)
        x += 34 + 7.2 * len(label)
    svg.save("native-kernels")


def main():
    fig_architecture()
    fig_command_buffers()
    fig_df64()
    fig_code_size()
    fig_native_kernels()


if __name__ == "__main__":
    main()
