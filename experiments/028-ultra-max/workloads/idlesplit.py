#!/usr/bin/env python3
# Read-only: splits the GPU idle in a copy of the lead's gpu-util.log by the kind of lease hold.
# usage: idlesplit.py <gpu-util copy> <obs.txt> [from HH:MM:SS]
# obs.txt holds lease.sh waiter lines ("HH:MM:SSZ waiting for the lease: ... held by: <owner line>, N build
# processes"); each owner line names a hold by lane, start and what. A sample with holder=L maps to L's
# hold with the latest start at or before the sample.
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

IDLE_BELOW = 10
SAMPLE_SECONDS = 5
MAX_SAMPLE_WEIGHT = 15
DAY0 = datetime(2026, 9, 24, tzinfo=timezone.utc)
BURST_START = datetime(2026, 9, 24, 23, 40, 39, tzinfo=timezone.utc)
STALE_SECONDS = 2700
LONG_STRETCH_SECONDS = 30

def classify(what):
    w = what.lower()
    if 'window' in w:
        return 'window'
    if w.startswith('mixed pass') or 'force-eval timing' in w:
        return 'composite'
    if 'gate.sh' in w or 'gate failures' in w:
        return 'gate'
    if re.search(r'drift|census|check|xres|diag|md100|temps|forces-', w):
        return 'correctness'
    if re.search(r'profile|xctrace|gpucapture|counters', w):
        return 'profile'
    if re.search(r'ab\.sh|timing|confirm|knob|spread variants|probes|s1r\d', w):
        return 'timing'
    return 'unknown'

