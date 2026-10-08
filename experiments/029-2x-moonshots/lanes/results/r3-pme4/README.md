# Order and grid accuracy screen

This is analysis code, not a Metal implementation. `reference_bridge.cpp`
calls the unmodified `OpenMM::ReferencePME` in the existing r2/pmefft library.
It changes the constructor's interpolation-order argument without patching
OpenMM or replacing its force calculation with an approximation.

`analyze.py` loads each native `benchmark.py` topology at the default 0.9 nm
cutoff and 5e-4 Ewald tolerance. The default Metal grids are 56 cubed for
pme and amber20-dhfr, 98 cubed for both apoa1 cases, 231 by 112 by 110 for
cellulose, and 198 by 200 by 200 for STMV. The dispersion grid is 49 cubed.
DHFR uses r2/pmefft's 56 cubed grid, which is stricter than upstream's
55 cubed grid. Alpha is unchanged at sqrt(-log(0.001))/0.9.

Each input contains the benchmark coordinates and CPU LangevinMiddle
configurations after 100 and 200 steps at 2 fs, 300 K, friction 1/ps,
constraint tolerance 1e-8, four CPU threads, and seed 20260927. These are
short local configuration samples, not an equilibrium ensemble. No GPU
is used. `*-input.npz` preserves the exact coordinates used in the sweep.

The reference is order 8 at twice the default mesh density. Order 7 at
the same fine mesh checks reference convergence. A separate 32-particle
neutral system compares orders 4, 5, and 8 with an independent direct
reciprocal Ewald sum over integer vectors from -14 to 14. Finite differences
check that the force is the derivative of the computed energy. The result
is `validation.json`.

Metrics in `*-sweep.jsonl`:

- `rms_relative`: norm(F-Fref)/norm(Fref).
- `max_relative`: max_i norm(dF_i)/max_i norm(Fref_i).
- `max_atom_relative`: max_i norm(dF_i)/norm(Fref_i). The denominator floor
  is 1e-30, so nearly zero reference forces are not hidden.
- `rms_absolute`: sqrt(mean_i norm(dF_i)^2), in kJ/mol/nm.
- `max_absolute`: max_i norm(dF_i), in kJ/mol/nm.
- `energy_error`: E-Eref, in kJ/mol. This is the reciprocal mesh term.
  Direct space, exclusions, and self terms cancel between the compared
  methods. Dispersion is evaluated separately with exec_dpme and
  c6_i = 2 sqrt(epsilon_i) sigma_i^3.

The conservative screen requires both relative definitions of maximum
error, plus relative RMS, to be no worse than order 5 in every configuration.
For LJPME the acceptance metric is the combined Coulomb plus dispersion
force. Separate component sweeps diagnose the source of the error; they
do not impose independent budgets that the task did not request.
The report also gives the weaker RMS/global-maximum-only result to show
how this choice affects the conclusion. Energy error is measured, not
used to silently change the force-based acceptance rule.

`--dense LOW HIGH` evaluates every distinct mesh produced by uniform
rescaling and rounding up to dimensions factorizable by 2, 3, 5, 7, 11,
and 13 in that interval. This is an exhaustive search along that path,
not an exhaustive search of independent anisotropic dimensions or all
possible configurations. Existing rows and reference arrays are reused.

`lj_optimize.py` searches all legal cubic Coulomb dimensions from 52 to
176 and dispersion dimensions from 26 to 91, with orders 4 and 5. It
checks candidates in descending predicted savings and stops at the first
passing common-order policy and first passing independent-order policy.
It uses the three MD configurations plus nine rigidly translated mesh
alignments (phase seed 290927). `lj-phases.json` records the phase screen
that rejected the initially selected 96 cubed Coulomb grid.
`validate_lj.py` confirms that the bridge's combined baseline forces
exactly match a full OpenMM Reference Context. Self and neutralizing
background constants explain the energy offset, and cancel from all
candidate-versus-reference energy errors reported here.

`cost.py` uses the census and the consult's post-spread cost assumptions.
Its estimates are not new GPU timings. It also reports sensitivity to
the larger pre-spread costs. Every assumption is in its module docstring
and the experiment report. The lower-order stencil saving is an optimistic
ceiling: grid volume also changes atom sharing and spread fallback rate.

Reproduction uses the existing r2/pmefft venv, headers and dylib. Compile
the bridge with Xcode-beta clang++, C++17, -O2, -dynamiclib, the tree's
prefix/include and prefix/lib, -lOpenMM, and an rpath to prefix/lib.
Set PME_BRIDGE to that output file. Run only during 07:00-24:00 UTC:

```sh
python analyze.py validate
python analyze.py prepare
python analyze.py sweep --dense 1.25 1.85
python cost.py
python lj_optimize.py
```

The actual preparation and sweep logs are archived alongside the result
tables. Failed setup attempts stopped before any numerical result and
are recorded in the report. No full test suite or benchmark timing runs
are part of this analysis.

The raw .npz inputs and references (31 files, about 270 MB) live at /tmp/openmm-metal-bench/archive/r3-pme4-npz on the Studio, not in git.
