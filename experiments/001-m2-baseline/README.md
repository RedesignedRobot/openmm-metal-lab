# 001: base M2 baseline on the OpenCL and CPU platforms

## Question

How fast is OpenMM today on the smallest current Apple GPU, and how far ahead of the CPU is it? Every later Metal number gets compared against this.

## Method

- Machine: Mac mini Mac14,3, Apple M2 (4 performance and 4 efficiency cores, 10 GPU cores), 8 GB, macOS 27.0 (26A428), idle.
- OpenMM: upstream master 5a7a26861 (8.6.0.dev), Release build, AppleClang 21.
- Command: `python benchmark.py --platform <P> --test <tests> --seconds 30 --style table`, defaults otherwise (HBonds, 1.5 amu hydrogens, 4 fs, NVT). Run through `bench.sh`.
- Raw output: `results/20260921T133214Z-openmm-OpenCL.json`, `results/20260921T133518Z-openmm-CPU.json`.

## Result

| Test | OpenCL single (ns/day) | CPU mixed (ns/day) | GPU over CPU |
| --- | --- | --- | --- |
| rf | 256.4 | | |
| pme | 197.3 | | |
| apoa1rf | 59.5 | 7.89 | 7.5x |
| apoa1pme | 46.4 | 7.59 | 6.1x |
| apoa1ljpme | 34.2 | | |

## What it changes

- The GPU in the cheapest M2 runs the 92,000 atom ApoA1 system 6 to 7.5 times faster than its CPU. Folding@home folds on the CPU only on this machine, so a working GPU path is worth about that factor per Mac.
- Reference point from the upstream thread: philipturner quotes apoa1rf going from 110 to 150 ns/day with his Metal plugin. He does not name the chip in that comment (his earlier work was on M1 Max), so treat the comparison with our 59.5 as loose.
- Next: the per-kernel profile on this chip (`ENABLE_PROFILING` build), to compare with peastman's M4 Max breakdown.
