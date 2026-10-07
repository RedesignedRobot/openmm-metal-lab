#!/usr/bin/env python3
"""m029 campaign driver and CPU-only summary; no OpenMM imports in this process.

window-m029.sh [--dry-run | --run | --prepare] [--any-hour]
              [--out PATH] [--stack3-commit SHA] [--stack4-commit SHA]
              [--pme-base-commit SHA] [--reorder-diag-commit SHA]
python window-m029-summary.py OUTDIR   # regenerate the one campaign summary
"""
import argparse
import bz2
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import statistics as stats
import subprocess as sp
import sys
import time
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
BENCH = Path('/tmp/openmm-metal-bench')
TOOLS = BENCH / 'ultra-tools'
CODE = Path('~/code/metal/openmm-metal')
REPORTS = Path('~/.cdx/reports')
ROUND3 = Path('~/code/metal/lab/experiments/029-2x-moonshots/ROUND3.md')
HERE = Path(__file__).absolute()
PY = BENCH / 'env/bin/python3'
HOLDOUT = BENCH / 'holdout'
FLAGS = ('OPENMM_METAL_FOLD_ORDERED_FORCES', 'OPENMM_METAL_DEFER_BAROSTAT_ENERGIES',
         'OPENMM_METAL_PME_OWNER', 'OPENMM_METAL_DEVICE_BOX', 'OPENMM_METAL_DEVICE_BAROSTAT',
         'OPENMM_METAL_COOP_SHAKE')
# STATE.md:123, :30-32, :57: candidate, replaced trunk, window OpenCL arm.
# OpenCL commit is ultra-day-trial3/BUILT, built 2026-09-28T15:19:07Z.
# Scatter source: reports/m029-scatter-fold-r1.md "Ready-to-run experiment",
# r2.md and STATE.md:24. Syntax-only repair a156b7603 is the baseline's child.
# Barostat source: reports/m029-baro-defer-r1.md:138-161, STATE.md:23.
# PME source: reports/m029-pme-owner-r1.md "Kill command", STATE.md:106.
ARMS = {
    'candidate': ('ultra-m029-candidate-1', 'a4dd1eab9', None),
    'trunk': ('ultra-integrated', '734ce92d5', None),
    'opencl': ('ultra-day-trial3', '5d617bfc3', None),
    'scatter-base': ('ultra-m029-scatter-base', 'ecf4284db', 'a156b7603'),
    'fold': ('ultra-m029-window-fold', '516c1ef62', None),
    'baro-base': ('ultra-m029-baro-base', 'd670532ac', '805408bd7'),
    'defer': ('ultra-m029-baro-defer', 'c0365efdc', None),
    'owner': ('ultra-m029-window-owner', '942813b06', None),
    'stack3': ('ultra-m029-window-stack3', None, None),
    'pme-base': ('ultra-m029-window-pme-energy-base', None, None),
    'stack4': ('ultra-m029-window-stack4', None, None),
    'reorder-diag': ('ultra-m029-window-reorder-diag', None, None),
}
NEW_SCREENS = ('pme-energy-only', 'coop-shake')
FAH_UNITS = ('tip4pew', 'tip3p-hmr')
COMMIT_INPUTS = {'stack3': 'head-reviewed stack3', 'stack4': 'head-reviewed final stack4',
                 'pme-base': 'lane/m029-pme-base5 9925fa322 (stack5 without PME energy-only)',
                 'reorder-diag': 'lane/m029-reorder-diag5 35930334d (adaptive reorder diagnostic on stack5)'}
FIXED_COMMITS = {'pme-base': '9925fa322', 'reorder-diag': '35930334d'}
FAH_MAPS = {
    ('fah-map' if pme == det == 'true' else f'fah-pme-{pme}-det-{det}') + '-ocl-' + precision:
        (pme, det, precision)
    for pme in ('false', 'true') for det in ('false', 'true') for precision in ('single', 'mixed')
}
PROPERTY_SCREENS = tuple(FAH_MAPS) + ('reorder-cost', 'fah-owner')
# Explicit settings for the new final-stack arms only. Existing default arms retain their flags.
FINAL_SETTINGS = {FLAGS[2]: None, FLAGS[3]: '1', FLAGS[4]: '1', FLAGS[5]: '0'}


def commit_input(args, name):
    return getattr(args, name.replace('-', '_') + '_commit')

# Thresholds are copied, not inferred from the performance model.
# reports/m029-scatter-fold-kill.py: >=5 us saved AND >=1% throughput.
# reports/m029-baro-defer-r1.md:161: kill below 1% throughput.
# reports/m029-pme-owner-r1.md:45: combined GPU replay >40 us is DEAD.
# Device barostat: head's cdx question reply, 2026-10-03, recorded in ROUND3.md
# "m029 campaign": <1% tip4pew mixed is KILL, provisional. Same stack3 on/off.
# Model: reports/m029-tip4pew-next-r1.md item 2, 15-18 us net, phase 1 ~8 us.
# Mission: ROUND3.md:21, mixed/OpenCL single >=2. No cross-build projections.
RULES = {'mission': 'mixed/OpenCL single >=2x',
         'holdout': 'holdout.sh verdict: >1% regression with spread <1.5% blocks; forces must pass',
         'scatter-check': 'TestMetalOrderedForceFold Single and Mixed must pass',
         'scatter': 'mean saving >=5 us/step AND mean throughput gain >=1%',
         'baro': 'paired median throughput gain >=1%',
         'owner': 'combined spline-free GPU replay <=40 us; provisional lower bound only',
         'device': 'paired median throughput gain >=1%; provisional',
         'pme-energy-only': 'paired median saving >=3 us/step; provisional',
         'coop-shake': 'paired median throughput gain >=1.0%; provisional',
         'fah-owner': 'FAH map: full-path owner on / off on stack4; raw ratio and spread, confirm required',
         'reorder-cost': 'FAH map: adaptive-reorder diagnostic / stack4 throughput; raw ratio and spread, no kill bar'}
