import json, sys
from pathlib import Path
import numpy as np
out=Path(sys.argv[1]); result={}
with np.load(out/'reference.npz') as ref:
    for label in ('candidate', 'int028'):
        with np.load(out/(label+'.npz')) as data:
            rows={}
            for key in ref.files:
                error=data[key]-ref[key]
                where=np.unravel_index(np.abs(error).argmax(),error.shape)
                rows[key]={'relative':float(np.linalg.norm(error)/max(np.linalg.norm(ref[key]),1e-300)),
                           'maximum':float(np.abs(error).max()),'maximum_atom':int(where[0]),
                           'maximum_component':int(where[1])}
            result[label]=rows
    error=np.load(out/'trajectory-forces.npy')-ref['total']
    where=np.unravel_index(np.abs(error).argmax(),error.shape)
    result['trajectory']={'relative':float(np.linalg.norm(error)/np.linalg.norm(ref['total'])),
                          'maximum':float(np.abs(error).max()),'maximum_atom':int(where[0])}
with np.load(out/'candidate.npz') as a, np.load(out/'int028.npz') as b:
    error=a['total']-b['total']
    result['same_positions_candidate_minus_int028']={'maximum':float(np.abs(error).max()),
            'relative':float(np.linalg.norm(error)/np.linalg.norm(b['total']))}
print(json.dumps(result,indent=2))
