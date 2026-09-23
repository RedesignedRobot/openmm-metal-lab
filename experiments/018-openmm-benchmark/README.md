# 018: OpenMM's benchmark.py on M2, M3 Pro and M3 Ultra

OpenMM's `examples/benchmarks/benchmark.py` at f9347f6c5, unmodified, run through `run.py` on
each chip: nine non-AMOEBA tests x {Metal single, Metal mixed, OpenCL single, CPU}. Clock:
benchmark.py's host wall clock (`datetime.now`), one run of about 60 s per configuration (it
stops once a run passes half of `--seconds`; recorded runs took 54.5 to 68.8 s). Tables: `results.md`,
made by `summarize.py`.

## Findings

- Metal single / OpenCL single: 0.99 to 1.07 on every test and chip. On this suite the
  platform ties OpenCL.
- Metal mixed / OpenCL single: 0.58 to 0.89. Mixed costs 15 to 42% against Metal single: 28 to
  42% on the three 23,558-atom dhfr systems, 15 to 23% on cellulose and stmv. Where it goes is
  experiment 022.
- The FAHBench dhfr lead over OpenCL (1.20 to 1.28, experiment 017) doesn't appear here. That
  work unit constrains every bond and H-X-H angle, so all 3,072 non-water constraints go to CCMA.
  Every benchmark.py system constrains only bonds to hydrogen and sends nothing to CCMA
  (`constraints.py`). A correlation only; 022 tests whether CCMA is the cause.

## Learnings

- `benchmark.py` has no `__main__` guard: importing it parses argv and runs the whole suite.
  Rebuild a test system from its `retrieveTestSystem` code instead of importing it.
- `amber20-dhfr` reads a NetCDF restart and needs scipy in the interpreter; without it the run
  writes an empty benchmark list.
- The CPU platform reports its precision as mixed whatever you ask for.
- A first constraint classifier counted 2,135 CCMA constraints on FAHBench dhfr because it
  accepted a SETTLE triangle after checking two of its three atoms; CH2 and NH2 groups with
  H-H angle constraints slipped through. `constraints.py` ports IntegrationUtilities.cpp
  faithfully (all three atoms need exactly two constraints). Port the source, don't paraphrase it.
- benchmark.py labels the amber20 tests "hydrogen_mass 1.5" but never repartitions the prmtop
  systems.