RULES.update({name: ('Metal mixed / OpenCL single >=2x; explicit maps' if values[2] == 'single'
                     else 'Metal mixed / OpenCL mixed production comparison; no 2x verdict')
              for name, values in FAH_MAPS.items()})


def capture(cmd):
    return sp.check_output(list(map(str, cmd)), text=True, stderr=sp.PIPE).strip()


def atomic(path, data):
    path = Path(path)
    path.with_suffix(path.suffix + '.tmp').write_text(data)
    path.with_suffix(path.suffix + '.tmp').replace(path)


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def arm(name):
    return BENCH / ARMS[name][0]


def holdout_module(path=None):
    spec = importlib.util.spec_from_file_location('m029_holdout', path or TOOLS / 'holdout.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def hazards(any_hour=False, idle=False, builders=False):
    errors = []
    if (BENCH / 'GPU-EMBARGO').exists():
        errors.append(str(BENCH / 'GPU-EMBARGO'))
    # Executable names only, never print process arguments or environment secrets.
    for line in capture(['ps', '-axo', 'pid=,comm=']).splitlines():
        if re.search(r'blender|remotion|ffmpeg|headless|ms-playwright|chrome for testing|chromium|davinci|unreal', line, re.I):
            errors.append('GPU process ' + line.strip())
    if not any_hour and dt.datetime.now(dt.timezone.utc).hour >= 7:
        errors.append('outside 00:00-07:00 UTC (owner release requires --any-hour)')
    if idle or builders:
        for line in capture(['ps', '-axo', 'stat=,ucomm=']).splitlines():
            parts = line.split()
            if len(parts) == 2 and not parts[0].startswith('T') and parts[1] in ('clang', 'clang++', 'ninja', 'cc1plus'):
                errors.append('BUILD RUNNING: ' + parts[1])
    if idle:
        # Same foreign-GPU threshold as ab-test.sh, before our own GPU work only.
        values = re.findall(r'"Device Utilization %"\s*=\s*(\d+)', capture(['ioreg', '-r', '-d', '1', '-c', 'IOAccelerator']))
        if not values:
            errors.append('GPU utilization unavailable from ioreg')
        elif max(map(int, values)) > 5:
            errors.append('foreign GPU utilization >5% (ab-test.sh)')
        if os.getloadavg()[0] >= 3:
            errors.append('host load >=3 (window.sh dedicated-window convention)')
    return errors


def guard(any_hour=False, idle=False, builders=False):
    errors = hazards(any_hour, idle, builders)
    if errors:
        raise RuntimeError('STOP: ' + '; '.join(errors))


def clean_env(extra=None):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('OPENMM_METAL_') and k not in ('PYTHONPATH', 'OPENMM_CPU_THREADS', 'GPUQ_PREFLIGHT',
               'OPENMM_PLUGIN_DIR', 'DYLD_LIBRARY_PATH', 'DYLD_FALLBACK_LIBRARY_PATH')}
    env.update(OPENMM_METAL_PME_OWNER='0', OPENMM_METAL_DEVICE_BOX='0', OPENMM_METAL_DEVICE_BAROSTAT='0',
               OPENMM_METAL_COOP_SHAKE='0')
    env['PATH'] = str(BENCH / 'env/bin') + ':' + env.get('PATH', '')
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    env.update(extra or {})
    return {key: value for key, value in env.items() if value is not None}


def environment_command(settings):
    return ['env'] + [part for key, value in settings.items() if value is None for part in ('-u', key)] + [
        f'{key}={value}' for key, value in settings.items() if value is not None]


def monitored(cmd, log, any_hour, env=None, stdin=None, allowed=(0,), allow_build=False):
    """Abort only our recorded process group if renders/embargo/night boundary return."""
    guard(any_hour, builders=not allow_build)
    with open(log, 'w') as output:
        proc = sp.Popen(list(map(str, cmd)), stdin=stdin, stdout=output, stderr=sp.STDOUT,
                        env=env or clean_env(), start_new_session=True)
        try:
            while proc.poll() is None:
                guard(any_hour, builders=not allow_build)
                time.sleep(1)
            guard(any_hour, builders=not allow_build)
            if proc.returncode not in allowed:
                raise RuntimeError(f'command exited {proc.returncode}: {log}')
            return proc.returncode
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except sp.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()


def clock_running():
    path = BENCH / 'ultra-lead/gpuclock.pid'
    try:
        pid = int(path.read_text().strip())
        return 'gpuclock.py' in capture(['ps', '-p', str(pid), '-o', 'command='])
    except (OSError, ValueError, sp.CalledProcessError):
        return False


def ensure_clock(any_hour):
    guard(any_hour)
    if not clock_running():
        (BENCH / 'ultra-lead/gpuclock.stop').unlink(missing_ok=True)
        sp.run([str(TOOLS / 'bg.sh'), str(BENCH / 'ultra-lead/gpuclock.out'), str(PY), str(TOOLS / 'gpuclock.py')], check=True)
    for _ in range(15):
        guard(any_hour)
        log = BENCH / 'ultra-lead/gpuclock.log'
        if clock_running() and log.exists() and time.time() - log.stat().st_mtime < 10:
            return
        time.sleep(1)
    raise RuntimeError('gpuclock has no fresh samples; see ultra-lead/gpuclock.out')


