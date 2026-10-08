"""Aggregate throughput of several builds: N concurrent simulations of one benchmark.py test, each in its own process.

  agg2.py <outdir> <rounds> <window_s> <tests> <label=python:platform:precision[:VAR=value,...]>...
  agg2.py sum <outdir>
  agg2.py child <outdir> <case> <index> <platform> <precision> <test>

agg.py's method with abw.py's configurations: each label runs its own python, so ultra-base and a candidate tree
compare in one hold. Children build the system and Context exactly as benchmark.py's runOneTest does (abw.setup,
minimizer included for amber20), warm up, report ready and wait for one go file that holds the window's start and
end on the wall clock. Each runs step chunks of about 0.05 s with a getState(energy) sync after each. Cases go
round, test, N, label; N and labels run in reverse order on even rounds. configs.txt records each label's build
(BUILT and srchash, checked as ab.sh does). The run stops if a label's BUILT changes, since a rebuild would give
the next case's children a different library. It must run inside a lease.sh hold, at nice 0.
"""
import glob
import json
import os
import statistics
import subprocess
import sys
import time

import abw

COUNTS = (1, 2, 4, 8)
READY_SECONDS = 300
CASE_EXTRA_SECONDS = 3


def child(root, case, index, platform, precision, test):
    import openmm as mm
    import openmm.unit as unit
    os.chdir(abw.BENCH)
    bench = abw.benchmark_functions()
    context, integ, test_result, temperature = abw.setup(bench, mm, unit, platform, precision, test)
    step_ns = test_result['timestep_in_fs']*1e-6
    context.setVelocitiesToTemperature(temperature)
    integ.step(50)
    context.getState(energy=True)
    start = time.perf_counter()
    integ.step(100)
    context.getState(energy=True)
    chunk = max(1, int(0.05/((time.perf_counter() - start)/100)))
    open(f'{root}/{case}.ready.{index}', 'w').close()
    go = f'{root}/{case}.go'
    while not os.path.exists(go):
        time.sleep(0.005)
    with open(go) as f:
        t_start, t_end = map(float, f.read().split())
    while time.time() < t_start:
        time.sleep(0.001)
    began = time.time()
    finished = [began]
    while finished[-1] < t_end:
        integ.step(chunk)
        context.getState(energy=True)
        finished.append(time.time())
    steps = chunk*(len(finished) - 1)
    elapsed = finished[-1] - began
    print(json.dumps({'index': index, 'steps': steps, 'chunk': chunk, 'began': began, 'ended': finished[-1],
                      'ns_day': steps*step_ns/(elapsed/86400), 'step_ns': step_ns, 'finished': finished,
                      'properties': test_result['platform_properties']}), flush=True)


def cpu_sample(pids):
    children = vm = 0.0
    top = []
    for row in abw.command('ps', '-Ao', 'pid=,pcpu=,comm=').splitlines():
        pid, cpu, comm = row.split(None, 2)
        cpu = float(cpu)
        if int(pid) in pids:
            children += cpu
        if 'Virtualization.VirtualMachine' in comm:
            vm += cpu
        top.append((cpu, os.path.basename(comm)))
    top.sort(reverse=True)
    return {'children_cpu_pct': round(children, 1), 'vm_cpu_pct': round(vm, 1),
            'top': ', '.join(f'{name} {cpu:.0f}%' for cpu, name in top[:5])}


def run_case(root, case, n, config, test, window):
    load = os.getloadavg()[0]
    build_before = abw.build_running()
    env = dict(os.environ, **config.env)
    procs = [subprocess.Popen([config.python, os.path.abspath(__file__), 'child', root, case, str(i), config.platform,
                               config.precision, test], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                              env=env) for i in range(n)]
    head = {'case': case, 'label': config.label, 'test': test, 'platform': config.platform,
            'precision': config.precision, 'n': n}
    deadline = time.time() + READY_SECONDS
    while len(glob.glob(f'{root}/{case}.ready.*')) < n:
        if time.time() > deadline or any(p.poll() is not None for p in procs):
            for p in procs:
                p.kill()
                p.wait()
            return {**head, 'error': 'a child died or never got ready'}
        time.sleep(0.05)
    t_start = time.time() + 0.5
    with open(f'{root}/{case}.go.tmp', 'w') as f:
        f.write(f'{t_start} {t_start + window}')
    os.rename(f'{root}/{case}.go.tmp', f'{root}/{case}.go')
    time.sleep(0.5 + window/2)
    cpu = cpu_sample({p.pid for p in procs})
    build_mid = abw.build_running()
    results = [json.loads(p.communicate()[0]) for p in procs]
    total = sum(r['ns_day'] for r in results)
    common_start = max(r['began'] for r in results)
    common_end = min(r['ended'] for r in results)
    span = max(r['ended'] for r in results) - min(r['began'] for r in results)
    common = 0.0
    for r in results:
        inside = [t for t in r['finished'] if common_start <= t <= common_end]
        if len(inside) >= 2:
            common += r['chunk']*(len(inside) - 1)*r['step_ns']/((inside[-1] - inside[0])/86400)
    return {**head, 'window_s': window, 'total_ns_day': total, 'common_ns_day': common,
            'overlap': (common_end - common_start)/span, 'per_process': [round(r['ns_day'], 2) for r in results],
            'began': [round(r['began'] - t_start, 3) for r in results],
            'ended': [round(r['ended'] - t_start, 3) for r in results], 'chunk': results[0]['chunk'],
            'properties': results[0]['properties'], 'load1_before': load,
            'build_running': build_before or build_mid or abw.build_running(), **cpu}


