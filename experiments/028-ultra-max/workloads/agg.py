"""Aggregate throughput: N concurrent simulations of one benchmark.py system, each in its own process.

  agg.py prep <dir>                  serialize the gbsa and rf systems (benchmark.py's settings) into <dir>; no GPU
  agg.py all <dir> <window_s>        every case, one JSON line each to <dir>/agg.jsonl; run it under one lease.sh hold
  agg.py child <dir> <case> <index> <platform> <precision> <test>

Children build their Context, warm up, report ready, then wait for a shared go file that holds the start and
end of the window on the wall clock. Each runs step chunks of about 0.05 s (solo speed) until the end, with a
getState(energy) sync after every chunk so no process runs on alone after the window. Each reports its actual
start and end on the wall clock and the time every chunk finished. The parent reports two sums: total_ns_day
over each process's own start-to-last-sync time, and common_ns_day, where each process's rate counts only the
chunks that finished inside the interval all N were running (latest start to earliest end). overlap is that
interval over the span from earliest start to latest end.
"""
import glob
import json
import os
import subprocess
import sys
import time

import openmm as mm
import openmm.app as app
import openmm.unit as unit

BENCH = '/tmp/openmm-metal-bench/ultra-base/benchmarks'
TESTS = ('gbsa', 'rf')
COUNTS = (1, 2, 4, 8)
CONFIGS = (('Metal', 'single'), ('OpenCL', 'single'), ('Metal', 'mixed'))
STEP_PS = 0.004


def build(test):
    os.chdir(BENCH)
    if test == 'gbsa':
        pdb = app.PDBFile('5dfr_minimized.pdb')
        ff = app.ForceField('amber99sb.xml', 'amber99_obc.xml')
        system = ff.createSystem(pdb.topology, nonbondedMethod=app.CutoffNonPeriodic, nonbondedCutoff=2.0,
                                 constraints=app.HBonds, hydrogenMass=1.5*unit.amu)
    else:
        pdb = app.PDBFile('5dfr_solv-cube_equil.pdb')
        ff = app.ForceField('amber99sb.xml', 'tip3p.xml')
        system = ff.createSystem(pdb.topology, nonbondedMethod=app.CutoffPeriodic, nonbondedCutoff=1.0,
                                 constraints=app.HBonds, hydrogenMass=1.5*unit.amu)
    return system, pdb


def prep(root):
    os.makedirs(root, exist_ok=True)
    for test in TESTS:
        system, pdb = build(test)
        with open(f'{root}/{test}-system.xml', 'w') as f:
            f.write(mm.XmlSerializer.serialize(system))
        with open(f'{root}/{test}-positions.pdb', 'w') as f:
            app.PDBFile.writeFile(pdb.topology, pdb.positions, f)


def child(root, case, index, platform, precision, test):
    with open(f'{root}/{test}-system.xml') as f:
        system = mm.XmlSerializer.deserialize(f.read())
    positions = app.PDBFile(f'{root}/{test}-positions.pdb').positions
    friction = 91 if test == 'gbsa' else 1
    integ = mm.LangevinMiddleIntegrator(300*unit.kelvin, friction/unit.picosecond, STEP_PS*unit.picoseconds)
    integ.setConstraintTolerance(1e-5)
    ctx = mm.Context(system, integ, mm.Platform.getPlatformByName(platform), {'Precision': precision})
    ctx.setPositions(positions)
    ctx.setVelocitiesToTemperature(300*unit.kelvin)
    integ.step(50)
    ctx.getState(energy=True)
    start = time.perf_counter()
    integ.step(100)
    ctx.getState(energy=True)
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
        ctx.getState(energy=True)
        finished.append(time.time())
    steps = chunk*(len(finished) - 1)
    elapsed = finished[-1] - began
    print(json.dumps({'index': index, 'steps': steps, 'chunk': chunk, 'began': began, 'ended': finished[-1],
                      'elapsed': elapsed, 'ns_day': steps*STEP_PS*1e-3/(elapsed/86400), 'finished': finished}),
          flush=True)


def cpu_sample(pids):
    rows = subprocess.run(['ps', '-Ao', 'pid=,pcpu=,comm='], capture_output=True, text=True).stdout.splitlines()
    children = vm = 0.0
    top = []
    for row in rows:
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


def run_case(root, case, n, platform, precision, test, window):
    load = os.getloadavg()[0]
    procs = [subprocess.Popen([sys.executable, __file__, 'child', root, case, str(i), platform, precision, test],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True) for i in range(n)]
    deadline = time.time() + 180
    while len(glob.glob(f'{root}/{case}.ready.*')) < n:
        if time.time() > deadline or any(p.poll() is not None for p in procs):
            for p in procs:
                p.kill()
            return {'case': case, 'test': test, 'platform': platform, 'precision': precision, 'n': n,
                    'error': 'a child died or never got ready'}
        time.sleep(0.05)
    t_start = time.time() + 0.5
    with open(f'{root}/{case}.go.tmp', 'w') as f:
        f.write(f'{t_start} {t_start + window}')
    os.rename(f'{root}/{case}.go.tmp', f'{root}/{case}.go')
    time.sleep(0.5 + window/2)
    cpu = cpu_sample({p.pid for p in procs})
    results = [json.loads(p.communicate()[0]) for p in procs]
    total = sum(r['ns_day'] for r in results)
    common_start = max(r['began'] for r in results)
    common_end = min(r['ended'] for r in results)
    span = max(r['ended'] for r in results) - min(r['began'] for r in results)
    common = 0.0
    for r in results:
        inside = [t for t in r['finished'] if common_start <= t <= common_end]
        if len(inside) >= 2:
            common += r['chunk']*(len(inside) - 1)*STEP_PS*1e-3/((inside[-1] - inside[0])/86400)
    return {'case': case, 'test': test, 'platform': platform, 'precision': precision, 'n': n, 'window_s': window,
            'total_ns_day': total, 'common_ns_day': common, 'overlap': (common_end - common_start)/span,
            'per_process': [round(r['ns_day'], 2) for r in results],
            'began': [round(r['began'] - t_start, 3) for r in results],
            'ended': [round(r['ended'] - t_start, 3) for r in results], 'chunk': results[0]['chunk'],
            'load1_before': load, **cpu}


def run_all(root, window):
    nice = int(subprocess.run(['ps', '-o', 'nice=', '-p', str(os.getpid())], capture_output=True, text=True).stdout)
    if nice != 0:
        sys.exit(f'running at nice {nice}, not 0')
    out = open(f'{root}/agg.jsonl', 'a')
    case = 0
    for test in TESTS:
        for k, n in enumerate(COUNTS):
            configs = CONFIGS if k % 2 == 0 else CONFIGS[::-1]
            for platform, precision in configs:
                case += 1
                result = run_case(root, f'c{case}', n, platform, precision, test, window)
                result['utc'] = time.strftime('%H:%M:%SZ', time.gmtime())
                out.write(json.dumps(result) + '\n')
                out.flush()
                print(result.get('total_ns_day', result.get('error')), result.get('common_ns_day'), result.get('overlap'),
                      test, platform, precision, n, flush=True)


if __name__ == '__main__':
    mode = sys.argv[1]
    if mode == 'prep':
        prep(sys.argv[2])
    elif mode == 'all':
        run_all(sys.argv[2], float(sys.argv[3]))
    elif mode == 'child':
        child(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7])
    else:
        sys.exit(__doc__)
