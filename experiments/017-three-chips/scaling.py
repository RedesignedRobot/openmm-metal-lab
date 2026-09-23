"""How speed and GPU occupancy scale with system size: water boxes from ~2.7k to ~800k atoms.

usage: python scaling.py <platform> <precision> <box-nm> [<box-nm> ...]
Prints one JSON line per box. Each box is TIP3P water (amber14), PME with a 0.9 nm cutoff, rigid
water, LangevinMiddle at 300 K and 2 fs. It is minimized briefly, warmed up for 200 steps, then
timed for 30 s. Clock: host wall (time.perf_counter), whole steps. While the timed steps run, a
thread samples the GPU's "Device Utilization %" from ioreg (IOAccelerator) every 0.5 s.
"""
import json
import re
import statistics
import subprocess
import sys
import threading
import time

import openmm as mm
import openmm.app as app
import openmm.unit as u


def gpu_utilization():
    out = subprocess.run(["ioreg", "-r", "-c", "IOAccelerator", "-d", "1"],
                         capture_output=True, text=True).stdout
    m = re.search(r'"Device Utilization %"=(\d+)', out)
    return int(m.group(1)) if m else None


def sample_until(stop, samples):
    while not stop.is_set():
        value = gpu_utilization()
        if value is not None:
            samples.append(value)
        stop.wait(0.5)


def water_box(nm):
    forcefield = app.ForceField("amber14-all.xml", "amber14/tip3p.xml")
    modeller = app.Modeller(app.Topology(), [])
    modeller.addSolvent(forcefield, boxSize=mm.Vec3(nm, nm, nm) * u.nanometer)
    system = forcefield.createSystem(modeller.topology, nonbondedMethod=app.PME,
                                     nonbondedCutoff=0.9 * u.nanometer, constraints=app.HBonds,
                                     rigidWater=True)
    return system, modeller.positions


def run(platform, precision, nm, seconds=30.0):
    system, positions = water_box(nm)
    integrator = mm.LangevinMiddleIntegrator(300 * u.kelvin, 1 / u.picosecond, 0.002 * u.picoseconds)
    props = {} if platform in ("CPU", "Reference") else {"Precision": precision}
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setPositions(positions)
    mm.LocalEnergyMinimizer.minimize(context, 100, 100)
    context.setVelocitiesToTemperature(300 * u.kelvin)
    integrator.step(200)
    context.getState(getEnergy=True)

    stop, samples = threading.Event(), []
    sampler = threading.Thread(target=sample_until, args=(stop, samples))
    sampler.start()
    steps, start = 0, time.perf_counter()
    while time.perf_counter() - start < seconds:
        integrator.step(100)
        context.getState(getEnergy=True)
        steps += 100
    elapsed = time.perf_counter() - start
    stop.set()
    sampler.join()
    energy = context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)

    return {
        "box_nm": nm, "atoms": system.getNumParticles(), "platform": platform, "precision": precision,
        "ns_per_day": steps * 0.002 / 1000 / elapsed * 86400, "steps": steps, "wall_s": round(elapsed, 2),
        "ms_per_step": elapsed / steps * 1000,
        "gpu_util_median": statistics.median(samples) if samples else None,
        "gpu_util_max": max(samples) if samples else None, "gpu_util_samples": len(samples),
        "final_energy": energy, "clock": "host wall, whole steps",
    }


def main():
    platform, precision = sys.argv[1:3]
    for nm in map(float, sys.argv[3:]):
        print(json.dumps(run(platform, precision, nm)), flush=True)


if __name__ == "__main__":
    main()
