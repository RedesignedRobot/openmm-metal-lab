"""Time one Folding@home-style work unit the way benchmark.py times a test, for traces and 3x30 timing (r3-fah).

usage: [PROF_SECONDS=4] [PROF_PIDFILE=<file>] [PROF_OUT=<jsonl>] python profwu.py <wu dir> <precision> <platform> [variant ...]

The unit loads as a core loads it: deserialize system, integrator and state, build a Context, setState. Warm-up and
calibration follow benchmark.py (step, then getState(energy)); the timed window is step(n) followed by
getState(energy) on the host clock (time.perf_counter). A CustomIntegrator with `step` and `n_steps` globals (the neq
unit) steps in whole protocol cycles of 2*n_steps, with `step` and `protocol_work` reset before each cycle, so every
timed step moves lambda as a real unit does.

Variants are ablation arms; each keeps the physics of what remains intact:
  nobaro  MonteCarloBarostat frequency 0 (prices the barostat's trial-energy evaluation every 25 steps)
  dt2     2 fs step instead of the unit's own (prices HMR's 4 fs: list rebuilds and constraint iterations per step)
  obc     replace an OBC2 CustomGBForce with a GBSAOBCForce holding the same radii, scales, dielectrics and ACE
          surface term (prices a specialized CustomGB-to-OBC route; check equivalence with `profwu.py --check`)
  nocm    remove CMMotionRemover
One JSON line per run goes to stdout and, if PROF_OUT is set, is appended there.

    python profwu.py --check <wu dir>    energies and forces of the unit and its obc variant on Reference (CPU only)
"""
import bz2
import json
import math
import os
import sys
import time

if os.environ.get("PROF_PIDFILE"):  # tracewu.sh stops a run xctrace left behind by this pid
    with open(os.environ["PROF_PIDFILE"], "w") as f:
        f.write(f"{os.getpid()}\n")

import openmm as mm
import openmm.unit

OBC2_OFFSET = 0.009
ACE_FACTOR = 28.3919551  # 4*pi*2.25936 kJ/mol/nm^2, the surface term customgbforces.py writes


def load(wu, name):
    for path, opener in ((os.path.join(wu, name + ".xml.bz2"), bz2.open), (os.path.join(wu, name + ".xml"), open)):
        if os.path.exists(path):
            with opener(path, "rt") as f:
                return mm.XmlSerializer.deserialize(f.read())
    raise FileNotFoundError(os.path.join(wu, name + ".xml"))


def remove_forces(system, kind):
    for i in reversed(range(system.getNumForces())):
        if isinstance(system.getForce(i), kind):
            system.removeForce(i)


def disable_barostats(system):
    """Frequency 0 turns the barostat off but keeps its MonteCarloPressure and MonteCarloTemperature parameters, so
    the unit's own State still loads (removing the force made setState refuse the state, night 2026-09-30)."""
    for i in range(system.getNumForces()):
        if isinstance(system.getForce(i), mm.MonteCarloBarostat):
            system.getForce(i).setFrequency(0)


def obc_from_custom_gb(system):
    """Swap an OBC2 CustomGBForce (openmm.app customgbforces GBSAOBC2Force, ACE surface term, kappa 0) for GBSAOBCForce."""
    index = [i for i in range(system.getNumForces()) if isinstance(system.getForce(i), mm.CustomGBForce)]
    if len(index) != 1:
        raise ValueError("obc variant needs exactly one CustomGBForce")
    gb = system.getForce(index[0])
    names = [gb.getPerParticleParameterName(k) for k in range(gb.getNumPerParticleParameters())]
    if names != ["charge", "or", "sr"] or "4.85*psi^3" not in gb.getComputedValueParameters(1)[1]:
        raise ValueError("CustomGBForce is not the OBC2 template")
    obc = mm.GBSAOBCForce()
    obc.setNonbondedMethod(mm.GBSAOBCForce.NoCutoff if gb.getNonbondedMethod() == mm.CustomGBForce.NoCutoff
                           else mm.GBSAOBCForce.CutoffNonPeriodic)
    obc.setCutoffDistance(gb.getCutoffDistance())
    obc.setSolventDielectric(78.5)
    obc.setSoluteDielectric(1.0)
    obc.setSurfaceAreaEnergy(ACE_FACTOR/(4*math.pi))
    for i in range(gb.getNumParticles()):
        charge, offset_radius, scaled_radius = gb.getParticleParameters(i)
        obc.addParticle(charge, offset_radius + OBC2_OFFSET, scaled_radius/offset_radius)
    obc.setForceGroup(gb.getForceGroup())
    system.removeForce(index[0])
    system.addForce(obc)


