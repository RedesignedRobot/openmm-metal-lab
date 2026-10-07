"""Run under the GPU correctness lease. Capture or reevaluate identical positions."""
import json, os, sys
from pathlib import Path
import numpy as np
import openmm as mm
from openmm import unit as u
mode, out_name, label = sys.argv[1:]
out=Path(out_name); out.mkdir(parents=True, exist_ok=True)
force_unit=u.kilojoule_per_mole/u.nanometer
if mode == 'capture':
    bench=Path('/tmp/openmm-metal-bench/ultra-base/benchmarks')
    os.chdir(bench)
    ns={'__name__':'benchmark_definitions'}
    source=(bench/'benchmark.py').read_text()
    exec(source[:source.index('def serializeTest')],ns)
    system, positions, parameters=ns['retrieveTestSystem']('pme')
    integ=mm.LangevinMiddleIntegrator(300*u.kelvin,1/u.picosecond,0.004*u.picoseconds)
    integ.setRandomNumberSeed(2026)
    context=mm.Context(system,integ,mm.Platform.getPlatformByName('Metal'),{'Precision':'single'})
    for force in system.getForces():
        if isinstance(force,mm.NonbondedForce):
            alpha, nx, ny, nz=force.getPMEParametersInContext(context)
            alpha=float(alpha.value_in_unit(u.nanometer**-1) if hasattr(alpha,'value_in_unit') else alpha)
            (out/'pme-parameters.json').write_text(json.dumps({'alpha_per_nm':alpha,'grid':[nx,ny,nz]}))
    context.setPositions(positions); context.setVelocitiesToTemperature(300*u.kelvin,2026)
    integ.step(100)
    state=context.getState(getForces=True,getEnergy=True,getPositions=True)
    np.save(out/'reached.npy',state.getPositions(asNumpy=True).value_in_unit(u.nanometer))
    np.save(out/'trajectory-forces.npy',state.getForces(asNumpy=True).value_in_unit(force_unit))
    (out/'system.xml').write_text(mm.XmlSerializer.serialize(system))
    print('CAPTURED pme single after md100',flush=True)
else:
    system=mm.XmlSerializer.deserialize((out/'system.xml').read_text())
    names=[]
    for index, force in enumerate(system.getForces()):
        force.setForceGroup(index); names.append(type(force).__name__)
    platform=mm.Platform.getPlatformByName('Reference' if label=='reference' else 'Metal')
    props={} if label=='reference' else {'Precision':'single'}
    context=mm.Context(system,mm.VerletIntegrator(0.001),platform,props)
    context.setPositions(np.load(out/'reached.npy')*u.nanometer)
    forces={}
    for index, name in enumerate(names):
        state=context.getState(getForces=True,groups=1<<index)
        forces[str(index)+'-'+name]=np.array(state.getForces(asNumpy=True).value_in_unit(force_unit))
    forces['total']=sum(forces.values())
    np.savez(out/(label+'.npz'),**forces)
    print('EVALUATED',label,names,flush=True)
