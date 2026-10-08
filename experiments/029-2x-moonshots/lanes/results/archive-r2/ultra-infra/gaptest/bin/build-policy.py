"""Pauses registered bench builds for the length of a timing hold, under one lock.

build.sh registers each ninja phase (register/unregister, <tree>/.build.pid). lease.sh calls begin at
the start of a timing hold and end at its release. Correctness holds never call it.
begin: SIGSTOP to every registered ninja, then to each of its descendants (the compile jobs ninja
  spawned), by the recorded ninja pid and the tree found under it. A detached guard then watches the
  hold's lease.sh pid.
register during a hold: the new ninja is stopped the same way at once, unless build.sh runs inside that
  hold (OPENMM_LEASE_PID is the owner), which would deadlock the hold on its own build.
end: SIGCONT to every stopped process whose command line still matches, descendants first, and
  taskpolicy -B on the ninja (undoing the older background demotion).
Crash safety: every call first checks the saved owner. If it no longer runs lease.sh, every saved
process is continued and the state is dropped. The guard does the same within GUARD_POLL_SECONDS of the
owner dying, so a killed holder can't leave builds stopped even when no other lease.sh or build.sh runs.
active: exits 0 while a timing hold is live and the caller isn't inside it (build.sh waits on this).
Build gap: when a timing hold ends with builds pending (a live build.sh, waiting or building, marked in
  <tree>/.build.sh.pid, or a live registered ninja), the next timing hold waits until those builds end,
  for at most GAP_SECONDS. gap exits 0 while that lasts (lease.sh asks before a timing ticket takes the
  lease) and ends the gap, with a log line, once the builds are done or the cap runs out. Builds started
  during the gap don't extend it. Builds still running at the cap are paused by the next hold as usual.
recover: only the dead-holder check (lease.sh calls it when it clears a dead lease).
status: prints the owner and the paused builds, the gap if one is up, and the last gaps from the log.
BUILD_POLICY_BENCH replaces /tmp/openmm-metal-bench, for tests.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

bench = Path(os.environ.get('BUILD_POLICY_BENCH', '/tmp/openmm-metal-bench'))
state = bench / '.timing-build-policy.json'
gap_state = bench / '.build-gap.json'
policy_log = bench / 'ultra-lead/build-policy.log'
GAP_SECONDS = 20
GUARD_POLL_SECONDS = 2
STOP_PASSES = 5


def now():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def log(line):
    line = f'{now()} build-policy {line}'
    print(line, file=sys.stderr, flush=True)
    with policy_log.open('a') as out:
        out.write(line + '\n')


def command(pid):
    return subprocess.run(['ps', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()


def is_owner(pid):
    return 'lease.sh' in command(pid)


def recorded(tree, pid):
    marker = Path(tree) / '.build.pid'
    if not marker.exists() or marker.read_text().strip() != str(pid):
        return False
    line = command(pid)
    return 'ninja ' in line and str(Path(tree) / 'build') in line


def descendants(pid):
    children = {}
    pairs = subprocess.run(['ps', '-axo', 'pid=,ppid='], capture_output=True, text=True).stdout.split()
    for child, parent in zip(pairs[0::2], pairs[1::2]):
        children.setdefault(int(parent), []).append(int(child))
    found, todo = [], list(children.get(pid, []))
    while todo:
        p = todo.pop()
        found.append(p)
        todo.extend(children.get(p, []))
    return found


def signal_pid(pid, sig):
    try:
        os.kill(pid, sig)
        return True
    except ProcessLookupError:
        return False


# Stops the ninja first so it starts no new job, then its descendants until a pass finds none new.
def stop(tree, pid):
    if not recorded(tree, pid):
        return None
    entry = {'tree': tree, 'pid': pid, 'command': command(pid), 'children': []}
    signal_pid(pid, signal.SIGSTOP)
    seen = set()
    for _ in range(STOP_PASSES):
        new = [p for p in descendants(pid) if p not in seen]
        if not new:
            break
        for p in new:
            line = command(p)
            if line and signal_pid(p, signal.SIGSTOP):
                entry['children'].append([p, line])
            seen.add(p)
    log(f'stop pid={pid} tree={tree} children={len(entry["children"])}')
    return entry


# Continues only processes whose command line is the one recorded at the stop, so a reused pid is left alone.
def resume(entry):
    if isinstance(entry, list):
        entry = {'tree': entry[0], 'pid': entry[1], 'command': None, 'children': []}
    resumed = 0
    for p, line in entry['children']:
        if command(p) == line and signal_pid(p, signal.SIGCONT):
            resumed += 1
    pid = entry['pid']
    line = command(pid)
    if line and (entry['command'] is None or line == entry['command']):
        signal_pid(pid, signal.SIGCONT)
        subprocess.run(['taskpolicy', '-B', '-p', str(pid)], capture_output=True)
        log(f'continue pid={pid} tree={entry["tree"]} children={resumed}')
    else:
        log(f'continue pid={pid} tree={entry["tree"]}: ninja gone, children={resumed}')


# A pending build is a marker whose pid still runs that tree's build.sh (.build.sh.pid) or ninja (.build.pid).
def live(marker, pid):
    marker = Path(marker)
    if not marker.exists() or marker.read_text().strip() != str(pid):
        return False
    if marker.name == '.build.pid':
        return recorded(str(marker.parent), pid)
    line = command(pid)
    return 'build.sh' in line and str(marker.parent) in line


def pending():
    markers = sorted(bench.glob('ultra-*/.build.sh.pid')) + sorted(bench.glob('ultra-*/.build.pid'))
    builds = []
    for marker in markers:
        pid = marker.read_text().strip()
        if pid.isdigit() and live(marker, int(pid)):
            builds.append([str(marker), int(pid)])
    return builds


def trees(builds):
    return ', '.join(sorted({Path(marker).parent.name for marker, _ in builds}))


def start_gap(owner):
    builds = pending()
    if not builds:
        return
    gap_state.write_text(json.dumps({'start': time.time(), 'owner': owner, 'builds': builds}))
    log(f'gap after the timing hold of pid {owner}: timing waits up to {GAP_SECONDS} s for {trees(builds)}')


# The gap in force, or None after ending one whose builds are done or whose cap ran out.
def current_gap():
    if not gap_state.exists():
        return None
    gap = json.loads(gap_state.read_text())
    gap['builds'] = [b for b in gap['builds'] if live(*b)]
    waited = time.time() - gap['start']
    if gap['builds'] and waited < GAP_SECONDS:
        return gap
    gap_state.unlink(missing_ok=True)
    if gap['builds']:
        log(f'gap ended after {waited:.0f} s at the cap; next hold pauses {trees(gap["builds"])}')
    else:
        log(f'gap ended after {waited:.0f} s: its builds are done')
    return None


def save(saved):
    state.write_text(json.dumps(saved))


def release(saved, why):
    for entry in saved['builds']:
        resume(entry)
    state.unlink(missing_ok=True)
    start_gap(saved['owner'])
    if why:
        log(f'{why}: owner {saved["owner"]} released {len(saved["builds"])} builds')


def load():
    saved = json.loads(state.read_text()) if state.exists() else None
    if saved and not is_owner(saved['owner']):
        release(saved, 'recovered after a dead holder')
        return None
    return saved


def inside(saved):
    return os.environ.get('OPENMM_LEASE_PID') == str(saved['owner'])


def guard(owner):
    while is_owner(owner):
        time.sleep(GUARD_POLL_SECONDS)
    with (bench / '.build-policy.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        load()


action = sys.argv[1]
if action == 'guard':
    guard(int(sys.argv[2]))
    raise SystemExit(0)
# lease.sh checks the gap before a timing ticket takes the lease; a holder that didn't (a lease.sh
# started before the gap existed) waits here, lease held, until the gap ends.
if action == 'begin':
    waited = 0
    while True:
        with (bench / '.build-policy.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not current_gap():
                break
        time.sleep(GUARD_POLL_SECONDS)
        waited += GUARD_POLL_SECONDS
    if waited:
        log(f'timing hold of pid {sys.argv[2]} waited {waited} s for the gap')
with (bench / '.build-policy.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    saved = load()
    if action == 'register':
        tree, pid = sys.argv[2], int(sys.argv[3])
        (Path(tree) / '.build.pid').write_text(str(pid) + '\n')
        if saved and not inside(saved):
            entry = stop(tree, pid)
            if entry:
                saved['builds'].append(entry)
                save(saved)
    elif action == 'unregister':
        tree, pid = sys.argv[2], int(sys.argv[3])
        marker = Path(tree) / '.build.pid'
        if marker.exists() and marker.read_text().strip() == str(pid):
            marker.unlink()
    elif action == 'begin':
        owner = int(sys.argv[2])
        if saved:
            raise RuntimeError('another timing policy owner is live')
        saved = {'owner': owner, 'builds': []}
        save(saved)
        subprocess.Popen([sys.executable, __file__, 'guard', str(owner)], start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for marker in sorted(bench.glob('ultra-*/.build.pid')):
            entry = stop(str(marker.parent), int(marker.read_text()))
            if entry:
                saved['builds'].append(entry)
                save(saved)
    elif action == 'end':
        if saved and saved['owner'] == int(sys.argv[2]):
            release(saved, '')
    elif action == 'recover':
        pass
    elif action == 'active':
        raise SystemExit(0 if saved and not inside(saved) else 1)
    elif action == 'gap':
        raise SystemExit(0 if not saved and current_gap() else 1)
    elif action == 'status':
        if saved:
            print(f'timing hold of lease.sh pid {saved["owner"]}: {len(saved["builds"])} builds paused'
                  + ''.join(f', {Path(e["tree"]).name}' for e in saved['builds'] if isinstance(e, dict)))
        else:
            print('no timing hold: builds run')
        gap = None if saved else current_gap()
        if gap:
            print(f'build gap: timing tickets wait up to {GAP_SECONDS - time.time() + gap["start"]:.0f} s more'
                  f' for {trees(gap["builds"])}')
        lines = policy_log.read_text().splitlines()[-2000:] if policy_log.exists() else []
        for line in [l for l in lines if ' build-policy gap ' in l][-4:]:
            print('  ' + line)
    else:
        raise SystemExit('unknown build policy action')
