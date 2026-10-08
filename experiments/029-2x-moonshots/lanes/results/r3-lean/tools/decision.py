import json
import statistics as st
from collections import defaultdict
from pathlib import Path
root = Path('/tmp/openmm-metal-bench/ultra-r3-lean')
rates, times = defaultdict(list), defaultdict(list)
for folder in ['screen1', 'screen2']:
    for path in (root/folder).glob('*.json'):
        label = path.name.split('-round')[0]
        for row in json.loads(path.read_text()).get('benchmarks', []):
            test = row['test']
            arm = label[:-(len(test)+1)]
            rates[test, arm].append(row['ns_per_day'])
            times[test, arm].append(row['timestep_in_fs']*86400/row['ns_per_day'])
tests = ['gbsa', 'rf', 'pme', 'apoa1rf', 'apoa1pme', 'amber20-cellulose', 'amber20-stmv']
ratios, saved = {}, {}
print('test precision base_us candidate_us saved_us throughput_change_percent')
for test in tests:
    for precision in ['single', 'mixed']:
        keys = [(test, arm+'-'+precision) for arm in ['base', 'mine']]
        assert all(len(rates[k]) == 2 for k in keys), (test, precision, [len(rates[k]) for k in keys])
        base, mine = [st.median(times[k]) for k in keys]
        ratio = st.median(rates[keys[1]])/st.median(rates[keys[0]])
        ratios[test, precision] = ratio
        saved[test, precision] = base-mine
        print(test, precision, f'{base:.3f}', f'{mine:.3f}', f'{base-mine:+.3f}', f'{100*(ratio-1):+.3f}')
kills = []
for precision in ['single', 'mixed']:
    kill = saved['gbsa', precision] >= 5 or saved['apoa1rf', precision] >= 10
    kills.append(kill)
    print('Kill threshold met:', precision, kill)
print('3 percent gain reached:', any(r >= 1.03 for r in ratios.values()))
print('No loss over 1 percent on measured tests:', all(r >= 0.99 for r in ratios.values()))
print('Raw throughput conditions, before quality review:', any(r >= 1.03 for r in ratios.values()) and all(r >= 0.99 for r in ratios.values()))
print('Accepted under kill rule:', all(kills) and any(r >= 1.03 for r in ratios.values()) and all(r >= 0.99 for r in ratios.values()))
print('Quality: GBSA single round 1 and STMV mixed candidate round 1 overlapped builds. APOA1 PME single baseline spread is 14.8%; its apparent gain is not a repeatable 3 percent win.')
