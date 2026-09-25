"""Warm-process ab.sh: each (configuration, test) pays benchmark.py's setup once per screen, not once per run.

  abw.py [--cold <label>,...] [--validate] <outdir> <rounds> <seconds> <tests|all> <configuration>...

Runs on the M3 Ultra at nice 0, with ab.sh's arguments, refusals, estimate and lease self-wrap: the whole
screen is one lease.sh timing hold, and inside another hold it runs at once. A configuration is
label=python:platform:precision[:VAR=value,...], as for ab.sh.
Pre-phase, before anything is timed: one worker process per (configuration, test), started with that
configuration's python and settings, loads benchmark.py's functions without its command-line code, builds the
system with its retrieveTestSystem, makes the integrator and Context the way runOneTest does, sets the
positions (and minimizes for amber20), reports ready and its memory, then blocks on stdin. The workers set up
in parallel; the first run starts only after every worker is ready.
Rounds: ab.sh's order exactly (round, then test, then configurations, reversed on even rounds), one run at a
time. The driver tells one worker to run; it puts back its post-setup positions, draws new velocities, runs
benchmark.py's adaptive loop around benchmark.py's timeIntegration (host clock), and writes
<label>-<test>-round<r>.json with benchmark.py's appendTestResult, so summarize.py reads the outdir as is.
The other workers sit blocked in a read, with no polling.
--cold runs the listed labels as ab.sh does, a fresh benchmark.py process per run through tools/ab-test.sh,
interleaved with the warm runs in the same order (the A/A check).
loads.txt gets ab-test.sh's lines for every run: load, Hyperscale VM CPU and top 5 before it, BUILD RUNNING,
CPU sampling and CPU BUSY for CPU-platform runs, NO RESULT. memory.txt gets each worker's resident size,
physical footprint and peak resident size at ready and after every run. runs.txt gets each run's wall time
from the driver's side, cold and warm. workers.txt records the driver's and each worker's pid (RULES: stop only
by recorded pid); a worker exits when the driver closes its stdin or dies. A cold run in flight when the driver
is stopped by pid runs on, as under ab.sh; lease.sh's cap stops the whole process group.
A warm CPU-platform run's samples cover its timed loop only; ab-test.sh's also cover a cold run's setup.
--validate skips the lease and accepts only Reference:double and CPU configurations that set OPENMM_CPU_THREADS
to 1 or 2: for checking the tool with no GPU ticket. Its numbers are not timings.
  /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-base/venv/bin/python /tmp/openmm-metal-bench/ultra-workloads/abw.py /tmp/openmm-metal-bench/ultra-<lane>/abw1 2 15 gbsa,rf,pme base=/tmp/openmm-metal-bench/ultra-base/venv/bin/python:Metal:single > /tmp/openmm-metal-bench/ultra-<lane>/abw1.out 2>&1 < /dev/null &'
"""
import argparse
import ast
import json
import os
import re
import select
import signal
import subprocess
import sys
import threading
import time
import types

ABW = os.path.abspath(__file__)
TOOLS = '/tmp/openmm-metal-bench/ultra-tools'
BENCH = '/tmp/openmm-metal-bench/ultra-base/benchmarks'
ALL = 'gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose,amber20-stmv'
SCREEN_MAX_SECONDS = 1080
RUN_CAP_EXTRA_SECONDS = 900
# benchmark.py's loop runs 20 steps and about 1 s of steps before its timed call; a warm run pays only that
# beyond <seconds>, where a cold run pays setup_seconds.
WARM_RUN_EXTRA_SECONDS = 2
TIMED = ('Metal:single', 'Metal:mixed', 'OpenCL:single', 'CPU:single', 'CPU:mixed')
BUILDS = r'clang|clang\+\+|ninja|cc1plus'
CPU_SAMPLE_SECONDS = 5
CPU_BUSY_PERCENT = 100
INITIAL_STEPS = 5
RUSAGE_INFO_V0 = 0


def setup_seconds(test, precision):
    """ab.sh's table: seconds of setup per cold run beyond <seconds> on the M3 Ultra."""
    if test == 'amber20-cellulose':
        return 47 if precision == 'mixed' else 12
    if test.startswith('apoa1'):
        return 6
    return {'amber20-stmv': 60, 'amoebapme': 20, 'amoebagk': 15}.get(test, 4)


