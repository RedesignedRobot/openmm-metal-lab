#!/usr/bin/env python3
"""Sum OpenMM ENABLE_PROFILING trace events per kernel.

usage: profile-kernels.py <benchmark stdout file>
Prints a markdown table of kernel, launches, total GPU milliseconds and fraction.
"""
import collections
import re
import sys

EVENT = re.compile(r'"dur":([0-9.eE+-]+), "ph":"X", "name":"([^"]+)"')

durations = collections.Counter()
launches = collections.Counter()
for match in EVENT.finditer(open(sys.argv[1]).read()):
    durations[match.group(2)] += float(match.group(1))
    launches[match.group(2)] += 1

total = sum(durations.values())
print("| Kernel | Launches | GPU ms | Fraction |")
print("| --- | --- | --- | --- |")
for name, microseconds in durations.most_common(15):
    print(f"| {name} | {launches[name]} | {microseconds / 1000:.1f} | {microseconds / total:.3f} |")
