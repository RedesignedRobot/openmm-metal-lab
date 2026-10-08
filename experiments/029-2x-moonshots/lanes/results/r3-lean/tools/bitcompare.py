from pathlib import Path
import numpy as np
root = Path('/tmp/openmm-metal-bench/ultra-r3-lean/correctness')
failed = False
print('test forces_base_mine repeat_force_bits energy_base_repeat energy_mine_repeat energy_base_mine delta_energy')
for path in sorted((root/'base-1').glob('*.npz')):
    rows = [np.load(root/arm/path.name) for arm in ['base-1', 'base-2', 'mine-1', 'mine-2']]
    forces = all(np.array_equal(rows[0]['f'], r['f']) for r in rows[1:])
    repeat = all(bool(r['same']) for r in rows)
    bits = [r['e'].tobytes() for r in rows]
    print(path.stem, forces, repeat, bits[0] == bits[1], bits[2] == bits[3], bits[0] == bits[2], float(rows[2]['e']-rows[0]['e']))
    failed |= not forces or not repeat
if failed:
    raise SystemExit('Deterministic force mismatch')