def refuse(reason):
    """ab.sh's refusal: the reason on stderr, exit 2."""
    print(reason, file=sys.stderr)
    sys.exit(2)


def stamp():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def append(path, line):
    with open(path, 'a') as f:
        f.write(line + '\n')


def command(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


# Driver.

def parse_config(spec, validate):
    label, _, rest = spec.partition('=')
    python, platform, precision, settings = (rest.split(':', 3) + ['', '', '', ''])[:4]
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', label):
        refuse(f"bad label '{label}' in {spec}: use letters, digits, '.', '_' and '-'")
    if not python.startswith('/'):
        refuse(f'python must be an absolute path in {spec}')
    if not os.access(python, os.X_OK):
        refuse(f'{python} is not executable')
    allowed = ('Reference:double', 'CPU:single', 'CPU:mixed') if validate else TIMED
    if f'{platform}:{precision}' not in allowed:
        refuse(f'platform:precision {platform}:{precision} is not one of {", ".join(allowed)}')
    built = 'not a build.sh tree'
    tree = python[:-len('/venv/bin/python')] if python.endswith('/venv/bin/python') else ''
    if tree and os.path.isdir(f'{tree}/build'):
        if not os.path.isfile(f'{tree}/BUILT'):
            refuse(f'{tree}/BUILT is missing: a build.sh is running there, or the last one failed')
        lines = open(f'{tree}/BUILT').read().splitlines()
        recorded = next((line[4:] for line in lines if line.startswith('src ')), '')
        if recorded != command(f'{TOOLS}/srchash.sh', tree).strip():
            refuse(f'{tree}/src changed after build.sh; rebuild before timing {label}')
        built = ' '.join(lines) + ' '
    info = subprocess.run([python, '-c', 'import openmm; print(openmm.__file__, openmm.version.git_revision)'],
                          cwd='/', capture_output=True, text=True)
    if info.returncode:
        refuse(f"{python} can't import openmm")
    items = [setting for setting in settings.split(',') if setting]
    for setting in items:
        if '=' not in setting:
            refuse(f"setting '{setting}' in {spec} is not VAR=value")
    env = dict(setting.split('=', 1) for setting in items)
    if validate and platform == 'CPU' and env.get('OPENMM_CPU_THREADS') not in ('1', '2'):
        refuse(f'--validate runs with no lease: set OPENMM_CPU_THREADS=1 or 2 in {spec}')
    return types.SimpleNamespace(spec=spec, label=label, python=python, platform=platform, precision=precision,
                                 env=env, cold=False,
                                 line=f'{label} {platform} {precision} settings={settings or "none"} '
                                      f'{info.stdout.strip()} {built}')


def benchmark_tests():
    """benchmark.py's TESTS tuple, which it checks --test against."""
    path = os.path.join(BENCH, 'benchmark.py')
    for node in ast.parse(open(path).read(), path).body:
        if isinstance(node, ast.Assign) and any(getattr(target, 'id', '') == 'TESTS' for target in node.targets):
            return ast.literal_eval(node.value)
    return ()


def build_running():
    return subprocess.run(['pgrep', '-x', BUILDS], capture_output=True).returncode == 0


def before_run():
    """ab-test.sh's load, Hyperscale VM CPU and top 5 CPU processes."""
    vm = sum(float(line.split(None, 1)[0]) for line in command('ps', '-Ao', 'pcpu=,comm=').splitlines()
             if 'Virtualization.VirtualMachine' in line)
    top = []
    for line in command('ps', '-Aro', 'pcpu=,comm=').splitlines()[:5]:
        cpu, name = line.split(None, 1)
        top.append(f'{name.split("/")[-1]} {cpu}%')
    return f'load {command("sysctl", "-n", "vm.loadavg").strip()}', f'vm {vm:.0f}% top {", ".join(top)}'


class RunWatch:
    """What ab-test.sh watches during a run: a build starting (every second) and, for a CPU-platform run, the
    worker's %CPU, the busiest other process and the Hyperscale VM (every CPU_SAMPLE_SECONDS)."""

    def __init__(self, cpu_pid=None):
        self.build_seen = False
        self.samples = []
        self.done = threading.Event()
        self.threads = [threading.Thread(target=self.watch_builds, daemon=True)]
        if cpu_pid:
            self.threads.append(threading.Thread(target=self.sample_cpu, args=(cpu_pid,), daemon=True))
        for thread in self.threads:
            thread.start()

    def watch_builds(self):
        while not self.done.is_set():
            if build_running():
                self.build_seen = True
                return
            self.done.wait(1)

    def sample_cpu(self, pid):
        while not self.done.wait(CPU_SAMPLE_SECONDS):
            own, top, name, vm = 0.0, 0.0, '', 0.0
            for line in command('ps', '-Ao', 'pid=,pcpu=,comm=').splitlines():
                fields = line.split(None, 2)
                if len(fields) < 3:
                    continue
                cpu = float(fields[1])
                if int(fields[0]) == pid:
                    own = cpu
                    continue
                if cpu > top:
                    top, name = cpu, fields[2].split()[0].split('/')[-1]
                if 'Virtualization.VirtualMachine' in line:
                    vm += cpu
            self.samples.append((round(own), round(top), name, round(vm)))

    def stop(self):
        self.done.set()
        for thread in self.threads:
            thread.join()

    def cpu_summary(self):
        own = [sample[0] for sample in self.samples]
        top = max(self.samples, key=lambda sample: sample[1], default=(0, 0, '', 0))
        vm = max((sample[3] for sample in self.samples), default=0)
        busy = ' CPU BUSY' if top[1] > CPU_BUSY_PERCENT else ''
        return (f'{len(own)} samples: benchmark {min(own, default=0):.0f}% to {max(own, default=0):.0f}%, '
                f'busiest other {top[1]:.0f}% ({top[2]}), VM up to {vm:.0f}%{busy}')


def receive(worker, timeout):
    """The worker's next message, or None on EOF or timeout. The protocol is one line per request, so nothing
    is left in the pipe after a line."""
    deadline = time.monotonic() + timeout
    data = b''
    while not data.endswith(b'\n'):
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([worker.proc.stdout], [], [], left)[0]:
            return None
        chunk = os.read(worker.proc.stdout.fileno(), 65536)
        if not chunk:
            return None
        data += chunk
    return json.loads(data)


def memory_line(message):
    return (f'resident {message["resident_mb"]} MB footprint {message["footprint_mb"]} MB '
            f'peak resident {message["peak_resident_mb"]} MB')


def start_workers(configs, tests, seconds, out):
    workers = []
    for config in configs:
        if config.cold:
            continue
        for test in tests:
            proc = subprocess.Popen([config.python, ABW, 'worker', config.platform, config.precision, test, str(seconds)],
                                    env=dict(os.environ, **config.env), stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            append(f'{out}/workers.txt', f'{stamp()} pid {proc.pid} {config.label} {test}')
            workers.append(types.SimpleNamespace(proc=proc, label=config.label, test=test, alive=True, threads=None))
    for worker in workers:
        message = receive(worker, RUN_CAP_EXTRA_SECONDS)
        if not message or 'error' in message:
            reason = message['error'] if message else 'no ready message'
            append(f'{out}/loads.txt', f'{stamp()} NOT READY {worker.label} {worker.test} pid {worker.proc.pid}: {reason}')
            stop_worker(worker)
            continue
        worker.threads = message['platform_properties'].get('Threads', 'unknown')
        append(f'{out}/memory.txt', f'{stamp()} {worker.label} {worker.test} pid {worker.proc.pid} ready after '
                                    f'{message["setup_seconds"]:.1f} s {memory_line(message)}')
    return {(worker.label, worker.test): worker for worker in workers}


def stop_worker(worker):
    worker.alive = False
    if worker.proc.poll() is None:
        os.kill(worker.proc.pid, signal.SIGKILL)
    worker.proc.wait()
    try:
        worker.proc.stdin.close()
    except OSError:
        pass  # a request left in the buffer for a dead worker


def run_warm(worker, config, r, test, seconds, out):
    label = config.label
    result = f'{out}/{label}-{test}-round{r}.json'
    loads = f'{out}/loads.txt'
    build_note = ' BUILD RUNNING' if build_running() else ''
    load, rest = before_run()
    append(loads, f'{stamp()} round {r} {test} {label} {load}{build_note} {rest}')
    cpu = config.platform == 'CPU' and worker.alive
    watch = RunWatch(worker.proc.pid if cpu else None)
    began = time.monotonic()
    if worker.alive:
        try:
            worker.proc.stdin.write((json.dumps({'outfile': result}) + '\n').encode())
            worker.proc.stdin.flush()
            message = receive(worker, seconds + RUN_CAP_EXTRA_SECONDS)
        except OSError:
            message = None
        if message is None:
            append(loads, f'{stamp()} round {r} {test} {label} worker pid {worker.proc.pid} died or ran over '
                          f'{seconds + RUN_CAP_EXTRA_SECONDS} s; stopped')
            stop_worker(worker)
        else:
            if 'error' in message:
                append(loads, f'{stamp()} round {r} {test} {label} OpenMMException: {message["error"]}')
            append(f'{out}/memory.txt', f'{stamp()} {label} {test} pid {worker.proc.pid} after round {r} '
                                        f'{memory_line(message)}')
    wall = time.monotonic() - began
    watch.stop()
    if cpu:
        append(loads, f'{stamp()} round {r} {test} {label} cpu threads {worker.threads}, {watch.cpu_summary()}')
    if not build_note and watch.build_seen:
        append(loads, f'{stamp()} round {r} {test} {label} BUILD RUNNING during the run')
    if not (os.path.exists(result) and os.path.getsize(result)):
        line = f'{stamp()} NO RESULT round {r} {test} {label}'
        print(line)
        append(loads, line)
    append(f'{out}/runs.txt', f'{stamp()} round {r} {test} {label} warm {wall:.1f} s')


def run_cold(config, r, test, seconds, out):
    env = dict(os.environ, AB_OUT=out, AB_ROUND=str(r), AB_TEST=test, AB_SECONDS=str(seconds))
    began = time.monotonic()
    code = subprocess.run([f'{TOOLS}/ab-test.sh', config.spec], env=env).returncode
    wall = time.monotonic() - began
    if code:
        line = f'{stamp()} round {r} {test} ended with exit {code}'
        print(line)
        append(f'{out}/loads.txt', line)
    append(f'{out}/runs.txt', f'{stamp()} round {r} {test} {config.label} cold {wall:.1f} s')


def drive():
    for name in ('PYTHONPATH', 'OPENMM_CPU_THREADS'):
        os.environ.pop(name, None)
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode-beta.app/Contents/Developer'
    nice = os.getpriority(os.PRIO_PROCESS, 0)
    if nice != 0:
        refuse(f"running at nice {nice}, not 0: launch through /bin/sh -c 'nohup ...'")
    parser = argparse.ArgumentParser(usage=__doc__.splitlines()[2].strip())
    parser.add_argument('--cold', default='')
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('outdir')
    parser.add_argument('rounds', type=int)
    parser.add_argument('seconds', type=int)
    parser.add_argument('tests')
    parser.add_argument('configs', nargs='+')
    args = parser.parse_args()
    if not args.outdir.startswith('/'):
        refuse('the outdir must be an absolute path')
    out = args.outdir.rstrip('/')
    tests = [test for test in (ALL if args.tests == 'all' else args.tests).split(',') if test]
    known = benchmark_tests()
    for test in tests:
        if test not in known:
            refuse(f"benchmark.py has no test '{test}': {', '.join(known)}")
    lane = re.match(r'/tmp/openmm-metal-bench/(ultra-[^/]*)/', out)
    lane = lane.group(1) if lane else os.environ.get('AB_LANE', '')
    if not lane:
        refuse('no lane: put the outdir under /tmp/openmm-metal-bench/ultra-<lane>/ or set AB_LANE')
    os.makedirs(out, exist_ok=True)
    if os.listdir(out):
        refuse(f'{out} is not empty; use a new outdir per run')

    configs = [parse_config(spec, args.validate) for spec in args.configs]
    labels = [config.label for config in configs]
    for label in labels:
        if labels.count(label) > 1:
            refuse(f'label {label} is used twice')
    cold = [label for label in args.cold.split(',') if label]
    for label in cold:
        if label not in labels:
            refuse(f'--cold names {label}, which is not a configuration label')
    for config in configs:
        config.cold = config.label in cold

    estimate = 0
    for config in configs:
        for test in tests:
            setup = setup_seconds(test, config.precision)
            run = args.seconds + (setup if config.cold else WARM_RUN_EXTRA_SECONDS)
            if config.platform == 'CPU':
                run += args.seconds
            estimate += args.rounds*run + (0 if config.cold else setup)
    if not os.environ.get('AB_HELD'):
        print(f'estimate: {args.rounds} rounds, {len(tests)} tests, {len(configs)} configurations '
              f'({len(configs) - len(cold)} warm), about {estimate // 60} min {estimate % 60} s', flush=True)
        if not os.environ.get('OPENMM_WINDOW') and estimate > SCREEN_MAX_SECONDS:
            refuse(f'the estimate is over {SCREEN_MAX_SECONDS // 60} minutes: split the screen by test into several '
                     f'abw.py calls')
        if not args.validate:
            os.environ['AB_HELD'] = '1'
            lease = f'{TOOLS}/lease.sh'
            os.execv(lease, [lease, lane, f'abw.py {out}, about {(estimate + 59) // 60} min',
                             sys.executable, ABW] + sys.argv[1:])

    with open(f'{out}/configs.txt', 'w') as f:
        f.write(''.join(config.line + '\n' for config in configs))
    print(open(f'{out}/configs.txt').read(), end='')
    os.chdir(BENCH)
    append(f'{out}/workers.txt', f'{stamp()} pid {os.getpid()} driver')
    began = time.monotonic()
    workers = start_workers(configs, tests, args.seconds, out)
    print(f'pre-phase: {sum(worker.alive for worker in workers.values())} of {len(workers)} workers ready after '
          f'{time.monotonic() - began:.1f} s')
    for r in range(1, args.rounds + 1):
        order = configs if r % 2 else configs[::-1]
        for test in tests:
            for config in order:
                if config.cold:
                    run_cold(config, r, test, args.seconds, out)
                else:
                    run_warm(workers[(config.label, test)], config, r, test, args.seconds, out)
    for worker in workers.values():
        if worker.alive:
            worker.proc.stdin.close()
            worker.proc.wait()
    print(f'done {out}')


# Worker: runs under the configuration's python, with openmm.

def benchmark_functions():
    """benchmark.py's imports and functions, without its command-line code, which runs on import."""
    path = os.path.join(BENCH, 'benchmark.py')
    tree = ast.parse(open(path).read(), path)
    tree.body = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef))]
    namespace = {'__name__': 'benchmark'}
    exec(compile(tree, path, 'exec'), namespace)
    return namespace