def build_check(name, sha):
    tree = arm(name)
    required = [tree / 'BUILT', tree / 'src/.commit', tree / 'venv/bin/python',
                tree / 'build/libOpenMM.dylib', tree / 'prefix/lib/libOpenMM.dylib',
                tree / 'prefix/lib/plugins/libOpenMMMetal.dylib', tree / 'prefix/lib/plugins/libOpenMMOpenCL.dylib']
    for path in required:
        if not path.exists():
            raise RuntimeError(f'missing {path}')
    if not os.access(tree / 'venv/bin/python', os.X_OK):
        raise RuntimeError(f'not executable: {tree}/venv/bin/python')
    built = dict(line.split(' ', 1) for line in (tree / 'BUILT').read_text().splitlines())
    if not sha or not built['commit'].startswith(sha) or (tree / 'src/.commit').read_text().strip() != built['commit']:
        raise RuntimeError(f'{tree}/BUILT commit {built["commit"]} != recorded {sha}')
    if capture([TOOLS / 'srchash.sh', tree]) != built['src']:
        raise RuntimeError(f'{tree}/src differs from BUILT')
    sp.run([str(PY), str(TOOLS / 'check-pin.py'), str(tree)], check=True, stdout=sp.DEVNULL)
    libraries = sorted((tree / 'build').rglob('libOpenMM*.dylib')) + sorted((tree / 'prefix').rglob('libOpenMM*.dylib'))
    if not any(p.name == 'libOpenMMMetal.dylib' for p in libraries):
        raise RuntimeError(f'missing {tree}/build/**/libOpenMMMetal.dylib')
    return {'built': built, 'libraries': {str(p): digest(p) for p in libraries}}


def fah_barostat(unit):
    """Read the frozen XML without importing OpenMM or changing its settings."""
    path = HOLDOUT / ('fah-' + unit) / 'system.xml.bz2'
    root = ET.fromstring(bz2.decompress(path.read_bytes()))
    barostats = [f for f in root.findall('./Forces/Force') if 'Barostat' in f.get('type', '')]
    if len(barostats) != 1 or barostats[0].get('frequency') != '25':
        raise ValueError(f'{path}: FAH screen requires one barostat with frequency 25')


def preflight(args):
    errors, identities = [], {}
    required = [TOOLS / n for n in ('gpuclock.py', 'bg.sh', 'ab.sh', 'ab-test.sh', 'holdout.sh', 'holdout.py',
                'lease.sh', 'gpuq/gpuq', 'build.sh', 'sync.sh', 'sync.py', 'srchash.sh', 'check-pin.py', 'forces.py')]
    required += [PY, CODE, ROUND3, REPORTS / 'm029-scatter-fold-kill.py',
                 REPORTS / 'm029-scatter-fold-r1.md', REPORTS / 'm029-baro-defer-r1.md',
                 REPORTS / 'm029-pme-owner-r1.md', REPORTS / 'm029-tip4pew-next-r1.md',
                 REPORTS / 'm029-tip4pew-next2-r1.md']
    for path in required:
        if not path.exists():
            errors.append('missing ' + str(path))
        elif (path.suffix == '.sh' or path in (PY, TOOLS / 'gpuq/gpuq')) and not os.access(path, os.X_OK):
            errors.append('not executable: ' + str(path))
    canonical_worker = HERE.with_name('holdout.py')
    if not (TOOLS / 'holdout.py').exists() or digest(TOOLS / 'holdout.py') != digest(canonical_worker):
        errors.append('head must install canonical lab holdout.py into ultra-tools before running')
    identities['tools'] = {str(p): digest(p) for p in required if p.is_file()}
    for binary in ('git', 'tar', 'ps', 'ioreg', 'ctest'):
        if not shutil.which(binary, path=clean_env()['PATH']):
            errors.append('missing binary ' + binary)
    for name, (_, sha, _) in ARMS.items():
        if name in COMMIT_INPUTS:
            sha = commit_input(args, name)
            if not sha:
                errors.append(f'pending {name}: head must supply --{name}-commit')
        try:
            identities[name] = build_check(name, sha)
            print(f'OK build {name}: {arm(name)} {identities[name]["built"]["commit"]}')
        except (RuntimeError, OSError, sp.CalledProcessError, KeyError) as exc:
            errors.append((f'pending {name}: ' if name in COMMIT_INPUTS else '') + str(exc))
    if not args.stack4_commit:
        for screen in NEW_SCREENS + ('fah-owner',):
            errors.append(f'pending {screen} ({", ".join(FAH_UNITS)} mixed): --stack4-commit required')
    for unit in FAH_UNITS:
        try:
            fah_barostat(unit)
        except (OSError, ValueError, ET.ParseError) as exc:
            errors.append('FAH barostat: ' + str(exc))
    for name, relative in [('fold', 'build/TestMetalOrderedForceFold'), ('owner', 'build/TestMetalPmeOwner'),
                           ('owner', 'src/platforms/metal/tests/runPmeOwnerKill.sh'),
                           ('owner', 'src/platforms/metal/tests/capturePmeOwner.py')]:
        path = arm(name) / relative
        if not path.exists():
            errors.append('missing ' + str(path))
    # Verify the frozen corpus, then prove the requested decompressed XML copies match it.
    try:
        module = holdout_module()
        identities['holdout'] = module.verify(str(HOLDOUT))
        for unit in ('tip4pew', 'tip3p-hmr'):
            for part in ('system', 'state', 'integrator'):
                xml = Path('/tmp/m029-fah-' + unit) / (part + '.xml')
                frozen = HOLDOUT / ('fah-' + unit) / (part + '.xml.bz2')
                if not xml.exists():
                    errors.append('missing ' + str(xml))
                elif xml.read_bytes() != bz2.decompress(frozen.read_bytes()):
                    errors.append(f'{xml} differs from {frozen}')
    except (OSError, ValueError, SystemExit) as exc:
        errors.append('holdout corpus: ' + str(exc))
    # Check the literal threshold evidence, without executing the historical harness.
    for name, token in [('m029-scatter-fold-kill.py', 'saving >= 5 and gain >= 1'),
                        ('m029-baro-defer-r1.md', 'ratio >= 1.01'),
                        ('m029-pme-owner-r1.md', 'over 40 us')]:
        path = REPORTS / name
        if not path.exists() or token not in path.read_text():
            errors.append(f'missing threshold evidence {path}: {token}')
    if not ROUND3.exists() or 'Device box plus device barostat: kill below 1.0%' not in ROUND3.read_text():
        errors.append(f'missing device kill threshold evidence: {ROUND3}')
    for error in errors:
        print('INPUT ' + error)
    return errors, identities


