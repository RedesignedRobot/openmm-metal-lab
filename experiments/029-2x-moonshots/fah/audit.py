"""Audit CustomIntegrator expressions against Metal mixed precision.

In mixed precision the Metal platform evaluates CustomIntegrator per-DOF and sum expressions in df64 (paired
floats).  Eleven functions have no df64 version and fail at kernel compile time: tan, asin, acos, atan, atan2,
sinh, cosh, tanh, erf, erfc, and pow with a non-integer exponent (x^y).  Global expressions run on the host in
double and force expressions run in float, so neither is affected.

    python audit.py xml <integrator.xml[.bz2] or WU dir> ...      static check of serialized integrators
    python audit.py openmmtools <openmmtools package dir>        build every openmmtools CustomIntegrator, check it
    python audit.py compile <WU dir> <openmmtools package dir>   (GPU) also step each one on Metal mixed

The package dir is any directory holding an importable `openmmtools/`.  A site-packages works.  So does a
folder with openmmtools main's integrators.py, respa.py, constants.py and utils/utils.py (saved as utils.py) plus an
empty __init__.py, which is how the 2026-09-27 audit ran.
"""
import bz2
import inspect
import os
import re
import sys

import openmm as mm
import openmm.unit as u

UNSUPPORTED = ('tan', 'asin', 'acos', 'atan', 'atan2', 'sinh', 'cosh', 'tanh', 'erf', 'erfc')
FUNCTION = re.compile(r'\b(%s)\s*\(' % '|'.join(UNSUPPORTED))
# Integer powers become multiplies (ExpressionUtilities, POWER_CONSTANT); any other exponent is a general pow.
POWER = re.compile(r'\^\s*\(?\s*(-?[0-9.eE+-]+|[A-Za-z_][A-Za-z0-9_]*)')


def load(path):
    if os.path.isdir(path):
        for name in ('integrator.xml.bz2', 'integrator.xml'):
            if os.path.exists(os.path.join(path, name)):
                path = os.path.join(path, name)
                break
    opener = bz2.open if path.endswith('.bz2') else open
    with opener(path, 'rt') as f:
        return mm.XmlSerializer.deserialize(f.read())


def unsupported(expression):
    found = set(FUNCTION.findall(expression))
    for exponent in POWER.findall(expression):
        try:
            if not float(exponent).is_integer():
                found.add('pow')
        except ValueError:
            found.add('pow')  # a variable exponent
    return sorted(found)


def gpu_expressions(integrator):
    """Per-DOF and sum expressions, the ones Metal mixed compiles to df64."""
    kinds = (mm.CustomIntegrator.ComputePerDof, mm.CustomIntegrator.ComputeSum)
    for i in range(integrator.getNumComputations()):
        kind, variable, expression = integrator.getComputationStep(i)
        if kind in kinds:
            yield variable, expression


def audit(name, integrator):
    if not isinstance(integrator, mm.CustomIntegrator):
        print('%-45s not a CustomIntegrator, fixed kernels only: OK' % name)
        return True
    bad = [(v, e, unsupported(e)) for v, e in gpu_expressions(integrator) if unsupported(e)]
    count = sum(1 for _ in gpu_expressions(integrator))
    print('%-45s %3d per-DOF/sum expressions, %s' % (name, count, 'OK' if not bad else 'FAILS in mixed'))
    for variable, expression, functions in bad:
        print('    %s = %s   uses %s' % (variable, expression, ', '.join(functions)))
    return not bad


def openmmtools_integrators(package):
    sys.path.insert(0, package)
    from openmmtools import integrators
    alchemical = {'lambda_sterics': 'min(1, 2*lambda)', 'lambda_electrostatics': 'max(0, 2*lambda-1)'}
    special = {
        'AlchemicalNonequilibriumLangevinIntegrator': dict(alchemical_functions=alchemical, nsteps_neq=100),
        'PeriodicNonequilibriumIntegrator': dict(alchemical_functions=alchemical, nsteps_eq=10, nsteps_neq=100,
                                                 splitting='V R H O R V'),
        'ExternalPerturbationLangevinIntegrator': {},
        'NoseHooverChainVelocityVerletIntegrator': dict(system=None),
    }
    for name, cls in sorted(inspect.getmembers(integrators, inspect.isclass)):
        if not issubclass(cls, mm.CustomIntegrator) or name in ('ThermostatedIntegrator', 'DummyIntegrator'):
            continue
        yield name, cls, special.get(name, {})


def build(cls, kwargs, system):
    if 'system' in kwargs:
        kwargs = dict(kwargs, system=system)
    return cls(**kwargs)


def main():
    mode = sys.argv[1]
    ok = True
    if mode == 'xml':
        for path in sys.argv[2:]:
            ok &= audit(path, load(path))
    elif mode in ('openmmtools', 'compile'):
        wu = sys.argv[2] if mode == 'compile' else None
        package = sys.argv[3] if mode == 'compile' else sys.argv[2]
        system = state = None
        if wu:
            with bz2.open(os.path.join(wu, 'system.xml.bz2'), 'rt') as f:
                system = mm.XmlSerializer.deserialize(f.read())
            with bz2.open(os.path.join(wu, 'state.xml.bz2'), 'rt') as f:
                state = mm.XmlSerializer.deserialize(f.read())
        for name, cls, kwargs in openmmtools_integrators(package):
            try:
                integrator = build(cls, kwargs, system)
            except Exception as e:
                print('%-45s not built with defaults: %s' % (name, str(e).splitlines()[0][:80]))
                continue
            ok &= audit(name, integrator)
            if wu:
                try:
                    context = mm.Context(system, integrator, mm.Platform.getPlatformByName('Metal'), {'Precision': 'mixed'})
                    context.setState(state)
                    integrator.step(20)
                    energy = context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
                    print('    Metal mixed: compiled and ran 20 steps, E %.1f' % energy)
                    del context
                except Exception as e:
                    ok = False
                    print('    Metal mixed: FAILED %s' % str(e).splitlines()[0][:160])
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
