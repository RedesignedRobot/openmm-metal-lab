"""Run one minimization of a work unit with the temporary MINIMIZE_PROFILE instrumentation.

usage: MINIMIZE_PROFILE=1 python minprof.py <wu-dir> <precision> [tolerance]
The instrumented build prints a PROFILE line to stderr per minimize() call: host wall of the call,
total time of single-block launches (each between device syncs), the cost of one empty sync per
launch, and the total time of GPU force evaluations.  The first call is the one-iteration warm-up.
"""
import sys

import openmm as mm

from minwu import load

wu, precision = sys.argv[1:3]
tolerance = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
system, integrator, state = load(wu)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
context.setState(state)
mm.LocalEnergyMinimizer.minimize(context, tolerance, 1)
context.setState(state)
mm.LocalEnergyMinimizer.minimize(context, tolerance)