def steps():
    return ['mission-tip4pew', 'mission-tip3p-hmr', 'holdout', 'scatter-check', 'scatter', 'baro', 'owner', 'device'] + [
        f'{screen}-{unit}' for screen in NEW_SCREENS + PROPERTY_SCREENS for unit in FAH_UNITS]


def screen_name(step):
    return next((screen for screen in ('mission',) + NEW_SCREENS + PROPERTY_SCREENS if step.startswith(screen + '-')), step)


def unit_name(step):
    screen = screen_name(step)
    return step[len(screen) + 1:] if screen in ('mission',) + NEW_SCREENS + PROPERTY_SCREENS else 'tip4pew'


def configurations(step):
    if step.startswith('mission-'):
        return [('candidate', 'Metal', 'mixed', {}), ('opencl', 'OpenCL', 'single', {})]
    screen = screen_name(step)
    if screen in FAH_MAPS:
        return [('stack4', 'Metal', 'mixed', FINAL_SETTINGS),
                ('opencl', 'OpenCL', FAH_MAPS[screen][2], {})]
    if screen == 'reorder-cost':
        return [('stack4', 'Metal', 'mixed', FINAL_SETTINGS),
                ('reorder-diag', 'Metal', 'mixed', FINAL_SETTINGS)]
    if screen == 'fah-owner':
        return [('stack4', 'Metal', 'mixed', dict(FINAL_SETTINGS, OPENMM_METAL_PME_OWNER=value))
                for value in ('0', '1')]
    if screen in NEW_SCREENS:
        settings = {FLAGS[3]: '1', FLAGS[4]: '1', FLAGS[5]: '0'}
        if screen == 'pme-energy-only':
            return [('pme-base', 'Metal', 'mixed', settings), ('stack4', 'Metal', 'mixed', settings)]
        return [('stack4', 'Metal', 'mixed', settings), ('stack4', 'Metal', 'mixed', dict(settings, OPENMM_METAL_COOP_SHAKE='1'))]
    return {
        'scatter': [('scatter-base', 'Metal', 'mixed', {}), ('fold', 'Metal', 'mixed', {FLAGS[0]: '1'})],
        'baro': [('baro-base', 'Metal', 'mixed', {FLAGS[1]: '0'}), ('defer', 'Metal', 'mixed', {FLAGS[1]: '1'})],
        'device': [('stack3', 'Metal', 'mixed', {FLAGS[3]: '0', FLAGS[4]: '0'}),
                   ('stack3', 'Metal', 'mixed', {FLAGS[3]: '1', FLAGS[4]: '1'})],
    }[step]


def context_properties(step, platform, precision):
    props = {'Precision': precision}
    screen = screen_name(step)
    if screen in PROPERTY_SCREENS:
        props.update(DeviceIndex='0', DisablePmeStream='true')
        if platform == 'Metal':
            pme, det = FAH_MAPS[screen][:2] if screen in FAH_MAPS else ('true', 'true')
            props.update(DisablePmeStream=pme, DeterministicForces=det)
    return props


def worker_command(step, config):
    name, platform, precision, _ = config
    return [str(arm(name) / 'venv/bin/python'), str(TOOLS / 'holdout.py'), 'worker',
            str(HOLDOUT / ('fah-' + unit_name(step))), platform, precision, '--properties',
            json.dumps(context_properties(step, platform, precision), sort_keys=True)]


def validate_receipt(module, expected, row):
    if row.get('requested_properties') != expected:
        raise RuntimeError('FAH worker did not attest the requested property map')
    module.verify_properties(expected, row.get('effective_properties', {}))


def comparison(step, samples):
    screen = screen_name(step)
    reference = screen == 'mission' or screen in FAH_MAPS
    base, cand = (samples[1], samples[0]) if reference else samples
    ratio, spread = paired(base, cand)
    precision = 'mixed'
    verdict = 'SURVIVES screen' if ratio >= 1.01 else 'KILL'
    if reference:
        ref_precision = FAH_MAPS[screen][2] if screen in FAH_MAPS else 'single'
        precision = 'mixed/OpenCL ' + ref_precision
        verdict = ('TARGET MET' if ratio >= 2 else 'BELOW TARGET') if ref_precision == 'single' else 'production comparison'
    elif screen == 'reorder-cost':
        verdict = 'diagnostic only; no kill bar'
    elif screen == 'fah-owner':
        verdict = 'full-path comparison; confirm required'
    result = dict(arm=step, unit=unit_name(step), precision=precision,
                  ratio=ratio, spread=spread, verdict=verdict)
    if screen == 'fah-owner':
        result['saving_us'] = stats.median([b - c for b, c in zip(base, cand)])
    if step == 'scatter':
        saving = stats.mean(base) - stats.mean(cand)
        gain = stats.mean(base) / stats.mean(cand)
        result.update(ratio=gain, saving_us=saving, verdict='SURVIVES screen' if saving >= 5 and gain >= 1.01 else 'KILL')
    if screen in NEW_SCREENS:
        saving = stats.median([b - c for b, c in zip(base, cand)])
        survives = saving >= 3 if screen == 'pme-energy-only' else ratio >= 1.01
        result.update(saving_us=saving, verdict='KEEP screen' if survives else 'KILL')
    return result


def attempt(path):
    numbers = [int(p.name.split('-')[-1]) for p in path.glob('attempt-*') if p.name.split('-')[-1].isdigit()]
    return path / f'attempt-{max(numbers, default=0) + 1:03d}'


def paired(base, cand):
    values = [b / c for b, c in zip(base, cand)]
    if not values or any(not math.isfinite(v) or v <= 0 for v in base + cand):
        raise ValueError('missing or non-finite samples')
    return stats.median(values), max(values) - min(values)


