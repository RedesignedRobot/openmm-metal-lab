"""Run the unchanged forces.py, saving its pme/single state after evaluation."""
import json, runpy, sys
from pathlib import Path
import numpy as np
import openmm as mm
from openmm import unit as u
capture=Path(sys.argv.pop(1)); capture.mkdir(parents=True,exist_ok=True)
original=mm.Context.getState
def capture_state(context,*args,**kwargs):
    state=original(context,*args,**kwargs)
    platform=context.getPlatform()
    if (platform.getName()=='Metal' and context.getStepCount()==100 and
        platform.getPropertyValue(context,'Precision')=='single' and kwargs.get('getForces') and kwargs.get('getPositions')):
        system=context.getSystem()
        force=next((f for f in system.getForces() if isinstance(f,mm.NonbondedForce)),None)
        if system.getNumParticles()==23558 and force is not None and force.getNonbondedMethod()==mm.NonbondedForce.PME:
            np.save(capture/'reached.npy',state.getPositions(asNumpy=True).value_in_unit(u.nanometer))
            np.save(capture/'trajectory-forces.npy',state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
            (capture/'system.xml').write_text(mm.XmlSerializer.serialize(system))
            alpha,nx,ny,nz=force.getPMEParametersInContext(context)
            alpha=float(alpha.value_in_unit(u.nanometer**-1) if hasattr(alpha,'value_in_unit') else alpha)
            (capture/'pme-parameters.json').write_text(json.dumps({'alpha_per_nm':alpha,'grid':[nx,ny,nz]}))
    return state
mm.Context.getState=capture_state
script=Path('/tmp/openmm-metal-bench/ultra-tools/forces.py')
sys.path.insert(0,str(script.parent)); sys.argv[0]=str(script)
runpy.run_path(str(script),run_name='__main__')
