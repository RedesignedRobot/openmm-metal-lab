"""Report the pre-registered stationary-geometry ceiling, never force correctness."""
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import statistics

root = Path('/tmp/openmm-metal-bench/ultra-r3-gbown-probe')
archive = Path('~/code/metal/lab/experiments/029-2x-moonshots/lanes/r3-gbown-artifacts')
screen = root/'screen'
records = {}
failures = []
for label in ('baseS', 'baseM', 'probeS', 'probeM'):
    for round_number in (1, 2):
        name = f'{label}-gbsa-round{round_number}.json'
        try:
            data = json.loads((screen/name).read_text())
            rows = data['benchmarks']
            assert len(rows) == 1
            row = rows[0]
            assert row['test'] == 'gbsa' and row['steps'] > 0 and row['elapsed_time'] > 0
            assert math.isfinite(row['elapsed_time']) and math.isfinite(row['steps'])
            geometry = row['fixed_geometry']
            assert geometry['max_drift_nm'] <= 1e-12
            assert geometry['mass_scale'] == 1e30 and geometry['temperature_kelvin'] == 0
            records[name] = data
        except (OSError, KeyError, ValueError, AssertionError) as error:
            failures.append(f'{name}: missing or invalid diagnostic result ({error!r})')

loads = (screen/'loads.txt').read_text() if (screen/'loads.txt').exists() else ''
if not loads:
    failures.append('Screen load evidence is missing.')
if any(marker in loads for marker in ('BUILD RUNNING', 'CPU BUSY', 'NO RESULT')):
    failures.append('The screen reports build overlap, CPU interference, or a missing result.')

lines = ['# GB ownership direction ceiling', '',
         f'Reported {datetime.now(timezone.utc).isoformat()}.', '',
         'Stationary geometry, masses scaled by 1e30, zero temperature, full integration dispatch. '
         'Probe forces omit exclusions and OBC2 arithmetic and are incorrect. '
         'These results are a conditional ceiling, not valid dynamics or a shipping speedup.', '']
ratios = {}
for precision in ('S', 'M'):
    names = [f'{label}{precision}-gbsa-round{r}.json'
             for label in ('base', 'probe') for r in (1, 2)]
    if not all(name in records for name in names):
        continue
    rows = [records[name]['benchmarks'][0] for name in names]
    hashes = {row['fixed_geometry']['rounded_1e10_sha256'] for row in rows}
    if len(hashes) != 1:
        failures.append(f'{precision}: geometry differs between arms or rounds at 1e-10 nm rounding.')
    base = [row['elapsed_time']/row['steps']*1e6 for row in rows[:2]]
    probe = [row['elapsed_time']/row['steps']*1e6 for row in rows[2:]]
    b, p = statistics.median(base), statistics.median(probe)
    ratio = p/b
    ratios[precision] = ratio
    lines += [f"{'Single' if precision == 'S' else 'Mixed'}: baseline {b:.6f} us/step; "
              f'probe {p:.6f} us/step; step ratio {ratio:.9f}; '
              f'throughput ratio {1/ratio:.9f}; step reduction {100*(1-ratio):.4f}%.',
              f'Baseline rounds: {base}. Probe rounds: {probe}.', '']

if failures or 'S' not in ratios:
    verdict = 'INCONCLUSIVE. Do not apply the direction kill to incomplete or confounded evidence.'
else:
    verdict = ('KILL DIRECTION: the single ceiling is below the pre-registered 3% step reduction.'
               if ratios['S'] > 0.97 else
               'DRAFT THIRD DESIGN: the single ceiling meets the pre-registered 3% step reduction.')
lines += [verdict, '', 'The exact keep boundary is probe/baseline step time <= 0.97, '
          'or its reciprocal throughput ratio >= 1/0.97. A and B remain rejected.', '']
lines += [f'- {failure}' for failure in failures]
result = '\n'.join(lines)+'\n'
(archive/'direction-probe-result.md').write_text(result)
(archive/'direction-probe-results.json').write_text(json.dumps(records, indent=2)+'\n')
for name in ('configs.txt', 'loads.txt'):
    if (screen/name).exists():
        (archive/f'direction-probe-{name}').write_bytes((screen/name).read_bytes())
lane_log = archive.parent/'r3-gbown.md'
log = lane_log.read_text()
section = '\n## Direction probe result\n\n'+result.split('\n', 1)[1]+'\n'
log = log.replace('## Deferred run handoff\n', section+'## Deferred run handoff\n', 1)
log = log.replace('These result files do not exist yet. The direction verdict remains pending until the run completes and its geometry and interference checks pass.',
                  'The result files are now archived. The direction verdict and any failed evidence checks appear in the Direction probe result section.')
lane_log.write_text(log)
print(result)
if failures:
    raise SystemExit(1)