def completed(path):
    marker = path / 'done.json'
    if not marker.exists():
        return None
    record = json.loads(marker.read_text())
    for filename, expected in record['evidence'].items():
        if digest(path / filename) != expected:
            raise RuntimeError(f'resume evidence changed: {path / filename}')
        if Path(filename).name == 'done.json':
            completed((path / filename).parent)
    return record['result']


def finish(path, result, evidence):
    atomic(path / 'done.json', json.dumps({'result': result, 'evidence': {
        str(p.relative_to(path)): digest(p) for p in evidence}}, indent=2) + '\n')


def sample(step, index, output, seconds, any_hour):
    name, platform, precision, settings = configurations(step)[index]
    unit = unit_name(step)
    if screen_name(step) in NEW_SCREENS:
        fah_barostat(unit)
    # Head-approved substitution: ab.sh/ab-test.sh only support benchmark.py.
    # Use the existing holdout worker with the identical frozen FAH XML instead.
    module = holdout_module()
    (output / 'workers').mkdir(parents=True, exist_ok=True)
    if not os.environ.get('GPUQ_JOB') or not os.environ.get('OPENMM_LEASE_PID'):
        raise RuntimeError('FAH sample requires a gpuq hold')
    old = os.environ.copy()
    environment = clean_env(settings)
    os.environ.clear()
    os.environ.update(environment)
    worker = None
    try:
        guard(any_hour)
        worker = module.Worker(str(output), str(arm(name) / 'venv/bin/python'),
                               str(HOLDOUT / ('fah-' + unit)), name, platform, precision,
                               properties=context_properties(step, platform, precision))
        ready = worker.read()
        if not ready or not ready.get('ready'):
            if (platform == 'OpenCL' and precision == 'mixed' and screen_name(step) in FAH_MAPS
                    and ready and ready.get('failure') == 'context_creation_failed'):
                worker.process.wait(timeout=5)
                atomic(output / 'result.json', json.dumps(dict(ready, status='failed', arm=name,
                       platform=platform, precision=precision, unit=unit,
                       stderr_log=str(Path(worker.log_path).relative_to(output)))) + '\n')
                return
            raise RuntimeError('FAH worker failed to load')
        expected = context_properties(step, platform, precision)
        validate_receipt(module, expected, ready)
        guard(any_hour)
        warm = worker.send('warm')
        if not warm or not math.isfinite(warm['warm_us']) or warm['warm_us'] <= 0:
            raise RuntimeError('FAH warmup failed')
        guard(any_hour)
        row = worker.send(f'time {max(1, int(seconds * 1e6 / warm["warm_us"]))}')
        guard(any_hour)
        if not row or row['steps'] <= 0 or not math.isfinite(row['seconds']) or row['seconds'] <= 0:
            raise RuntimeError('FAH worker returned no valid timing')
        validate_receipt(module, expected, row)
        if screen_name(step) == 'reorder-cost':
            # Head confirmed both pinned builds have C++ members only, no public Python interface.
            row['diagnostics'] = dict(reorder_count=None, tile_count=None, status='unavailable',
                                      reason='build exposes no public reorder/tile counter interface')
        atomic(output / 'result.json', json.dumps(dict(row, us_per_step=1e6 * row['seconds'] / row['steps'],
               arm=name, platform=platform, precision=precision, unit=unit, forces=ready,
               environment_settings=settings)) + '\n')
    finally:
        if worker and worker.process.poll() is None:
            worker.process.terminate()
            try:
                worker.process.wait(timeout=5)
            except sp.TimeoutExpired:
                worker.process.kill()
                worker.process.wait()
        os.environ.clear()
        os.environ.update(old)