def read_holds(path):
    holds = defaultdict(dict)
    for line in open(path):
        owner = re.sub(r', \d+ build processes$', '', line.split('held by: ', 1)[1].strip())
        owner = owner.replace(' BUILD RUNNING', '')
        m = re.match(r'(\S+) (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (.*)', owner)
        if m:
            start = datetime.strptime(m[2], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
            holds[m[1]][start] = m[3]
            continue
        m = re.match(r'(\S+) lane .*started (\d\d):(\d\d)Z', owner)
        if m:
            holds[m[1]][DAY0.replace(hour=int(m[2]), minute=int(m[3]))] = owner
    return holds

def read_samples(path, since):
    samples = []
    day = DAY0
    last = None
    for line in open(path):
        m = re.match(r'(\d\d):(\d\d):(\d\d) gpu=(\d+) holder=(\S+) queue=(\d+) builds=(\d+)', line)
        if not m:
            continue
        t = day.replace(hour=int(m[1]), minute=int(m[2]), second=int(m[3]))
        if last and t < last:
            day += timedelta(days=1)
            t += timedelta(days=1)
        last = t
        if t.strftime('%H:%M:%S') < since and t.date() == DAY0.date():
            continue
        samples.append((t, int(m[4]), m[5], int(m[6]), int(m[7])))
    return samples

def hold_for(holds, lane, t):
    starts = [s for s in holds.get(lane, {}) if s <= t + timedelta(seconds=SAMPLE_SECONDS)]
    if not starts:
        return None, None
    start = max(starts)
    if (t - start).total_seconds() > STALE_SECONDS:
        return None, None
    return start, holds[lane][start]

def main():
    log, obs = sys.argv[1], sys.argv[2]
    since = sys.argv[3] if len(sys.argv) > 3 else '21:00:00'
    holds = read_holds(obs)
    samples = read_samples(log, since)
    total = 0.0
    by_class = defaultdict(lambda: [0.0, 0.0, 0.0])
    by_hold = defaultdict(lambda: [0.0, 0.0, 0.0])
    runs = defaultdict(list)
    run_class, run_len = None, 0.0
    stretches = []
    cur = None
    gaps = 0
    for i, (t, gpu, lane, queue, builds) in enumerate(samples):
        dt = SAMPLE_SECONDS
        if i + 1 < len(samples):
            dt = (samples[i + 1][0] - t).total_seconds()
            if dt > MAX_SAMPLE_WEIGHT:
                gaps += 1
                dt = SAMPLE_SECONDS
        burst = 'burst' if t >= BURST_START else 'non-burst'
        if lane == 'none':
            cls, key = 'handoff', 'none'
        else:
            start, what = hold_for(holds, lane, t)
            if what is None:
                cls, key = 'unmatched', f'{lane} (no owner line seen)'
            else:
                cls = classify(what)
                key = f'{lane} {start:%H:%MZ} {what}'
        if cls in ('correctness', 'gate'):
            cls = f'{cls} {burst}'
        idle = gpu < IDLE_BELOW
        total += dt
        by_class[cls][0] += dt
        by_hold[key][0] += dt
        if idle:
            by_class[cls][1] += dt
            by_hold[key][1] += dt
            if builds:
                by_class[cls][2] += dt
                by_hold[key][2] += dt
        if idle and cur and cur['key'] == key:
            cur['len'] += dt
            cur['built'] += dt if builds else 0
        else:
            if cur:
                stretches.append(cur)
            cur = {'cls': cls, 'key': key, 'start': t, 'len': dt, 'built': dt if builds else 0} if idle else None
        if idle and run_class == cls:
            run_len += dt
        else:
            if run_class is not None and run_len:
                runs[run_class].append(run_len)
            run_class, run_len = (cls, dt) if idle else (None, 0.0)
    if run_class is not None and run_len:
        runs[run_class].append(run_len)
    if cur:
        stretches.append(cur)
    hours = total / 3600
    idle_total = sum(v[1] for v in by_class.values())
    print(f'window {samples[0][0]:%H:%M:%S}Z to {samples[-1][0]:%H:%M:%S}Z, {len(samples)} samples, {total:.0f} s '
          f'({hours:.2f} h), sample gaps over {MAX_SAMPLE_WEIGHT} s: {gaps}')
    print(f'GPU under {IDLE_BELOW}%: {idle_total:.0f} s, {100 * idle_total / total:.1f}% of the time, '
          f'{idle_total / hours:.0f} s per hour')
    print()
    print(f'{"class":24} {"held s":>7} {"share":>6} {"idle s":>7} {"idle %":>7} {"idle s/h":>8} {"of idle":>7} '
          f'{"idle w/ build s":>15} {"idle stretches: n, median s, max s":>36}')
    for cls, (held, idle, built) in sorted(by_class.items(), key=lambda kv: -kv[1][1]):
        r = sorted(runs[cls])
        stretch = f'{len(r)}, {r[len(r) // 2]:.0f}, {r[-1]:.0f}' if r else '0'
        print(f'{cls:24} {held:7.0f} {100 * held / total:5.1f}% {idle:7.0f} {100 * idle / held:6.1f}% '
              f'{idle / hours:8.0f} {100 * idle / idle_total:6.1f}% {built:15.0f} {stretch:>36}')
    print()
    print(f'{"hold":100} {"held s":>7} {"idle s":>7} {"idle %":>7} {"idle s/h":>8} {"w/ build":>8}')
    for key, (held, idle, built) in sorted(by_hold.items(), key=lambda kv: -kv[1][1]):
        print(f'{key[:100]:100} {held:7.0f} {idle:7.0f} {100 * idle / held:6.1f}% {idle / hours:8.0f} {built:8.0f}')

    print()
    mech = defaultdict(float)
    for st in stretches:
        if st['cls'] == 'handoff':
            m = 'handoff, no holder'
        elif st['len'] < LONG_STRETCH_SECONDS:
            m = f'short stretches under {LONG_STRETCH_SECONDS} s (process start, setup, per-test launch)'
        elif st['built'] > st['len'] / 2:
            m = f'long stretches, a build running most of it'
        else:
            m = f'long stretches, no build (CPU phase inside the hold)'
        mech[m] += st['len']
    print(f'{"mechanism":72} {"idle s":>7} {"idle s/h":>8} {"of idle":>7}')
    for m, v in sorted(mech.items(), key=lambda kv: -kv[1]):
        print(f'{m:72} {v:7.0f} {v / hours:8.0f} {100 * v / idle_total:6.1f}%')
    print()
    print(f'long idle stretches (at least {LONG_STRETCH_SECONDS} s):')
    for st in sorted(stretches, key=lambda st: st['start']):
        if st['len'] >= LONG_STRETCH_SECONDS:
            print(f"  {st['start']:%H:%M:%S}Z {st['len']:4.0f} s, build {st['built']:4.0f} s, {st['cls']:22} {st['key'][:80]}")
    short = defaultdict(lambda: [0, 0.0])
    for st in stretches:
        if st['len'] < LONG_STRETCH_SECONDS and st['cls'] != 'handoff':
            short[st['cls']][0] += 1
            short[st['cls']][1] += st['len']
    print()
    print('short stretches by class: ' + ', '.join(f'{c} {n} x, {v:.0f} s' for c, (n, v) in sorted(short.items(), key=lambda kv: -kv[1][1])))

main()