def apply_variants(system, integrator, variants):
    for v in variants:
        if v == "nobaro":
            disable_barostats(system)
        elif v == "nocm":
            remove_forces(system, mm.CMMotionRemover)
        elif v == "dt2":
            integrator.setStepSize(0.002)
        elif v == "obc":
            obc_from_custom_gb(system)
        else:
            raise ValueError("unknown variant " + v)


def protocol_cycle(integrator):
    if not isinstance(integrator, mm.CustomIntegrator):
        return 0
    names = {integrator.getGlobalVariableName(i) for i in range(integrator.getNumGlobalVariables())}
    return int(2*integrator.getGlobalVariableByName("n_steps")) if {"step", "n_steps"} <= names else 0


def check(wu):
    """Reference energies and forces: the unit as written against its obc variant."""
    import numpy as np
    state = load(wu, "state")
    out = []
    for variants in ([], ["obc"]):
        system = load(wu, "system")
        apply_variants(system, mm.VerletIntegrator(0.001), variants)
        context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
        context.setPositions(state.getPositions())
        s = context.getState(getEnergy=True, getForces=True)
        out.append((s.getPotentialEnergy()._value, np.array(s.getForces(asNumpy=True)._value)))
    de = out[1][0] - out[0][0]
    df = np.linalg.norm(out[1][1] - out[0][1], axis=1)
    print(json.dumps(dict(wu=wu, energy=out[0][0], energy_obc=out[1][0], de=de, max_df=float(df.max()),
                          rms_f=float(np.sqrt((np.linalg.norm(out[0][1], axis=1)**2).mean())))))


def main():
    if sys.argv[1] == "--check":
        check(sys.argv[2])
        return
    wu, precision, platform_name = sys.argv[1:4]
    variants = sys.argv[4:]
    seconds = float(os.environ.get("PROF_SECONDS", "4"))
    started = time.perf_counter()
    system, integrator, state = load(wu, "system"), load(wu, "integrator"), load(wu, "state")
    apply_variants(system, integrator, variants)
    platform = mm.Platform.getPlatformByName(platform_name)
    properties = {"Precision": precision} if platform_name in ("Metal", "OpenCL", "CUDA", "HIP") else {}
    context = mm.Context(system, integrator, platform, properties)
    context.setState(state)
    cycle = protocol_cycle(integrator)

    def advance(steps):
        if not cycle:
            integrator.step(steps)
            return
        for _ in range(steps//cycle):
            integrator.setGlobalVariableByName("step", 0)
            integrator.setGlobalVariableByName("protocol_work", 0)
            integrator.step(cycle)

    def window(steps):
        context.getState(getEnergy=True)
        start, cpu = time.perf_counter(), time.process_time()
        advance(steps)
        energy = context.getState(getEnergy=True).getPotentialEnergy()._value
        return time.perf_counter() - start, time.process_time() - cpu, energy

    unit = cycle or 20
    advance(unit)
    setup = time.perf_counter() - started
    steps = unit
    while True:
        elapsed, _, _ = window(steps)
        if elapsed >= 0.5:
            break
        steps = max(unit, int(steps*1.0/max(elapsed, 1e-3)))
        steps = -(-steps//unit)*unit
    steps = max(unit, -(-int(steps*seconds/elapsed)//unit)*unit)
    elapsed, cpu, energy = window(steps)
    dt = integrator.getStepSize().value_in_unit(mm.unit.picoseconds)
    result = dict(wu=os.path.basename(os.path.normpath(wu)), variant="+".join(variants) or "base",
                  platform=platform_name, precision=precision, atoms=system.getNumParticles(), steps=steps,
                  seconds=round(elapsed, 6), us_per_step=round(elapsed/steps*1e6, 3),
                  ns_per_day=round(steps*dt*86400e-3/elapsed, 3), cpu_per_host=round(cpu/elapsed, 3),
                  setup_s=round(setup, 3), energy=energy, finite=math.isfinite(energy),
                  openmm=os.path.dirname(mm.__file__))
    line = json.dumps(result)
    print(line, flush=True)
    if os.environ.get("PROF_OUT"):
        with open(os.environ["PROF_OUT"], "a") as f:
            f.write(line + "\n")


if __name__ == "__main__":
    main()
