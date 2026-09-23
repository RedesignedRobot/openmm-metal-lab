"""usage: literals.py <program.metal>...
Lists floating-point literals without an f/h suffix whose value a float cannot hold exactly. MSL
has no double, so such a literal is rounded to float; CUDA and OpenCL keep it as a double."""
import re, sys, os
import struct
LIT = re.compile(r'(?<![\w.])((?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)([fFhH]?)(?![\w.])')
seen = {}
for path in sys.argv[1:]:
    for n, line in enumerate(open(path), 1):
        code = line.split('//')[0]
        for m in LIT.finditer(code):
            if m.group(2):
                continue
            v = float(m.group(1))
            if struct.unpack("f", struct.pack("f", v))[0] == v:
                continue
            key = (line.strip(), m.group(1))
            seen.setdefault(key, []).append('%s:%d' % (os.path.basename(path)[:8], n))
for (text, lit), where in sorted(seen.items(), key=lambda kv: kv[1][0]):
    print('%-24s %s\n    | %s' % (lit, ' '.join(sorted(set(where)))[:120], text[:220]))
