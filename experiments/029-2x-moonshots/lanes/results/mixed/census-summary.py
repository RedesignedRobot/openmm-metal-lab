from pathlib import Path
import json
root = Path(__file__).resolve().parent / 'census'
result = {}
for kind in ('fused', 'split'):
    rows = {}
    for precision in ('single', 'mixed'):
        data = {}
        for line in (root / f'{kind}-{precision}.err').read_text().splitlines():
            if line.startswith('CENSUS '):
                _, name, count, total = line.split()
                data[name] = (int(count), float(total))
        key = 'integrateLangevinMiddleFused' + ('Shake' if kind == 'split' else '')
        steps = data[key][0]
        rows[precision] = {key: total/steps for key, (count, total) in data.items()}
    result[kind] = rows
    print(f'\n{kind}: GPU microseconds per integrator step, instrumented command buffers')
    print('kernel single mixed excess')
    for key in sorted(set(rows['single']) | set(rows['mixed']), key=lambda k: -rows['mixed'].get(k, 0)):
        single, mixed = rows['single'].get(key, 0), rows['mixed'].get(key, 0)
        if max(single, mixed) > 0.5:
            print(f'{key} {single:.3f} {mixed:.3f} {mixed-single:.3f}')
    single, mixed = sum(rows['single'].values()), sum(rows['mixed'].values())
    print(f'TOTAL {single:.3f} {mixed:.3f} {mixed-single:.3f}')
(root / 'summary.json').write_text(json.dumps(result, indent=2)+'\n')