def execute_step(step, path, args):
    guard(args.any_hour, idle=True)
    # The scheduler may have waited: validate again under its hold, before GPU work.
    identity = json.loads((args.out / 'campaign.json').read_text())
    if identity['driver'] != digest(HERE):
        raise RuntimeError('driver changed while queued')
    for name, value in identity['arms'].items():
        if name in ARMS and build_check(name, value['built']['commit']) != value:
            raise RuntimeError(f'build changed while queued: {name}')
    for filename, expected in identity['arms']['tools'].items():
        if digest(filename) != expected:
            raise RuntimeError(f'tool changed while queued: {filename}')
    if holdout_module().verify(str(HOLDOUT)) != identity['arms']['holdout']:
        raise RuntimeError('holdout changed while queued')
    ensure_clock(args.any_hour)
    if completed(path):
        return
    path.mkdir(parents=True, exist_ok=True)
    if step in ('holdout', 'scatter-check', 'owner'):
        out = attempt(path)
        out.mkdir()
        if step == 'holdout':
            cmd = [TOOLS / 'holdout.sh', arm('trunk'), arm('candidate'), out / 'data']
        elif step == 'scatter-check':
            cmd = [BENCH / 'env/bin/ctest', '--test-dir', arm('fold') / 'build', '--output-on-failure',
                   '--no-tests=error', '-R', '^TestMetalOrderedForceFold(Single|Mixed)$']
        else:
            cmd = [arm('owner') / 'src/platforms/metal/tests/runPmeOwnerKill.sh',
                   arm('owner') / 'build/TestMetalPmeOwner', HOLDOUT / 'fah-tip4pew', out / 'capture.txt']
        log = out / 'run.log'
        code = monitored(cmd, log, args.any_hour, clean_env({FLAGS[2]: '1'} if step == 'owner' else {}),
                         allowed=(0, 2) if step == 'owner' else (0,))
        evidence = [log]
        result = {'arm': step, 'unit': 'tip4pew', 'precision': 'mixed', 'ratio': None, 'spread': None}
        if step == 'owner':
            match = re.search(r'combined=([\d.]+) threshold=40\.000', log.read_text())
            if not match or code != (2 if float(match[1]) > 40 else 0):
                raise RuntimeError('PME replay has no consistent measured verdict')
            result.update(verdict='KILL' if code == 2 else 'SURVIVES lower bound', gpu_us=float(match[1]))
        elif step == 'holdout':
            data = out / 'data'
            runs = [json.loads(s) for s in (data / 'results.jsonl').read_text().splitlines()]
            module = holdout_module()
            expected = {(item, r, tree, platform, precision)
                        for item, precisions in module.ITEMS for r in (1, 2, 3) for tree in ('base', 'cand')
                        for platform, precision in [('Metal', p) for p in precisions] + [('OpenCL', 'single')]}
            keys = [(r['item'], r['round'], r['tree'], r['platform'], r['precision']) for r in runs]
            if len(keys) != len(expected) or set(keys) != expected or any(not math.isfinite(r['us_per_step']) or r['us_per_step'] <= 0 for r in runs):
                raise RuntimeError('holdout incomplete; retry in a fresh attempt directory')
            text = (data / 'summary.txt').read_text()
            result.update(unit='all frozen items', verdict='PASS' if 'verdict: pass on timing (0 rows), ok on forces (0 rows)' in text else 'BLOCK',
                          summary=str(data / 'summary.txt'), data=str(data))
            evidence += [data / n for n in ('results.jsonl', 'forces.jsonl', 'summary.txt')]
        else:
            result.update(verdict='PASS', precision='single,mixed')
        finish(path, result, evidence)
        return
    mission = step.startswith('mission-') or screen_name(step) in PROPERTY_SCREENS
    rounds, seconds = (3, 30) if mission else (2, 15)
    samples = [[], []]
    evidence = []
    for r in range(1, rounds + 1):
        pair = path / f'round-{r}'
        done = completed(pair)
        if done is None:
            pair.mkdir(exist_ok=True)
            out = attempt(pair)
            out.mkdir()
            # Restart the entire interrupted pair; never pair different attempts.
            for i in ([0, 1] if r % 2 else [1, 0]):
                target = out / str(i)
                target.mkdir()
                cmd = [PY, HERE, 'sample', step, str(i), target, str(seconds)]
                if args.any_hour:
                    cmd.append('--any-hour')
                monitored(cmd, target / 'run.log', args.any_hour)
            done = [json.loads((out / str(i) / 'result.json').read_text()) for i in (0, 1)]
            receipts = [out / str(i) / 'result.json' for i in (0, 1)]
            receipts += [out / str(i) / row['stderr_log'] for i, row in enumerate(done) if row.get('status') == 'failed']
            finish(pair, done, receipts)
        evidence.append(pair / 'done.json')
        if any(row.get('status') == 'failed' for row in done):
            finish(path, dict(arm=step, unit=unit_name(step), precision='mixed/OpenCL mixed',
                   ratio=None, spread=None, verdict='FAILED OpenCL mixed context creation; see round receipts'), evidence)
            return
        for i in (0, 1):
            samples[i].append(done[i]['us_per_step'])
    result = comparison(step, samples)
    finish(path, result, evidence)


def summary(out):
    lines = ['m029 campaign: host-clock timing; paired ratio median, spread = max minus min.',
             'Scatter verdict uses mean us/step as recorded. PME replay uses GPU timestamps.',
             'New screens: PME paired median saving >=3 us/step; SHAKE paired median gain >=1.0%.',
             'Spread is reported as for existing screens; it adds no separate kill threshold.',
             'FAH rows use DeviceIndex=0; OpenCL disables PME stream and has no DeterministicForces property.',
             'FAH Metal rows name the boolean map; fah-map means both true. OpenCL mixed has no 2x verdict.',
             'Reorder ratio is diagnostic / stack4 throughput under the FAH map; no kill bar.',
             'FAH owner ratio is owner on / off on stack4, with the full PME path inside each timed step.',
             'The 40 us spline-free replay is preliminary and does not accept the full-path owner arm.',
             'No kill screen is a keep-rule confirm. No ratios are multiplied across builds.', '',
             '| arm | unit | precision | ratio / baseline | spread | kill / target verdict | vs 2x OpenCL |',
             '|---|---|---|---:|---:|---|---|']
    attachments = []
    for step in steps():
        result = completed(out / step)
        if not result:
            lines.append(f'| {step} | pending | | | | pending | unmeasured |')
            continue
        ratio = f'{result["ratio"]:.4f}' if result['ratio'] is not None else 'n/a'
        spread = f'{100 * result["spread"]:.2f} pp' if result['spread'] is not None else 'n/a'
        screen = screen_name(step)
        target = step.startswith('mission-') or (screen in FAH_MAPS and FAH_MAPS[screen][2] == 'single')
        mission = ('MET' if result['ratio'] >= 2 else 'BELOW') if target else 'unmeasured for this arm'
        if screen in FAH_MAPS and FAH_MAPS[screen][2] == 'mixed':
            mission = 'n/a: production precision, not the historical target'
        if screen == 'reorder-cost':
            mission = 'n/a: diagnostic'
        baseline = {'scatter': 'ecf4284db', 'baro': 'd670532ac', 'device': 'stack3 flags off',
                    'pme-energy-only': 'pme-base 9925fa322 (stack5 without energy-only), SHAKE off',
                    'reorder-cost': 'stack4 FAH map', 'fah-owner': 'stack4 FAH map owner off',
                    'coop-shake': 'stack4 SHAKE off'}.get(screen_name(step), 'OpenCL single')
        if screen in FAH_MAPS:
            baseline = 'OpenCL ' + FAH_MAPS[screen][2] + ' FAH map'
        if result['ratio'] is not None:
            ratio += ' / ' + baseline
        extra = f' ({result["gpu_us"]:.3f} us)' if 'gpu_us' in result else ''
        if screen_name(step) in NEW_SCREENS + ('fah-owner',):
            extra += f' ({result["saving_us"]:.3f} us/step saved)'
        lines.append(f'| {step} | {result["unit"]} | {result["precision"]} | {ratio} | {spread} | {result["verdict"]}{extra} | {mission} |')
        if step == 'holdout':
            attachments += ['', 'Holdout details (candidate vs 734ce92d5):', Path(result['summary']).read_text()]
    return '\n'.join(lines + attachments) + '\n'


