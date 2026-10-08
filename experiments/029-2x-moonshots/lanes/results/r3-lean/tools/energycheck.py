from pathlib import Path
import numpy as np
root = Path('/tmp/openmm-metal-bench/ultra-r3-lean/correctness')
paths = sorted((root/'base-1').glob('*.npz'))
assert len(paths) == 14, len(paths)
failed = False
print('test base_repeat_bits mine_repeat_bits base_mine_bits max_base_repeat_ulp max_mine_repeat_ulp max_paired_ulp max_cross_ulp paired_pass')
for path in paths:
    energies = [float(np.load(root/arm/path.name)['e']) for arm in ['base-1', 'base-2', 'mine-1', 'mine-2']]
    ulp = abs(float(np.spacing(np.float32(energies[0]))))
    base = abs(energies[0]-energies[1])/ulp
    mine = abs(energies[2]-energies[3])/ulp
    cross = max(abs(a-b)/ulp for a in energies[:2] for b in energies[2:])
    paired = max(abs(energies[i]-energies[i+2])/ulp for i in range(2))
    good = paired <= 1.0
    print(path.stem, energies[0] == energies[1], energies[2] == energies[3], energies[0] == energies[2], base, mine, paired, cross, good)
    failed |= not good
if failed:
    raise SystemExit('Energy exceeds the brief tolerance')
