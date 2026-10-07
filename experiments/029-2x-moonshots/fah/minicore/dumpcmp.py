#!/usr/bin/env python3
"""dumpcmp.py <reference out dir> <other out dir> <step> [<step> ...]

Compares the dump-<step>.bin files minicore --dump-steps writes (positions, velocities and forces as
raw doubles) and prints the largest per-atom difference in each at every step, with the reference
run's RMS force for scale. Bitwise equal dumps print "identical".
"""
import math
import sys
from array import array


def read_dump(path):
    data = array("d")
    with open(path, "rb") as f:
        data.frombytes(f.read())
    n = len(data) // 9
    return data[:3 * n], data[3 * n:6 * n], data[6 * n:]


def max_diff(a, b):
    return max(math.sqrt(sum((a[i + k] - b[i + k]) ** 2 for k in range(3))) for i in range(0, len(a), 3))


def main():
    ref_dir, other_dir = sys.argv[1], sys.argv[2]
    for step in sys.argv[3:]:
        ref = read_dump("%s/dump-%s.bin" % (ref_dir, step))
        other = read_dump("%s/dump-%s.bin" % (other_dir, step))
        if ref == other:
            print("step %s: identical" % step)
            continue
        forces = ref[2]
        rms = math.sqrt(sum(f * f for f in forces) / (len(forces) // 3))
        print("step %s: max|dx| %.3g nm, max|dv| %.3g nm/ps, max|dF| %.3g kJ/mol/nm (RMS force %.4g)" % (
            step, max_diff(ref[0], other[0]), max_diff(ref[1], other[1]), max_diff(ref[2], other[2]), rms))


if __name__ == "__main__":
    main()
