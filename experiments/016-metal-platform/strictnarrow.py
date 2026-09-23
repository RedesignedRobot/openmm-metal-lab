"""usage: strictnarrow.py <program.metal>...
Recompiles each captured program with df64's implicit narrowing to float made explicit, so every
place a df64 value silently becomes a float is a compile error. Prints each error with its source line."""
import re, subprocess, sys, os
# The compiler: swiftc -O mslc.swift -o <path>, then set MSLC=<path>. It uses the same options as
# MetalContext::createLibrary.
MSLC = os.environ['MSLC']
PAT = re.compile(r'template <typename T, typename = enable_if_t<is_same<T, float>::value>> operator T\(\) const (\w+)')
for path in sys.argv[1:]:
    src = open(path).read()
    strict, n = PAT.subn(r'explicit operator float() const \1', src)
    assert n == 4, (path, n)
    tmp = path + '.strict'
    open(tmp, 'w').write(strict)
    out = subprocess.run([MSLC, tmp, 'safe'], capture_output=True, text=True).stdout
    lines = strict.split('\n')
    seen = set()
    errs = []
    for m in re.finditer(r'program_source:(\d+):(\d+): error: ([^\n\\]*)', out):
        ln = int(m.group(1))
        if (ln, m.group(3)) in seen: continue
        seen.add((ln, m.group(3)))
        errs.append((ln, m.group(3), lines[ln-1].strip()))
    status = 'OK' if out.startswith('OK') else 'FAIL'
    print('=== %s %s  %d errors' % (status, os.path.basename(path), len(errs)))
    for ln, msg, text in errs:
        print('  %d: %s\n      | %s' % (ln, msg[:160], text[:200]))
    os.remove(tmp)
