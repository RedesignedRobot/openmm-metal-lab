# Assemble findInteractingBlocks.metal the way MetalContext::createLibrary does, for a compile check.
import re, sys
root = sys.argv[1]; variant = sys.argv[2]
src = open(f"{root}/platforms/metal/src/kernels/findInteractingBlocks.metal").read()
common = open(f"{root}/platforms/metal/src/kernels/common.metal").read()

def rewrite_param(p, prologue):
    d = p.strip()
    if not d or any(c in d for c in "*&[") or len([t for t in d.split() if t != "const"]) < 2:
        return p
    toks = [t for t in d.split() if t != "const"]
    prologue.append(f"    {' '.join(toks[:-1])} {toks[-1]} = _in_{toks[-1]};")
    lead = p[:len(p) - len(p.lstrip())]; trail = p[len(p.rstrip()):]
    return f"{lead}constant {' '.join(toks[:-1])}& _in_{toks[-1]}{trail}"

def rewrite(s):
    out = []; pos = 0
    for m in re.finditer(r"\bKERNEL\b", s):
        if m.start() < pos: continue
        o = s.index("(", m.start()); out.append(s[pos:o+1])
        pro = []; param = ""; depth = 0; i = o+1
        while True:
            c = s[i]
            if c == "#":
                e = s.index("\n", i); out.append(rewrite_param(param, pro) + s[i:e]); pro.append(s[i:e]); param = ""; i = e - 1
            elif c == "(": depth += 1; param += c
            elif c == ")" and depth > 0: depth -= 1; param += c
            elif c == ")" or (c == "," and depth == 0):
                out.append(rewrite_param(param, pro) + c); param = ""
                if c == ")": break
            else: param += c
            i += 1
        b = s.index("{", i); out.append(s[i+1:b+1] + "\n" + "\n".join(pro) + "\n"); pos = b+1
    out.append(s[pos:]); return "".join(out)

defs = {"TILE_SIZE": "32", "NUM_ATOMS": "92224", "PADDING": "0.1", "PADDED_CUTOFF": "1.1", "PADDED_CUTOFF_SQUARED": "1.21",
        "NUM_TILES_WITH_EXCLUSIONS": "3000", "NUM_BLOCKS": "2882", "SIMD_WIDTH": "32", "MAX_EXCLUSIONS": "20",
        "BIN_SHIFT": "13", "BLOCK_INDEX_MASK": "8191", "GROUP_SIZE": "256"}
if variant.endswith(".defines"):
    defs = {}
    for line in open(variant):
        parts = line.rstrip("\n").split("\t")
        if parts[0] == "program" and parts[1] not in ("BUFFER_GROUPS",):
            defs[parts[1]] = parts[2]
if "periodic" in variant: defs["USE_PERIODIC"] = "1"
if "large" in variant: defs["USE_LARGE_BLOCKS"] = "1"
if "triclinic" in variant: defs["TRICLINIC"] = "1"
pre = ["#define LOG log", "#define SQRT sqrt", "#define RSQRT rsqrt", "#define RECIP(x) (1.0f/(x))", "#define EXP exp",
       "#define APPLY_PERIODIC_TO_DELTA(delta) {delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x; delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y; delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;}",
       "#define APPLY_PERIODIC_TO_POS(pos) {pos.x -= floor(pos.x*invPeriodicBoxSize.x)*periodicBoxSize.x; pos.y -= floor(pos.y*invPeriodicBoxSize.y)*periodicBoxSize.y; pos.z -= floor(pos.z*invPeriodicBoxSize.z)*periodicBoxSize.z;}",
       "#define APPLY_PERIODIC_TO_POS_WITH_CENTER(pos, center) {pos.x -= floor((pos.x-center.x)*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x; pos.y -= floor((pos.y-center.y)*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y; pos.z -= floor((pos.z-center.z)*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;}",
       "#include <metal_stdlib>", "using namespace metal;",
       "typedef float real; typedef float2 real2; typedef float3 real3; typedef float4 real4;",
       "#define make_real2 make_float2", "#define make_real3 make_float3", "#define make_real4 make_float4",
       "typedef unsigned int tileflags;", common]
pre += [f"#define {k} {v}" for k, v in defs.items()]
print("\n".join(pre) + "\n" + rewrite(src))
