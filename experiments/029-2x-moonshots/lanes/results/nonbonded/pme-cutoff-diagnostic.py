"""CPU-only diagnosis, never adjusts gate errors or verdicts."""
import json, math, sys
from pathlib import Path
import numpy as np
import openmm as mm
from openmm import unit as u
out=Path(sys.argv[1])
system=mm.XmlSerializer.deserialize((out/'system.xml').read_text())
positions=np.load(out/'reached.npy')
box=np.array([v.value_in_unit(u.nanometer) for v in system.getDefaultPeriodicBoxVectors()])
if not np.allclose(box,np.diag(np.diag(box))):
    raise RuntimeError('Diagnostic requires an orthogonal box')
box=np.diag(box)
alpha=json.loads((out/'pme-parameters.json').read_text())['alpha_per_nm']
force=next(f for f in system.getForces() if isinstance(f,mm.NonbondedForce))
if force.getUseSwitchingFunction():
    raise RuntimeError('Diagnostic does not model LJ switching')
cutoff=force.getCutoffDistance().value_in_unit(u.nanometer)
band=4*float(np.spacing(np.float32(max(box))))
parameters=np.array([[q.value_in_unit(u.elementary_charge),s.value_in_unit(u.nanometer),e.value_in_unit(u.kilojoule_per_mole)]
                      for q,s,e in [force.getParticleParameters(i) for i in range(system.getNumParticles())]])
exceptions=set()
for index in range(force.getNumExceptions()):
    i,j,*_=force.getExceptionParameters(index); exceptions.add((min(i,j),max(i,j)))
with np.load(out/'reference.npz') as reference:
    error=np.load(out/'trajectory-forces.npy')-reference['total']
top=np.argsort(np.linalg.norm(error,axis=1))[-16:][::-1]
rows=[]; seen=set()
for atom in top:
    delta=positions[atom]-positions
    delta-=box*np.floor(delta/box+0.5)
    distance=np.linalg.norm(delta,axis=1)
    neighbors=np.where(np.abs(distance-cutoff)<=band)[0]
    for partner in neighbors:
        pair=(min(int(atom),int(partner)),max(int(atom),int(partner)))
        if pair in exceptions or pair in seen: continue
        seen.add(pair)
        r=distance[partner]; q1,s1,e1=parameters[atom]; q2,s2,e2=parameters[partner]
        ar=alpha*r
        coulomb=138.935456*q1*q2*(math.erfc(ar)+2*ar/math.sqrt(math.pi)*math.exp(-ar*ar))/r**3
        sr6=((s1+s2)/(2*r))**6
        lj=24*math.sqrt(e1*e2)*sr6*(2*sr6-1)/r**2
        pair_force=(coulomb+lj)*delta[partner]
        norm=float(np.linalg.norm(pair_force))
        matches=[]
        for sign in (-1,1):
            residual=max(float(np.linalg.norm(error[atom]-sign*pair_force)),
                         float(np.linalg.norm(error[partner]+sign*pair_force)))
            matches.append((residual/max(norm,1e-300),sign))
        residual,sign=min(matches)
        rows.append({'atom':int(atom),'partner':int(partner),'distance_minus_cutoff_nm':float(r-cutoff),
                     'pair_force_norm':norm,'pair_force':pair_force.tolist(),
                     'error_atom':error[atom].tolist(),'error_partner':error[partner].tolist(),
                     'best_sign':sign,'relative_pair_residual':residual})
result={'diagnostic_only':True,'alpha_per_nm':alpha,'cutoff_nm':cutoff,'band_nm':band,
        'top_error_atoms':top.tolist(),'near_cutoff_pairs':rows}
(out/'cutoff-diagnostic.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
