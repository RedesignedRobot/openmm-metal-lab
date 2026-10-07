# Offline syntax check of the findInteractingBlocks module: assembles the source the way
# MetalContext::createModule does (single precision, rectangular box) and compiles it with xcrun metal.
# No GPU work. usage: mslcheck.py <src tree> <out dir> [NAME=value ...]; MODULE=sort checks the block sort instead.
import os, re, subprocess, sys

tree, out = sys.argv[1], sys.argv[2]
extra = dict(a.split('=', 1) for a in sys.argv[3:])
kdir = os.path.join(tree, 'platforms/metal/src/kernels')
read = lambda name: open(os.path.join(kdir, name)).read()

compilation = {
    'USE_METAL': '1', 'AMD_RDNA': '1',
    'make_real2': 'make_float2', 'make_real3': 'make_float3', 'make_real4': 'make_float4',
    'make_mixed2': 'make_float2', 'make_mixed3': 'make_float3', 'make_mixed4': 'make_float4',
    'SQRT': '__fsqrt_rn', 'RSQRT': '__frsqrt_rn', 'RECIP(x)': 'fast::divide(1.0f, (x))', 'EXP': '__expf',
    'LOG': '__logf', 'POW': 'powf', 'COS': 'cosf', 'SIN': 'sinf', 'TAN': 'tanf', 'ACOS': 'acosf',
    'ASIN': 'asinf', 'ATAN': 'atanf', 'ERF': 'erff', 'ERFC': 'erfcf', 'FMA': 'fmaf', 'FABS': 'fabsf',
    'APPLY_PERIODIC_TO_DELTA(delta)': '{delta.x -= floor(delta.x*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x; \\\n'
        'delta.y -= floor(delta.y*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y; \\\n'
        'delta.z -= floor(delta.z*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;}',
    'APPLY_PERIODIC_TO_POS(pos)': '{pos.x -= floor(pos.x*invPeriodicBoxSize.x)*periodicBoxSize.x; \\\n'
        'pos.y -= floor(pos.y*invPeriodicBoxSize.y)*periodicBoxSize.y; \\\n'
        'pos.z -= floor(pos.z*invPeriodicBoxSize.z)*periodicBoxSize.z;}',
    'APPLY_PERIODIC_TO_POS_WITH_CENTER(pos, center)': '{pos.x -= floor((pos.x-center.x)*invPeriodicBoxSize.x+0.5f)*periodicBoxSize.x; \\\n'
        'pos.y -= floor((pos.y-center.y)*invPeriodicBoxSize.y+0.5f)*periodicBoxSize.y; \\\n'
        'pos.z -= floor((pos.z-center.z)*invPeriodicBoxSize.z+0.5f)*periodicBoxSize.z;}',
}
# apoa1-like nblist defines.
defines = {
    'TILE_SIZE': '32', 'NUM_BLOCKS': '2882', 'NUM_ATOMS': '92224', 'PADDED_NUM_ATOMS': '92224',
    'PADDING': '0.072', 'PADDED_CUTOFF': '0.972', 'PADDED_CUTOFF_SQUARED': '0.944784',
    'NUM_TILES_WITH_EXCLUSIONS': '10000', 'USE_PERIODIC': '1', 'USE_LARGE_BLOCKS': '1', 'MAX_EXCLUSIONS': '96',
    'MAX_BITS_FOR_PAIRS': '4', 'FIND_UNROLL_MIN': '33', 'STAGE_BOX_DATA': '0', 'NUM_TILES_IN_BATCH': '1',
    'GROUP_SIZE': '32', 'BIN_SHIFT': '12', 'BLOCK_INDEX_MASK': '4095',
}
module = extra.pop('MODULE', 'fib')
if module == 'sort':
    defines = {}
defines.update(extra)
defines = {k: v for k, v in defines.items() if v != 'UNDEF'}

def rewrite_parameter(param, prologue):
    if re.search(r'\b(GLOBAL|LOCAL|LOCAL_ARG|device|threadgroup|constant)\b|[&\[]', param):
        return param, prologue
    if '*' in param:
        return 'device ' + param, prologue
    m = re.fullmatch(r'\s*(const\s+)?(\S.*?)\s+(\w+)((\s+[A-Z_]+)*)\s*', param, re.S)
    if not m:
        return param, prologue
    prologue += f'{m[2]} {m[3]} = _in_{m[3]};\n'
    return f'constant {m[2]}& _in_{m[3]}{m[4]}', prologue

def rewrite_signatures(source):
    result, pos = '', 0
    pattern = re.compile(r'\b(KERNEL|__global__)\b.*?\bvoid\s+\w+\s*\(')
    while True:
        m = pattern.search(source, pos)
        if not m:
            break
        i = m.end()
        result += source[pos:i]
        prologue, param, depth = '', '', 0
        while depth >= 0:
            c = source[i]
            if c == '#':
                end = source.find('\n', i) + 1
                p, prologue = rewrite_parameter(param, prologue)
                result += p + '\n' + source[i:end]
                prologue += source[i:end]
                param = ''
                i = end
                continue
            depth += (c == '(') - (c == ')')
            if depth < 0 or (c == ',' and depth == 0):
                p, prologue = rewrite_parameter(param, prologue)
                result += p + c
                param = ''
            else:
                param += c
            i += 1
        pos = source.find('{', i) + 1
        result += source[i:pos] + '\n' + prologue
    return result + source[pos:]

src = ''.join(f'#define {k} {v}\n' for k, v in sorted(compilation.items()) if k not in defines) + '\n'
src += '#include <metal_stdlib>\nusing namespace metal;\n'
src += 'typedef float real;\ntypedef float2 real2;\ntypedef float3 real3;\ntypedef float4 real4;\n'
src += 'typedef float mixed;\ntypedef float2 mixed2;\ntypedef float3 mixed3;\ntypedef float4 mixed4;\n'
src += 'typedef unsigned int tileflags;\n' + read('common.metal') + '\n'
thread_word = re.compile(r'\bthread\b')
src += ''.join('#define %s %s\n' % (k, thread_word.sub('_mmThread', v)) for k, v in sorted(defines.items())) + '\n'
src += read('intrinsics.metal') + '\n'
if module == 'sort':
    body = read('sort.metal')
    for k, v in {'DATA_TYPE': 'unsigned int', 'KEY_TYPE': 'unsigned int', 'SORT_KEY': 'value', 'MIN_KEY': '0',
                 'MAX_KEY': '0xFFFFFFFFu', 'MAX_VALUE': '0xFFFFFFFFu', 'UNIFORM': '0'}.items():
        body = re.sub(r'\b%s\b' % k, v, body)
else:
    body = read('vectorOps.metal') + read('findInteractingBlocks.metal')
body = re.sub(r'\blong long\b', 'long', thread_word.sub('_mmThread', body))
src += rewrite_signatures(body) + '\n'
os.makedirs(out, exist_ok=True)
path = os.path.join(out, module + '.metal')
open(path, 'w').write(src)
r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-std=metal3.2', '-c', path, '-o', os.path.join(out, module + '.air')],
                   capture_output=True, text=True)
print(r.stderr.strip() or 'compiled', '\n', ' '.join(sys.argv[3:]))
sys.exit(r.returncode)