def built(config):
    tree = config.python[:-len('/venv/bin/python')]
    path = f'{tree}/BUILT'
    return open(path).read() if os.path.isfile(path) else None


def drive(args):
    for name in ('PYTHONPATH', 'OPENMM_CPU_THREADS'):
        os.environ.pop(name, None)
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode-beta.app/Contents/Developer'
    if os.getpriority(os.PRIO_PROCESS, 0) != 0:
        abw.refuse("not at nice 0: launch through /bin/sh -c 'nohup ...'")
    if not os.environ.get('OPENMM_LEASE_PID'):
        abw.refuse('not inside a lease.sh hold: run it as the command of one lease.sh ticket')
    if len(args) < 5:
        abw.refuse(__doc__.splitlines()[2].strip())
    out, rounds, window, tests = args[0].rstrip('/'), int(args[1]), float(args[2]), args[3].split(',')
    known = abw.benchmark_tests()
    for test in tests:
        if test not in known:
            abw.refuse(f"benchmark.py has no test '{test}'")
    configs = [abw.parse_config(spec, False) for spec in args[4:]]
    labels = [config.label for config in configs]
    if len(set(labels)) < len(labels):
        abw.refuse('a label is used twice')
    for config in configs:
        if not config.python.endswith('/venv/bin/python'):
            abw.refuse(f'{config.label}: python is not a build.sh tree venv, so its build cannot be recorded')
    cases = rounds*len(tests)*len(COUNTS)*len(configs)
    estimate = sum(rounds*len(COUNTS)*len(configs)*(abw.setup_seconds(test, 'mixed') + window + CASE_EXTRA_SECONDS)
                   for test in tests)
    if estimate > abw.SCREEN_MAX_SECONDS:
        abw.refuse(f'{cases} cases, about {estimate/60:.0f} min, is over {abw.SCREEN_MAX_SECONDS//60} min: '
                   f'split by test')
    os.makedirs(out, exist_ok=True)
    if os.listdir(out):
        abw.refuse(f'{out} is not empty; use a new outdir per run')
    builds = {config.label: built(config) for config in configs}
    with open(f'{out}/configs.txt', 'w') as f:
        f.write(''.join(config.line + '\n' for config in configs))
    print(f'{cases} cases, about {estimate/60:.0f} min', flush=True)
    print(open(f'{out}/configs.txt').read(), end='', flush=True)
    case = 0
    with open(f'{out}/agg.jsonl', 'a') as log:
        for r in range(1, rounds + 1):
            for test in tests:
                counts = COUNTS if r % 2 else COUNTS[::-1]
                for n in counts:
                    for config in (configs if r % 2 else configs[::-1]):
                        if built(config) != builds[config.label]:
                            print(f'STOPPED: {config.label} was rebuilt during the run', flush=True)
                            sys.exit(3)
                        case += 1
                        result = {'round': r, **run_case(out, f'c{case}', n, config, test, window),
                                  'utc': time.strftime('%H:%M:%SZ', time.gmtime())}
                        log.write(json.dumps(result) + '\n')
                        log.flush()
                        print(r, test, n, config.label, result.get('total_ns_day', result.get('error')),
                              'BUILD RUNNING' if result.get('build_running') else '', flush=True)
    print('done', flush=True)


def summarize(out):
    """Median over rounds of total ns/day per (test, precision, N, label), each label's ratio to the first label
    with the same platform and precision, and each label's scaling against its own N=1."""
    rows = [json.loads(line) for line in open(f'{out}/agg.jsonl')]
    errors = [row for row in rows if 'error' in row]
    rows = [row for row in rows if 'error' not in row]
    labels = list(dict.fromkeys(row['label'] for row in rows))
    median = {}
    for key in {(row['test'], row['platform'], row['precision'], row['n'], row['label']) for row in rows}:
        median[key] = statistics.median(row['total_ns_day'] for row in rows
                                        if (row['test'], row['platform'], row['precision'], row['n'], row['label']) == key)
    for test, platform, precision in sorted({key[:3] for key in median}):
        present = [label for label in labels if (test, platform, precision, 1, label) in median]
        print(f'{test} {platform} {precision}')
        for n in COUNTS:
            cells = []
            for label in present:
                value = median.get((test, platform, precision, n, label))
                if value is None:
                    continue
                scale = value/median[(test, platform, precision, 1, label)]
                ratio = value/median[(test, platform, precision, n, present[0])]
                cells.append(f'{label} {value:.1f} ({scale:.2f}x of N=1, {ratio:.3f} of {present[0]})')
            print(f'  N={n}: ' + ', '.join(cells))
    flagged = sum(1 for row in rows if row.get('build_running'))
    print(f'{len(rows)} cases, {flagged} with a build running, {len(errors)} failed')


if __name__ == '__main__':
    if sys.argv[1:2] == ['child']:
        child(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7])
    elif sys.argv[1:2] == ['sum']:
        summarize(sys.argv[2])
    else:
        drive(sys.argv[1:])