def prepare(args):
    guard(args.any_hour)
    # Only immutable exports inside this campaign, never worktree checkout changes.
    for name, (_, recorded, patch) in ARMS.items():
        if name in ('trunk', 'opencl'):
            continue
        sha = commit_input(args, name) if name in COMMIT_INPUTS else recorded
        if not sha:
            print(f'pending {name}: head must supply --{name}-commit after merging')
            continue
        try:
            build_check(name, sha)
            continue
        except (RuntimeError, OSError, sp.CalledProcessError, KeyError):
            pass
        if arm(name).exists():
            raise RuntimeError(f'refuse to overwrite existing invalid build {arm(name)}; head must relocate it')
        full = capture(['git', '-C', CODE, 'rev-parse', sha + '^{commit}'])
        snapshot = args.out / 'prepare' / name
        snapshot.mkdir(parents=True, exist_ok=True)
        archive = snapshot / 'source.tar'
        with archive.open('wb') as f:
            sp.run(['git', '-C', str(CODE), 'archive', full], stdout=f, check=True)
        source = snapshot / 'source'
        source.mkdir(exist_ok=True)
        sp.run(['tar', '-xf', str(archive), '-C', str(source)], check=True)
        if patch:
            repair = sp.check_output(['git', '-C', str(CODE), 'diff', patch + '^', patch, '--',
                                    'platforms/metal/include/MetalContext.h', 'platforms/metal/src/MetalContext.cpp'])
            sp.run(['git', 'apply', '-'], input=repair, cwd=source, check=True)
        (source / '.commit').write_text(full + '\n')
        guard(args.any_hour)
        sp.run([str(TOOLS / 'sync.sh'), str(source), str(arm(name))], check=True)
        monitored([TOOLS / 'build.sh', arm(name)], snapshot / 'build.log', args.any_hour, allow_build=True)
    for name in COMMIT_INPUTS:
        sha = commit_input(args, name)
        if sha:
            atomic(args.out / (name + '.commit'), sha + '\n')


