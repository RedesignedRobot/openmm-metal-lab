import json, os, shlex, subprocess
from pathlib import Path
lane=Path('/tmp/openmm-metal-bench/ultra-m29-nonbonded')
root='~/lab/ultra-m2.noindex'
remote=root+'/uploads/nonbonded-memory'
host=os.environ['M2']
ssh=['ssh','-o','ConnectTimeout=15',host]
subprocess.run(ssh+['mkdir -p '+shlex.quote(remote)],check=True)
subprocess.run(['rsync',str(lane/'device-memory.swift'),host+':'+remote+'/device-memory.swift'],check=True)
counts=json.loads((lane/'system-atoms.json').read_text())
exclusions=json.loads((lane/'system-exclusion-tiles.json').read_text())
command=['/opt/homebrew/bin/python3',root+'/tools/locked.py',root+'/job.lock',
         root+'/tools/m2-lease.sh','--correctness','ultra-m29-nonbonded','public device memory limits',
         '/usr/bin/xcrun','swift',remote+'/device-memory.swift']
command += [f'{test}:{count}:{exclusions[test]}' for test,count in counts.items()]
with (lane/'device-memory-m2.json').open('w') as output:
    subprocess.run(ssh+[shlex.join(command)],stdout=output,check=True)
print('PASS M2 public memory query',flush=True)