def memory_mb():
    """This process's resident size, physical footprint (Activity Monitor's figure, which counts GPU buffers the
    process owns) and peak resident size."""
    import ctypes
    import resource
    info = (ctypes.c_uint64*12)()
    # rusage_info_v0: a 16-byte uuid, then user and system time, idle and interrupt wakeups, pageins, wired
    # size, resident size, physical footprint, start and exit time.
    ctypes.CDLL('/usr/lib/libSystem.B.dylib').proc_pid_rusage(os.getpid(), RUSAGE_INFO_V0, info)
    return {'resident_mb': info[8] >> 20, 'footprint_mb': info[9] >> 20,
            'peak_resident_mb': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss >> 20}


def setup(bench, mm, unit, platform_name, precision, test):
    """runOneTest up to its timing loop, with benchmark.py's defaults as ab-test.sh runs it: NVT, hbonds,
    PME cutoff 0.9 nm, no device index."""
    system, positions, test_parameters = bench['retrieveTestSystem'](test, pme_cutoff=0.9, bond_constraints='hbonds',
                                                                     polarization='mutual', epsilon=1e-5)
    test_result = test_parameters.copy()
    test_result['ensemble'] = 'NVT'
    test_result['precision'] = precision
    explicit = test not in ('gbsa', 'amoebagk')
    amoeba = test in ('amoebagk', 'amoebapme')
    amber = test.startswith('amber')
    temperature = 300*unit.kelvin
    friction = (1 if explicit else 91)*(1/unit.picoseconds)
    if amoeba:
        dt = 0.002*unit.picoseconds
        integ = mm.MTSLangevinIntegrator(temperature, friction, dt, [(0, 2), (1, 1)])
    else:
        dt = 0.004*unit.picoseconds
        integ = mm.LangevinMiddleIntegrator(temperature, friction, dt)
    test_result['timestep_in_fs'] = dt.value_in_unit(unit.femtoseconds)
    platform = mm.Platform.getPlatform(platform_name)
    properties = {'Precision': precision} if 'Precision' in platform.getPropertyNames() else {}
    integ.setConstraintTolerance(1e-5)
    if properties:
        context = mm.Context(system, integ, platform, properties)
    else:
        context = mm.Context(system, integ, platform)
    platform = context.getPlatform()
    test_result['platform'] = platform.getName()
    test_result['platform_properties'] = {name: platform.getPropertyValue(context, name)
                                          for name in platform.getPropertyNames()}
    context.setPositions(positions)
    if amber:
        mm.LocalEnergyMinimizer.minimize(context, 100*unit.kilojoules_per_mole/unit.nanometer)
    return context, integ, test_result, temperature