def campaign(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--dry-run', action='store_true')
    modes.add_argument('--run', action='store_true')
    modes.add_argument('--prepare', action='store_true')
    parser.add_argument('--any-hour', action='store_true')
    parser.add_argument('--out', type=Path, default=BENCH / 'ultra-lead/m029-window')
    for name, description in COMMIT_INPUTS.items():
        parser.add_argument('--' + name + '-commit', help=description)
    parser.add_argument('--step', choices=steps(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    args.out = args.out.absolute()
    for name in COMMIT_INPUTS:
        sha = commit_input(args, name)
        if not sha and (args.out / (name + '.commit')).exists():
            sha = (args.out / (name + '.commit')).read_text().strip()
        if sha and not re.fullmatch('[0-9a-f]{9,40}', sha):
            parser.error(f'--{name}-commit must be the head-reviewed merged commit SHA')
        if sha and name in FIXED_COMMITS and not sha.startswith(FIXED_COMMITS[name]):
            parser.error(f'--{name}-commit must identify {COMMIT_INPUTS[name]}')
        setattr(args, name.replace('-', '_') + '_commit', sha)
    if args.step:
        if not os.environ.get('GPUQ_JOB') or not os.environ.get('OPENMM_LEASE_PID'):
            raise RuntimeError('internal step requires a gpuq hold')
        execute_step(args.step, args.out / args.step, args)
        return
    print('m029: dry-run is read-only; --run executes; --prepare builds missing arms only.')
    print('Environment: clear inherited OPENMM_METAL_*; default PME_OWNER=0, DEVICE_BOX=0, DEVICE_BAROSTAT=0, COOP_SHAKE=0; per-arm overrides below.')
    errors, identities = preflight(args)
    for error in hazards(args.any_hour, idle=True):
        print('RUN BLOCKED: ' + error)
    print('gpuclock: ' + ('running' if clock_running() else 'stopped; --run restarts before GPU work'))
    print('clock restart: remove ultra-lead/gpuclock.stop, then ' + shlex.join(list(map(str,
          [TOOLS / 'bg.sh', BENCH / 'ultra-lead/gpuclock.out', PY, TOOLS / 'gpuclock.py']))))
    print('Preparation: ' + shlex.join([str(HERE.with_name('window-m029.sh')), '--prepare'] +
          [value for name in COMMIT_INPUTS for value in
           (['--' + name + '-commit', commit_input(args, name)] if commit_input(args, name) else [])]))
    for name, (_, sha, repair) in ARMS.items():
        if name not in ('trunk', 'opencl'):
            if name in COMMIT_INPUTS:
                print(f'  input {name}: {COMMIT_INPUTS[name]}; --{name}-commit')
            commit = sha or (commit_input(args, name) if name in COMMIT_INPUTS else None) or f'<PENDING-merged-{name}-SHA>'
            snapshot = args.out / 'prepare' / name
            print(f'  prepare {name} (only if missing): mkdir -p {snapshot}/source')
            print('    ' + shlex.join(['git', '-C', str(CODE), 'archive', commit]) + f' > {snapshot}/source.tar')
            print('    ' + shlex.join(['tar', '-xf', str(snapshot / 'source.tar'), '-C', str(snapshot / 'source')]))
            if repair:
                print('    ' + shlex.join(['git', '-C', str(CODE), 'diff', repair + '^', repair, '--',
                      'platforms/metal/include/MetalContext.h', 'platforms/metal/src/MetalContext.cpp']) +
                      f' | (cd {snapshot}/source && git apply -)')
            print('    ' + shlex.join(['git', '-C', str(CODE), 'rev-parse', commit + '^{commit}']) + f' > {snapshot}/source/.commit')
            print('    ' + shlex.join([str(TOOLS / 'sync.sh'), str(snapshot / 'source'), str(arm(name))]))
            print('    ' + shlex.join([str(TOOLS / 'build.sh'), str(arm(name))]))
    commands = []
    today = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d')
    for step in steps():
        cls = 'correctness' if step == 'scatter-check' else 'window'
        cmd = [str(TOOLS / 'gpuq/gpuq'), 'hold', '--class', cls, '--lane', 'm029-window',
               '--est', '26m' if step == 'holdout' else '5m', '--cap', '65m' if step == 'holdout' else '20m']
        if not args.any_hour:
            cmd += ['--not-before', today + 'T00:00:00Z', '--not-after', today + 'T07:00:00Z']
        cmd += ['--', str(PY), str(HERE), 'campaign', '--step', step, '--out', str(args.out)]
        if args.any_hour:
            cmd.append('--any-hour')
        commands.append(cmd)
        rule = RULES[screen_name(step)]
        print(f'\n{step}: {rule}\n  output: {args.out / step}\n  command: {shlex.join(cmd)}')
        if step == 'holdout':
            print(f'  payload: {TOOLS}/holdout.sh {arm("trunk")} {arm("candidate")} {args.out / step}/attempt-NNN/data')
            for item, precisions in holdout_module(HERE.with_name('holdout.py')).ITEMS:
                for name in ('trunk', 'candidate'):
                    for platform, precision in [('Metal', p) for p in precisions] + [('OpenCL', 'single')]:
                        props = json.dumps({'Precision': precision}, sort_keys=True)
                        print('  worker: ' + shlex.join([str(arm(name) / 'venv/bin/python'),
                              str(TOOLS / 'holdout.py'), 'worker', str(HOLDOUT / item),
                              platform, precision, '--properties', props]))
        elif step == 'scatter-check':
            print(f'  payload: {BENCH}/env/bin/ctest --test-dir {arm("fold")}/build --output-on-failure --no-tests=error -R \'^TestMetalOrderedForceFold(Single|Mixed)$\'')
        elif step == 'owner':
            print(f'  payload: OPENMM_METAL_PME_OWNER=1 {arm("owner")}/src/platforms/metal/tests/runPmeOwnerKill.sh {arm("owner")}/build/TestMetalPmeOwner {HOLDOUT}/fah-tip4pew {args.out / step}/attempt-NNN/capture.txt')
        else:
            rounds, seconds = (3, 30) if step.startswith('mission-') or screen_name(step) in PROPERTY_SCREENS else (2, 15)
            print(f'  {rounds}x{seconds}s; reversed alternate rounds; fresh holdout.py worker per arm.')
            for config in configurations(step):
                name, platform, precision, settings = config
                sha = commit_input(args, name) if name in COMMIT_INPUTS else ARMS[name][1]
                print(f'  build: {name} {arm(name)} commit={sha or "PENDING --" + name + "-commit"}')
                print('  properties: ' + json.dumps(context_properties(step, platform, precision), sort_keys=True))
                print('  payload: ' + shlex.join(environment_command(settings) + worker_command(step, config)))
            if screen_name(step) in NEW_SCREENS:
                print('  FAH frozen barostat frequency=25; device box and device barostat on in both arms.')
                print('  paired order: round 1 base, candidate; round 2 candidate, base.')
            if screen_name(step) == 'reorder-cost':
                print('  reorder_count and tile_count: unavailable (no public counter interface in either build).')
            if screen_name(step) == 'fah-owner':
                print('  full-path timed step: clear, bin, splines, gather, conversion; no spline-free replay.')
                print('  paired order: round 1 off, on; round 2 on, off; round 3 off, on.')
                print('  requested and effective properties must match before timing and in each result receipt.')
            if step in ('scatter', 'baro'):
                print('  head-approved substitution for recorded ab.sh tip4pew (benchmark.py has no FAH XML test).')
    print(f'\nsummary: {PY} {HERE} {args.out}\nsummary output: {args.out}/summary.txt')
    if not args.run and not args.prepare:
        print(f'dry-run complete: {len(errors)} missing/pending input(s); no writes or GPU work.')
        return
    guard(args.any_hour)
    if args.prepare:
        args.out.mkdir(parents=True, exist_ok=True)
        prepare(args)
        return
    if errors:
        raise RuntimeError('preflight inputs unresolved; prepare builds before --run')
    if capture(['ps', '-p', str(os.getpid()), '-o', 'nice=']) != '0':
        raise RuntimeError('--run requires nice 0')
    args.out.mkdir(parents=True, exist_ok=True)
    with (args.out / '.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        identity = dict(arms=identities, driver=digest(HERE))
        manifest = args.out / 'campaign.json'
        if manifest.exists() and json.loads(manifest.read_text()) != identity:
            raise RuntimeError('campaign inputs changed; use a new --out directory')
        atomic(manifest, json.dumps(identity, indent=2) + '\n')
        try:
            for step, cmd in zip(steps(), commands):
                if completed(args.out / step):
                    continue
                guard(args.any_hour)
                # Recheck after scheduler wait inside --step; revalidate build identity too.
                for name, value in identities.items():
                    if name in ARMS and build_check(name, value['built']['commit']) != value:
                        raise RuntimeError(f'build changed: {name}')
                sp.run(cmd, env=clean_env(), check=True)
                atomic(args.out / 'summary.txt', summary(args.out))
        finally:
            atomic(args.out / 'summary.txt', summary(args.out))
            print((args.out / 'summary.txt').read_text())


if __name__ == '__main__':
    def interrupted(signum, _frame):
        raise RuntimeError(f'interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if sys.argv[1:2] == ['campaign']:
            campaign(sys.argv[2:])
        elif sys.argv[1:2] == ['sample']:
            sample(sys.argv[2], int(sys.argv[3]), Path(sys.argv[4]), int(sys.argv[5]), '--any-hour' in sys.argv[6:])
        else:
            out = Path(sys.argv[1])
            text = summary(out)
            atomic(out / 'summary.txt', text)
            print(text, end='')
    except (RuntimeError, OSError, ValueError, sp.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(2)
