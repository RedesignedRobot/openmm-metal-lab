# Classifies every conversion in the conversion-probe outputs: does it equal the exact truncated
# value modulo 2^64 (wrapping), or the value saturated to [INT64_MIN, INT64_MAX]? inf and NaN count
# as 0 for wrapping; NaN counts as 0 for saturating (what the M2 returns).
import math
import struct
import sys

for fn in sys.argv[1:]:
    rows = [line.split() for line in open(fn) if line.startswith("0x")]
    total = wraps = saturates = 0
    for row in rows:
        x = struct.unpack(">f", bytes.fromhex(row[0][2:]))[0]
        for col, mult in ((2, 2**32), (3, 1)):
            got = int(row[col], 16)
            v = x * mult   # exact: a power-of-two scale
            wrap = 0 if math.isnan(v) or math.isinf(v) else math.trunc(v) % 2**64
            if math.isnan(v):
                sat = 0
            elif v >= 2**63:
                sat = 2**63 - 1
            elif v <= -2**63:
                sat = 2**63
            else:
                sat = math.trunc(v) % 2**64
            total += 1
            wraps += got == wrap
            saturates += got == sat
    print(f"{fn}: {total} conversions ((long)(x*2^32) and (long)x); wrapping {wraps}/{total}, saturating {saturates}/{total}")