def timed_run(bench, context, integ, test_result, seconds, unit):
    """benchmark.py's timing loop, unchanged: it calibrates from 20 steps, times the last call only."""
    steps = 20
    while True:
        elapsed_time = bench['timeIntegration'](context, steps, INITIAL_STEPS)
        if elapsed_time >= 0.5*seconds:
            break
        if elapsed_time < 0.5:
            steps = int(steps*1.0/elapsed_time)
        else:
            steps = int(steps*seconds/elapsed_time)
    result = dict(test_result, steps=steps, elapsed_time=elapsed_time)
    time_per_step = elapsed_time*unit.seconds/steps
    result['ns_per_day'] = (integ.getStepSize()/time_per_step)/(unit.nanoseconds/unit.day)
    return result


def work(platform_name, precision, test, seconds):
    began = time.monotonic()
    # Library output goes to stderr; stdout carries only messages to the driver, one JSON line each.
    channel = os.fdopen(os.dup(1), 'w', buffering=1)
    os.dup2(2, 1)
    os.chdir(BENCH)
    import openmm as mm
    import openmm.unit as unit
    import platform
    import socket
    from datetime import datetime, timezone
    # benchmark.py forces these precisions for Reference and CPU whatever --precision says.
    precision = {'Reference': 'double', 'CPU': 'mixed'}.get(platform_name, precision)
    bench = benchmark_functions()
    try:
        context, integ, test_result, temperature = setup(bench, mm, unit, platform_name, precision, test)
    except mm.OpenMMException as e:
        channel.write(json.dumps({'error': str(e).splitlines()[0]}) + '\n')
        return
    start = context.getState(positions=True).getPositions()
    system_info = {'hostname': socket.gethostname(), 'timestamp': '', 'openmm_version': mm.version.version,
                   'cpuinfo': bench['cpuinfo'](), 'cpuarch': platform.processor(), 'system': platform.system()}
    channel.write(json.dumps(dict(ready=True, setup_seconds=time.monotonic() - began,
                                  platform_properties=test_result['platform_properties'], **memory_mb())) + '\n')
    runs = 0
    for line in sys.stdin:
        outfile = json.loads(line)['outfile']
        runs += 1
        # Every run starts where a cold run does: the post-setup positions and fresh velocities.
        context.setPositions(start)
        context.setVelocitiesToTemperature(temperature)
        try:
            result = timed_run(bench, context, integ, test_result, float(seconds), unit)
        except mm.OpenMMException as e:
            channel.write(json.dumps(dict(error=str(e).splitlines()[0], **memory_mb())) + '\n')
            continue
        system_info['timestamp'] = datetime.now(timezone.utc).isoformat()
        system_info['runner'] = f'abw.py warm worker pid {os.getpid()}, run {runs} after one setup'
        bench['appendTestResult'](outfile, system_info=system_info)
        bench['appendTestResult'](test_result=result, filename=outfile)
        bench['printTestResult'](result, types.SimpleNamespace(style='table'))
        sys.stdout.flush()
        channel.write(json.dumps(dict(done=True, **memory_mb())) + '\n')


if __name__ == '__main__':
    sys.stdout.reconfigure(line_buffering=True)
    if sys.argv[1:2] == ['worker']:
        work(*sys.argv[2:])
    else:
        drive()
