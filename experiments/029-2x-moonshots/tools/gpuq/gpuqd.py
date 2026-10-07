"""gpuqd: the M3 Ultra's GPU scheduler (029 round 2, owner-requested 2026-09-28).

One daemon owns the GPU. Clients (the gpuq CLI, and lease.sh and build.sh through it) talk JSON lines
over a Unix socket; state lives in SQLite, so a restarted daemon picks up where the old one stopped.

Jobs come in two kinds. A managed job is an argv the daemon runs in the submitter's cwd and environment,
under a runner (this file, `run` mode) that leads its own session, logs to the job dir and writes the
exit code there, so a restarted daemon still learns it. An attached hold is a client process that asks
for the GPU and then runs the work itself in its own process group, which it reports (lease.sh's shim).

Classes, highest first: merge (gate.sh merge path), window (once its not-before is due), correctness,
timing, then build. merge and correctness share the GPU, up to MAX_SHARED jobs; window and timing have
it alone. At night (00:00-07:00 UTC, the reserved timing slot) timing ranks above correctness, and while a
timing job is queued, correctness and builds start nothing unless their --not-before is in the day; a
build gap then holds no timing either (2026-09-30, 47 minutes lost to a backfilled gap). By day, once
a timing job has waited STARVE_SECONDS, correctness starts nothing new until it runs. Within a class,
the lane served least recently goes first, then FIFO. A timing or correctness job whose estimate would
run past a queued window's not-before waits; shorter ones backfill. A due window drains the GPU and
starts; nothing below it starts meanwhile.
Builds use no GPU and never run beside a timing job or window: queued builds wait, and running ones are
stopped (SIGSTOP to the recorded process group, then to each descendant in another group, since ninja
puts every command in its own group) and continued after. Every signal goes to a pid or group whose
start time matches the one recorded; nothing is ever matched by name. When a timing job or window ends
with builds running, or queued and due (their --not-before passed), a build gap holds timing back until
those builds end, for at most GAP_SECONDS. A due window doesn't wait for a gap.
A job holds its class's resources until its recorded process group has drained: when the managed
runner exits, or an attached client releases or dies, anything left in the group gets SIGTERM, then
SIGKILL KILL_GRACE s later, and the job ends only once the group is gone. An attached client forks its
work into a new group, blocked, before it submits, so every hold's group is known before its grant.
Crash safety: a managed job is marked launching before its runner starts, and the runner records its
pid and start time first thing; a restarted daemon adopts it or marks it lost, never runs it again.
Pause intent is written before each SIGSTOP, and a restart continues every recorded process.
Caps: SIGTERM to the job's group at the cap, SIGKILL KILL_GRACE s later. The estimate is --est, else the
median runtime of the lane's same script and class, else half the cap; the cap defaults to twice it.
A window needs --est, and its cap defaults to twice the estimate plus WINDOW_CAP_MARGIN.
Night scheduling is declarative (round 3): any class takes --not-before (a window reserves the GPU from
then; other classes just wait for it) and --not-after (a job that hasn't started by then ends as expired
and never runs). --after ID starts a job only once job ID ended with exit 0; if ID failed, was killed,
capped, cancelled, lost, skipped or expired, the job ends as skipped, and so does anything after it.
Each job end records a reason: exit (its own exit code), killed (a signal gpuqd didn't send; the note says
whether the hold client forwarded it), cap or cancelled (gpuqd's SIGTERM), lost, skipped, expired or off.
On each job end one line goes to events/<lane>.log. The daemon mirrors the running GPU jobs into
/tmp/openmm-lease (pid, owner, correctness, members/) and the queue into /tmp/openmm-lease-queue, for
lease-legacy.sh and the tools that read those. `gpuq off` hands the GPU back to lease-legacy.sh: gpuqd grants
nothing new, waits for the running GPU jobs, continues every paused build, then writes <home>/OFF and
ends the queued jobs with reason off (lease.sh and build.sh clients then fall back to the old path).
While OFF exists it starts nothing, refuses submits and leaves the mirrors alone. `gpuq on` undoes it.
usage: gpuqd.py [serve] | gpuqd.py run <jobdir>
"""
import json
import os
import re
from pathlib import Path
import shutil
import signal
import socket
import socketserver
import sqlite3
import statistics
import subprocess
import sys
import threading
import time

HOME = Path(os.environ.get('GPUQ_DIR', '/tmp/openmm-metal-bench/gpuq'))
SOCK = os.environ.get('GPUQ_SOCK', '/tmp/openmm-gpuq.sock')
MIRROR = Path(os.environ.get('GPUQ_LEASE_DIR', '/tmp/openmm-lease'))
MIRROR_QUEUE = Path(os.environ.get('GPUQ_QUEUE_DIR', '/tmp/openmm-lease-queue'))
IDLE_LOG = Path(os.environ.get('GPUQ_IDLE_LOG', '/tmp/openmm-lease-idle.log'))
GAP_SECONDS = float(os.environ.get('GPUQ_GAP_SECONDS', 900))
SLOT = os.environ.get('GPUQ_SLOT', '')  # day or night pins the slot, for tests
TICK_SECONDS = 1.0
KILL_GRACE = float(os.environ.get('GPUQ_KILL_GRACE', 30))
CRASH_AT = os.environ.get('GPUQ_CRASH_AT')  # launch or pause: the daemon dies there, for the crash tests
MAX_SHARED = 6
STARVE_SECONDS = 1800
NIGHT_END_HOUR = 7
DEFAULT_EST = 600
WINDOW_CAP_MARGIN = 1200
IDLE_POLL_SECONDS = 5
IDLE_WARN_SECONDS = 60
IDLE_BELOW_PERCENT = 10
CLASSES = ('merge', 'window', 'correctness', 'timing', 'build')
EXCLUSIVE = {'window', 'timing'}
SHARED = {'merge', 'correctness'}
NICE = {'merge': 0, 'window': 0, 'correctness': 0, 'timing': 0, 'build': 10}

SCHEMA = '''
CREATE TABLE IF NOT EXISTS jobs(
    id INTEGER PRIMARY KEY, lane TEXT, cls TEXT, kind TEXT, what TEXT, script TEXT,
    argv TEXT, cwd TEXT, env TEXT, est REAL, est_from TEXT, cap REAL, not_before REAL, after INTEGER,
    state TEXT, submitted REAL, started REAL, ended REAL, reason TEXT, exit_code INTEGER,
    pid INTEGER, pid_start TEXT, pgid INTEGER, pgid_start TEXT, client_pid INTEGER, client_start TEXT,
    paused INTEGER DEFAULT 0, stopped TEXT DEFAULT '[]', term_sent REAL, cancel_by TEXT,
    released INTEGER DEFAULT 0, drain REAL, not_after REAL, signal INTEGER, note TEXT);
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
'''
# Columns added after the first state.db: a restarted daemon adds them to an older table.
ADDED_COLUMNS = (('not_after', 'REAL'), ('signal', 'INTEGER'), ('note', 'TEXT'))


def now_iso(t=None):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))


def signame(sig):
    try:
        return signal.Signals(sig).name
    except ValueError:
        return f'signal {sig}'


def log(line):
    line = f'{now_iso()} {line}'
    print(line, flush=True)


def crash_point(name):
    if CRASH_AT == name:
        log(f'GPUQ_CRASH_AT={name}: exiting now')
        os._exit(99)


def is_night(t):
    if SLOT:
        return SLOT == 'night'
    return time.gmtime(t).tm_hour < NIGHT_END_HOUR


# ---------------------------------------------------------------- processes

class Proc:
    __slots__ = ('pid', 'ppid', 'pgid', 'stat', 'start')


def snapshot():
    """Every process: pid -> Proc with ppid, pgid, state and start time (ps lstart)."""
    out = subprocess.run(['ps', '-axww', '-o', 'pid=,ppid=,pgid=,stat=,lstart='],
                         capture_output=True, text=True).stdout
    procs = {}
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        p = Proc()
        p.pid, p.ppid, p.pgid, p.stat, p.start = int(parts[0]), int(parts[1]), int(parts[2]), parts[3], parts[4].strip()
        procs[p.pid] = p
    return procs


def alive(procs, pid, start):
    p = procs.get(pid)
    return bool(p and start and p.start == start and not p.stat.startswith('Z'))


def group_verified(procs, pgid, leader_start):
    """The group still exists and is the one recorded: its leader, if alive, has the recorded start time."""
    if not pgid:
        return False
    leader = procs.get(pgid)
    if leader and leader.start != leader_start:
        return False
    return any(p.pgid == pgid and not p.stat.startswith('Z') for p in procs.values())


def signal_group(procs, pgid, leader_start, sig):
    if not group_verified(procs, pgid, leader_start):
        return False
    try:
        os.killpg(pgid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def descendants(procs, roots):
    children = {}
    for p in procs.values():
        children.setdefault(p.ppid, []).append(p.pid)
    found, todo = set(), list(roots)
    while todo:
        for c in children.get(todo.pop(), []):
            if c not in found:
                found.add(c)
                todo.append(c)
    return found


# ---------------------------------------------------------------- scheduling (pure)

def after_ok(job, by_id):
    """by_id holds the jobs that haven't ended. A dependency missing from it ended, and ended with exit 0:
    the daemon's settle pass skips a job whose dependency failed before dispatch sees it."""
    dep = by_id.get(job['after']) if job['after'] else None
    return dep is None or dep['state'] == 'ended'


def in_time(job, now):
    """Inside the job's --not-before/--not-after range. A window's not-before is handled by dispatch()
    itself, since a window reserves the GPU ahead of it."""
    if job.get('not_after') and now >= job['not_after']:
        return False
    return job['cls'] == 'window' or (job['not_before'] or 0) <= now


def succeeded(job):
    return job['reason'] == 'exit' and job['exit_code'] == 0


def rr_order(jobs, cls, served):
    """Round-robin across lanes (least recently served first), FIFO within a lane."""
    lanes = {}
    for j in sorted(jobs, key=lambda j: j['id']):
        lanes.setdefault(j['lane'], []).append(j)
    last = {lane: served.get(f'{cls}:{lane}', 0.0) for lane in lanes}
    order = []
    tick = 0
    while lanes:
        lane = min(lanes, key=lambda l: (last[l], lanes[l][0]['id']))
        order.append(lanes[lane].pop(0))
        if not lanes[lane]:
            del lanes[lane]
        tick += 1
        last[lane] = float('inf') if lane not in lanes else 1e18 + tick
    return order


def gap_builds(now, jobs):
    """The builds a gap waits for after an exclusive job: running (or launching), or queued, inside
    their --not-before/--not-after and with their --after dependency ended. A queued build that can't
    start holds no timing (2026-09-30: a build queued for 07:00Z made every night job wait the full
    GAP_SECONDS, and a build --after a correctness job that the day starve rule held idled the GPU
    for 13 minutes: the gap waited for the build, the build for the correctness job, that job for the
    starved timing job, and the timing job for the gap)."""
    by_id = {j['id']: j for j in jobs}
    return [j for j in jobs if j['cls'] == 'build' and j['state'] != 'ended'
            and (j['state'] != 'queued' or (in_time(j, now) and after_ok(j, by_id)))]


def gap_active(sched, now, by_id):
    gap = sched.get('gap')
    if not gap or now >= gap['until']:
        return False
    # A build missing from by_id has ended (callers pass the jobs that haven't).
    return any(by_id.get(b, {}).get('state', 'ended') != 'ended' for b in gap['builds'])


def dispatch(now, jobs, sched):
    """The queued jobs to start now, GPU jobs first in priority order, then builds."""
    by_id = {j['id']: j for j in jobs}
    running = [j for j in jobs if j['state'] == 'running']
    queued = [j for j in jobs if j['state'] == 'queued' and after_ok(j, by_id) and in_time(j, now)]
    served = sched.setdefault('served', {})
    starts = []
    exclusive = any(j['cls'] in EXCLUSIVE for j in running)
    windows = [j for j in queued if j['cls'] == 'window']
    due = [w for w in windows if (w['not_before'] or 0) <= now]
    upcoming = min((w['not_before'] for w in windows if (w['not_before'] or 0) > now), default=None)

    def fits(j):
        return upcoming is None or now + j['est'] <= upcoming

    def start(j):
        starts.append(j)
        served[f"{j['cls']}:{j['lane']}"] = now + len(starts) * 1e-6

    # The night slot is timing's: while a timing job is queued at night, correctness and builds start
    # nothing unless the submitter planned them for the day (a --not-before in the day), and a build gap
    # holds no timing, since the builds it waits for can't start. Before this (2026-09-30 00:13Z) an ad
    # hoc build queued after a window opened a gap that two correctness jobs backfilled: 47 minutes.
    night = is_night(now)
    hold = night and any(j['cls'] == 'timing' for j in queued)

    def held(j):
        return hold and not (j['not_before'] and not is_night(j['not_before']))

    if not exclusive:
        shared = sum(j['cls'] in SHARED for j in running)
        order = ('merge', 'window', 'timing', 'correctness') if night else ('merge', 'window', 'correctness', 'timing')
        starved = not night and any(j['cls'] == 'timing' and now - j['submitted'] > STARVE_SECONDS for j in queued)
        for cls in order:
            candidates = rr_order([j for j in queued if j['cls'] == cls], cls, served)
            if cls == 'merge':
                for j in candidates:
                    if shared < MAX_SHARED:
                        start(j)
                        shared += 1
            elif cls == 'window':
                if not due:
                    continue
                if shared == 0 and not starts:
                    start(min(due, key=lambda w: w['id']))
                    exclusive = True
                break
            elif cls == 'correctness':
                if starved:
                    continue
                for j in candidates:
                    if shared < MAX_SHARED and fits(j) and not held(j):
                        start(j)
                        shared += 1
            elif cls == 'timing':
                if gap_active(sched, now, by_id) and not hold:
                    continue
                head = next((j for j in candidates if fits(j)), None)
                if head is None:
                    continue
                if shared == 0 and not starts:
                    start(head)
                    exclusive = True
                break
    if not exclusive and not due:
        for j in sorted((j for j in queued if j['cls'] == 'build'), key=lambda j: j['id']):
            if not held(j):
                start(j)
    return starts


def predict(now, jobs, sched):
    """Predicted start time per queued job id: dispatch() run forward over the estimates."""
    sim = [dict(j) for j in jobs if j['state'] != 'ended']
    sched = json.loads(json.dumps(sched))
    predicted = {}
    t = now
    for _ in range(1000):
        for j in dispatch(t, sim, sched):
            j['state'], j['started'] = 'running', t
            predicted[j['id']] = t
        if not any(j['state'] == 'queued' for j in sim):
            break
        running = [j for j in sim if j['state'] == 'running']
        ends = {j['id']: max(j['started'] + j['est'], t + 1) for j in running}
        times = list(ends.values())
        times += [j['not_before'] for j in sim if j['state'] == 'queued' and (j['not_before'] or 0) > t]
        gap = sched.get('gap')
        if gap and gap['until'] > t:
            times.append(gap['until'])
        if not times:
            break
        t = min(times)
        ended_exclusive = False
        for j in running:
            if ends[j['id']] <= t:
                j['state'] = 'ended'
                ended_exclusive |= j['cls'] in EXCLUSIVE
        if ended_exclusive:
            builds = gap_builds(t, sim)
            if builds:
                last = max(max(j.get('started') or t, t) + j['est'] for j in builds)
                sched['gap'] = {'until': min(t + GAP_SECONDS, last), 'builds': [j['id'] for j in builds]}
    return predicted


# ---------------------------------------------------------------- daemon

def public(job):
    """A job row for replies: without the environment snapshot."""
    return {k: v for k, v in job.items() if k != 'env'}


class Daemon:
    def __init__(self):
        HOME.mkdir(parents=True, exist_ok=True)
        (HOME / 'jobs').mkdir(exist_ok=True)
        (HOME / 'events').mkdir(exist_ok=True)
        self.db = sqlite3.connect(HOME / 'state.db', check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        have = {row['name'] for row in self.db.execute('PRAGMA table_info(jobs)')}
        for name, kind in ADDED_COLUMNS:
            if name not in have:
                self.db.execute(f'ALTER TABLE jobs ADD COLUMN {name} {kind}')
        self.lock = threading.Condition()
        self.children = {}
        self.idle = {}
        self.last_idle_poll = 0.0

    # ---- state
    def meta(self, key, default):
        row = self.db.execute('SELECT value FROM meta WHERE key=?', (key,)).fetchone()
        return json.loads(row['value']) if row else default

    def set_meta(self, key, value):
        self.db.execute('INSERT OR REPLACE INTO meta VALUES (?, ?)', (key, json.dumps(value)))

    def jobs(self, where="state != 'ended'", args=()):
        return [dict(r) for r in self.db.execute(f'SELECT * FROM jobs WHERE {where} ORDER BY id', args)]

    def job(self, jid):
        row = self.db.execute('SELECT * FROM jobs WHERE id=?', (jid,)).fetchone()
        return dict(row) if row else None

    def update(self, jid, **fields):
        cols = ', '.join(f'{k}=?' for k in fields)
        self.db.execute(f'UPDATE jobs SET {cols} WHERE id=?', (*fields.values(), jid))
        self.lock.notify_all()

    def sched(self):
        return {'gap': self.meta('gap', None), 'served': self.meta('served', {})}

    def estimate(self, lane, script, cls, cap):
        rows = self.db.execute(
            'SELECT ended - started AS d FROM jobs WHERE lane=? AND script=? AND cls=? AND reason=\'exit\' '
            'AND exit_code=0 ORDER BY id DESC LIMIT 20', (lane, script, cls)).fetchall()
        if rows:
            return statistics.median(r['d'] for r in rows), f'median of {len(rows)}'
        return (cap / 2 if cap else DEFAULT_EST), 'default'

    # ---- requests
    def submit(self, req):
        cls = req['cls']
        if cls not in CLASSES:
            raise ValueError(f'unknown class {cls}')
        if req['kind'] not in ('managed', 'attached'):
            raise ValueError('kind is managed or attached')
        if (HOME / 'OFF').exists():
            raise ValueError('gpuq is off: use the old lease.sh path')
        not_before, not_after, after = req.get('not_before'), req.get('not_after'), req.get('after')
        if not_after and not_after <= time.time():
            raise ValueError(f'--not-after {now_iso(not_after)} has already passed')
        if not_after and not_before and not_after <= not_before:
            raise ValueError(f'--not-after {now_iso(not_after)} is not later than --not-before {now_iso(not_before)}')
        if after and not self.job(after):
            raise ValueError(f'--after {after}: no such job')
        if cls == 'window' and not req.get('est'):
            raise ValueError('a window job needs --est (window.sh --estimate prints it); '
                             f'its cap defaults to twice the estimate plus {WINDOW_CAP_MARGIN // 60} min')
        argv = req['argv']
        script = os.path.basename(argv[0]) if argv else ''
        cap = req.get('cap')
        if req.get('est'):
            est, est_from = float(req['est']), 'given'
        else:
            est, est_from = self.estimate(req['lane'], script, cls, cap)
        if cap is None and cls == 'window':
            cap = 2 * est + WINDOW_CAP_MARGIN
        elif cap is None and cls != 'build':
            cap = 2 * est
        client_start = pgid = pgid_start = None
        if req['kind'] == 'attached':
            procs = snapshot()
            p, leader = procs.get(req['client_pid']), procs.get(req.get('pgid'))
            if not p:
                raise ValueError('the client pid is not running')
            if not leader or leader.pgid != leader.pid:
                raise ValueError('an attached hold needs its process group, led by a running process')
            client_start, pgid, pgid_start = p.start, leader.pid, leader.start
        cur = self.db.execute(
            'INSERT INTO jobs(lane, cls, kind, what, script, argv, cwd, env, est, est_from, cap, not_before, not_after, '
            'after, state, submitted, client_pid, client_start, pgid, pgid_start) '
            'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            (req['lane'], cls, req['kind'], req.get('what') or ' '.join(argv)[:200], script, json.dumps(argv),
             req.get('cwd'), json.dumps(req.get('env') or {}), est, est_from, cap, not_before, not_after,
             after, 'queued', time.time(), req.get('client_pid'), client_start, pgid, pgid_start))
        jid = cur.lastrowid
        (HOME / 'jobs' / str(jid)).mkdir(exist_ok=True)
        when = ''.join(f' {name} {now_iso(t)}' for name, t in (('not before', not_before), ('not after', not_after)) if t)
        when += f' after {after}' if after else ''
        log(f'submit {jid} {cls} {req["lane"]} {req["kind"]} est {est:.0f} s ({est_from}) cap {cap}{when}: '
            f'{self.job(jid)["what"]}')
        self.tick()
        return {'id': jid}

    def release(self, req):
        job = self.job(req['id'])
        if job and job['state'] == 'running':
            # signal: the one that ended the work; note: who sent it, when the hold client knows.
            self.update(job['id'], released=1, exit_code=req.get('exit_code'), signal=req.get('signal'),
                        note=req.get('note'))
            self.tick()
        elif job and job['state'] == 'queued':
            self.finish(job, 'cancelled', None)
        return {}

    def off(self, req):
        if not (HOME / 'OFF').exists():
            if not self.meta('draining', False):
                log('gpuq off: no new grants; waiting for the running GPU jobs, then OFF')
            self.set_meta('draining', True)
            self.tick()
        return {'off': (HOME / 'OFF').exists()}

    def on(self, req):
        self.set_meta('draining', False)
        if (HOME / 'OFF').exists():
            (HOME / 'OFF').unlink()
            log('gpuq on: OFF removed, gpuqd schedules again')
        self.tick()
        return {'off': False}

    def cancel(self, req):
        job = self.job(req['id'])
        if not job:
            raise ValueError('no such job')
        if req.get('lane') != job['lane']:
            raise ValueError(f'job {job["id"]} belongs to lane {job["lane"]}; cancel takes your own lane (--lane)')
        if job['state'] == 'queued':
            self.finish(job, 'cancelled', None)
        elif job['state'] == 'running':
            procs = snapshot()
            if job['paused']:
                self.resume_build(job, procs)
            signal_group(procs, job['pgid'], job['pgid_start'], signal.SIGTERM)
            self.update(job['id'], term_sent=time.time(), cancel_by=req['lane'])
        self.tick()
        return {'state': self.job(job['id'])['state']}

    def wait(self, req):
        deadline = time.time() + min(float(req.get('timeout', 20)), 60)
        states = set(req.get('states', ['ended']))
        while True:
            job = self.job(req['id'])
            if not job or job['state'] in states or time.time() >= deadline:
                return {'job': job and public(job)}
            self.lock.wait(max(0.05, min(1.0, deadline - time.time())))

    def listing(self, req):
        now = time.time()
        jobs = [public(j) for j in self.jobs()]
        sched = self.sched()
        predicted = predict(now, jobs, sched)
        by_id = {j['id']: j for j in jobs}
        gap = sched['gap'] if gap_active(sched, now, by_id) else None
        return {'now': now, 'night': is_night(now), 'jobs': jobs, 'predicted': predicted, 'gap': gap,
                'off': (HOME / 'OFF').exists()}

    def history(self, req):
        where, args = "state = 'ended'", ()
        if req.get('lane'):
            where, args = "state = 'ended' AND lane = ?", (req['lane'],)
        rows = [public(j) for j in self.jobs(where, args)]
        return {'jobs': rows[-int(req.get('n', 30)):]}

    def status(self, req):
        job = self.job(req['id'])
        if not job:
            raise ValueError('no such job')
        return {'job': public(job), 'log': str(HOME / 'jobs' / str(job['id']) / 'out.log')}

    def handle(self, req):
        op = req.get('op')
        with self.lock:
            if op == 'submit':
                return self.submit(req)
            if op == 'off':
                return self.off(req)
            if op == 'on':
                return self.on(req)
            if op == 'release':
                return self.release(req)
            if op == 'cancel':
                return self.cancel(req)
            if op == 'wait':
                return self.wait(req)
            if op == 'ls':
                return self.listing(req)
            if op == 'history':
                return self.history(req)
            if op == 'status':
                return self.status(req)
            if op == 'ping':
                return {'pid': os.getpid()}
        raise ValueError(f'unknown op {op}')

    # ---- job lifecycle
    def finish(self, job, reason, code, note=None):
        now = time.time()
        if job['kind'] == 'managed' and code is None and reason not in ('cancelled', 'off', 'expired', 'skipped'):
            code = self.read_exit(job)
        elif job['released'] and code is None:
            code = job['exit_code']
        sig = job['signal'] or (self.read_signal(job) if job['kind'] == 'managed' else None)
        if reason in ('exit', 'lost') and job['term_sent']:
            reason = 'cancelled' if job['cancel_by'] else 'cap'
            code = 128 + signal.SIGKILL if code is None else code
            why = f'the cancel by lane {job["cancel_by"]}' if job['cancel_by'] else f'the {job["cap"]:.0f} s cap'
            note = f'gpuqd sent SIGTERM at {why}' + (f', the work died of {signame(sig)}' if sig else '')
        elif reason == 'exit' and code is None:
            reason = 'lost'
        elif reason == 'exit' and sig:
            reason = 'killed'
            note = f'{signame(sig)} ' + (job['note'] or 'from outside gpuqd')
        elif reason == 'exit' and job['drain']:
            note = 'gpuqd ended processes left in its group after its work exited'
        elif reason == 'lost' and job['kind'] == 'attached':
            note = note or 'its hold client died'
        if job['paused']:
            self.resume_build(job, snapshot())
        self.update(job['id'], state='ended', ended=now, reason=reason, exit_code=code, signal=sig, note=note)
        elapsed = now - job['started'] if job['started'] else 0
        line = (f'job {job["id"]} {job["cls"]} ended: {reason}{f" ({note})" if note else ""}, exit {code}, '
                f'ran {elapsed:.0f} s, waited {(job["started"] or now) - job["submitted"]:.0f} s: {job["what"]}')
        with (HOME / 'events' / f'{job["lane"]}.log').open('a') as out:
            out.write(f'{now_iso(now)} {line}\n')
        log(line)
        self.children.pop(job['id'], None)
        if job['cls'] in EXCLUSIVE and job['started']:
            builds = [j['id'] for j in gap_builds(now, self.jobs())]
            if builds:
                self.set_meta('gap', {'start': now, 'until': now + GAP_SECONDS, 'builds': builds})
                log(f'build gap after job {job["id"]}: timing waits up to {GAP_SECONDS:.0f} s for builds {builds}')

    def read_exit(self, job):
        try:
            return int((HOME / 'jobs' / str(job['id']) / 'exit').read_text())
        except (FileNotFoundError, ValueError):
            return None

    def read_signal(self, job):
        """The signal that ended a managed job's command, which its runner writes next to the exit code."""
        try:
            return int((HOME / 'jobs' / str(job['id']) / 'signal').read_text())
        except (FileNotFoundError, ValueError):
            return None

    def settle(self, now):
        """Ends the queued jobs that can never start: past their --not-after, or after a job that failed.
        Repeats, so a skip goes down a whole --after chain in one tick."""
        changed = True
        while changed:
            changed = False
            for job in self.jobs("state = 'queued'"):
                dep = self.job(job['after']) if job['after'] else None
                if job['not_after'] and now >= job['not_after']:
                    self.finish(job, 'expired', None, f'not started by its not-after {now_iso(job["not_after"])}')
                elif dep and dep['state'] == 'ended' and not succeeded(dep):
                    code = f', exit {dep["exit_code"]}' if dep['exit_code'] is not None else ''
                    self.finish(job, 'skipped', None, f'dep {dep["id"]} failed: {dep["reason"]}{code}')
                else:
                    continue
                changed = True

    def launch(self, job):
        jobdir = HOME / 'jobs' / str(job['id'])
        if job['kind'] == 'attached':
            self.update(job['id'], state='running', started=time.time())
            return
        spec = {'argv': json.loads(job['argv']), 'cwd': job['cwd'], 'env': json.loads(job['env']),
                'nice': NICE[job['cls']], 'id': job['id']}
        (jobdir / 'spec.json').write_text(json.dumps(spec))
        # Persisted before the runner exists: a restart adopts the runner (jobdir/runner) or marks it lost.
        self.update(job['id'], state='launching', started=time.time())
        with (jobdir / 'out.log').open('ab') as out:
            child = subprocess.Popen([sys.executable, os.path.abspath(__file__), 'run', str(jobdir)],
                                     start_new_session=True, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                                     cwd='/')
        crash_point('launch')
        start = snapshot()[child.pid].start
        self.children[job['id']] = child
        threading.Thread(target=self.reaper, args=(child,), daemon=True).start()
        self.update(job['id'], state='running', started=time.time(), pid=child.pid, pid_start=start,
                    pgid=child.pid, pgid_start=start)

    def reaper(self, child):
        """Ends the job as soon as its runner exits, instead of at the next tick."""
        child.wait()
        with self.lock:
            self.tick()

    def pause_build(self, job, procs):
        if not group_verified(procs, job['pgid'], job['pgid_start']):
            return
        # Intent first: a daemon that dies mid-pause restarts with every stopped process on record.
        self.update(job['id'], paused=1, stopped='[]')
        if not signal_group(procs, job['pgid'], job['pgid_start'], signal.SIGSTOP):
            return
        crash_point('pause')
        stopped, seen = [], set()
        for _ in range(5):
            procs = snapshot()
            members = {p.pid for p in procs.values() if p.pgid == job['pgid']}
            new = [pid for pid in descendants(procs, members) - members if pid not in seen]
            if not new:
                break
            for pid in new:
                seen.add(pid)
                stopped.append([pid, procs[pid].start])
                self.update(job['id'], stopped=json.dumps(stopped))
                try:
                    os.kill(pid, signal.SIGSTOP)
                except ProcessLookupError:
                    pass
        log(f'paused build {job["id"]} ({job["lane"]}): group {job["pgid"]} and {len(stopped)} descendants')

    def resume_build(self, job, procs):
        resumed = 0
        # Reverse of the stop order: the deepest compile jobs first, ninja's own group last.
        for pid, start in reversed(json.loads(job['stopped'] or '[]')):
            if alive(procs, pid, start):
                try:
                    os.kill(pid, signal.SIGCONT)
                    resumed += 1
                except ProcessLookupError:
                    pass
        signal_group(procs, job['pgid'], job['pgid_start'], signal.SIGCONT)
        self.update(job['id'], paused=0, stopped='[]')
        log(f'continued build {job["id"]} ({job["lane"]}): group {job["pgid"]} and {resumed} descendants')

    def reap(self, procs):
        now = time.time()
        for job in self.jobs("state = 'running'"):
            if job['kind'] == 'managed':
                child = self.children.get(job['id'])
                if child is not None:
                    done = child.poll() is not None
                else:
                    done = not alive(procs, job['pid'], job['pid_start'])
                reason = 'exit'
            else:
                done = job['released'] or not alive(procs, job['client_pid'], job['client_start'])
                reason = 'exit' if job['released'] else 'lost'
            if done:
                if not group_verified(procs, job['pgid'], job['pgid_start']):
                    self.finish(job, reason, None)
                elif not job['drain']:
                    if job['paused']:
                        self.resume_build(job, procs)
                    signal_group(procs, job['pgid'], job['pgid_start'], signal.SIGTERM)
                    self.update(job['id'], drain=now)
                    log(f'job {job["id"]}: its {"runner" if job["kind"] == "managed" else "client"} is done and '
                        f'group {job["pgid"]} still runs: SIGTERM, SIGKILL in {KILL_GRACE:.0f} s; it keeps the GPU till then')
                elif now - job['drain'] >= KILL_GRACE:
                    signal_group(procs, job['pgid'], job['pgid_start'], signal.SIGKILL)
                continue
            if job['cap']:
                over = now - job['started'] - job['cap']
                if over >= 0 and not job['term_sent']:
                    if job['paused']:
                        self.resume_build(job, procs)
                    signal_group(procs, job['pgid'], job['pgid_start'], signal.SIGTERM)
                    self.update(job['id'], term_sent=now)
                    log(f'job {job["id"]} reached its {job["cap"]:.0f} s cap: SIGTERM to group {job["pgid"]}')
            if job['term_sent'] and now - job['term_sent'] >= KILL_GRACE:
                if signal_group(procs, job['pgid'], job['pgid_start'], signal.SIGKILL):
                    log(f'job {job["id"]}: SIGKILL to group {job["pgid"]} after {KILL_GRACE} s')
        for job in self.jobs("state = 'queued' AND kind = 'attached'"):
            if not alive(procs, job['client_pid'], job['client_start']):
                self.finish(job, 'cancelled', None)

    def tick(self):
        procs = snapshot()
        self.reap(procs)
        if (HOME / 'OFF').exists():
            return
        now = time.time()
        self.settle(now)
        jobs = self.jobs()
        sched = self.sched()
        by_id = {j['id']: j for j in jobs}
        if sched['gap'] and not gap_active(sched, now, by_id):
            left = [b for b in sched['gap']['builds'] if by_id.get(b, {}).get('state') not in (None, 'ended')]
            why = f'the {GAP_SECONDS:.0f} s cap, builds {left} still running' if left else 'its builds ended'
            log(f'build gap ended after {now - sched["gap"]["start"]:.0f} s: {why}')
            sched['gap'] = None
            self.set_meta('gap', None)
        served = dict(sched['served'])
        draining = self.meta('draining', False)
        starts = [] if draining else dispatch(now, jobs, sched)
        if sched['served'] != served:
            self.set_meta('served', sched['served'])
        exclusive = any(j['cls'] in EXCLUSIVE for j in jobs if j['state'] == 'running') or \
            any(j['cls'] in EXCLUSIVE for j in starts)
        for job in self.jobs("state = 'running' AND cls = 'build'"):
            if exclusive and not job['paused']:
                self.pause_build(job, procs)
            elif not exclusive and job['paused']:
                self.resume_build(job, procs)
        for job in starts:
            self.launch(job)
            log(f'start {job["id"]} {job["cls"]} {job["lane"]} after {now - job["submitted"]:.0f} s: {job["what"]}')
        self.mirror()
        self.watch_idle(now)
        if draining:
            self.finish_off()

    def finish_off(self):
        """The last step of gpuq off, once no GPU job runs and no build is paused."""
        jobs = self.jobs()
        if any(j['state'] != 'queued' and j['cls'] != 'build' or j['paused'] for j in jobs):
            return
        (HOME / 'OFF').write_text(f'{now_iso()} gpuq off\n')
        self.set_meta('draining', False)
        for job in jobs:
            if job['state'] == 'queued':
                self.finish(job, 'off', None)
        log('gpuq off: OFF written; lease.sh runs lease-legacy.sh, and running build jobs finish as they are')

    def watch_idle(self, now):
        timing = [j for j in self.jobs("state = 'running' AND cls = 'timing'")]
        if not timing:
            self.idle = {}
            return
        if now - self.last_idle_poll < IDLE_POLL_SECONDS:
            return
        self.last_idle_poll = now
        out = subprocess.run(['ioreg', '-r', '-d', '1', '-w', '0', '-c', 'IOAccelerator'],
                             capture_output=True, text=True).stdout
        found = re.search(r'"Device Utilization %"=(\d+)', out)
        util = int(found.group(1)) if found else 100
        for job in timing:
            idle = self.idle.get(job['id'], 0)
            idle = idle + IDLE_POLL_SECONDS if util < IDLE_BELOW_PERCENT else 0
            self.idle[job['id']] = idle
            if idle == IDLE_WARN_SECONDS:
                line = (f'{now_iso(now)} gpuq: GPU under {IDLE_BELOW_PERCENT}% for {IDLE_WARN_SECONDS} s in timing job '
                        f'{job["id"]} of {job["lane"]} ({job["what"]}). A timing hold carries only timing.')
                with IDLE_LOG.open('a') as out_log:
                    out_log.write(line + '\n')
                with (HOME / 'events' / f'{job["lane"]}.log').open('a') as out_log:
                    out_log.write(line + '\n')

    # ---- lease mirrors, for the tools that read /tmp/openmm-lease and its queue
    def mirror(self):
        jobs = self.jobs()
        gpu = [j for j in jobs if j['state'] == 'running' and j['cls'] in EXCLUSIVE | SHARED]
        if not gpu:
            # Only a lease dir this daemon wrote: after gpuq off, lease-legacy.sh may own /tmp/openmm-lease.
            pid = MIRROR / 'pid'
            if pid.exists() and pid.read_text().strip() == str(self.meta('mirror_pid', '')):
                shutil.rmtree(MIRROR, ignore_errors=True)
        else:
            (MIRROR / 'members').mkdir(parents=True, exist_ok=True)
            lines = {str(j['client_pid'] or j['pid']): f"{j['lane']} {now_iso(j['started'])} {j['what']}" for j in gpu}
            first = str(gpu[0]['client_pid'] or gpu[0]['pid'])
            if self.meta('mirror_pid', '') != first:
                self.set_meta('mirror_pid', first)
            for name, text in (('owner', lines[first]), ('pid', first)):
                path = MIRROR / name
                if not path.exists() or path.read_text().strip() != text:
                    (MIRROR / f'.{name}').write_text(text + '\n')
                    os.replace(MIRROR / f'.{name}', path)
            for pid, text in lines.items():
                path = MIRROR / 'members' / pid
                if not path.exists():
                    path.write_text(text + '\n')
            for path in (MIRROR / 'members').iterdir():
                if path.name not in lines:
                    path.unlink(missing_ok=True)
            marker = MIRROR / 'correctness'
            if any(j['cls'] in SHARED for j in gpu):
                marker.touch()
            else:
                marker.unlink(missing_ok=True)
        MIRROR_QUEUE.mkdir(parents=True, exist_ok=True)
        want = set()
        for j in jobs:
            if j['state'] == 'queued' and j['cls'] != 'build':
                lane = ''.join(c if c.isalnum() or c in '_.-' else '_' for c in j['lane'])
                name = f"{'0' if j['cls'] == 'merge' else ''}{int(j['submitted'] * 1e6)}-{lane}-{j['client_pid'] or os.getpid()}"
                want.add(name)
        mine = self.meta('mirrored', [])
        for name in set(mine) - want:
            (MIRROR_QUEUE / name).unlink(missing_ok=True)
        for name in want - set(mine):
            (MIRROR_QUEUE / name).touch()
        if set(mine) != want:
            self.set_meta('mirrored', sorted(want))

    # ---- startup
    def reattach(self):
        procs = snapshot()
        for job in self.jobs("state = 'launching'"):
            try:
                pid, start = (HOME / 'jobs' / str(job['id']) / 'runner').read_text().split(' ', 1)
                pid, start = int(pid), start.strip()
            except (FileNotFoundError, ValueError):
                pid, start = 0, None
            if alive(procs, pid, start) or self.read_exit(job) is not None:
                self.update(job['id'], state='running', pid=pid, pid_start=start, pgid=pid, pgid_start=start)
                log(f'adopted job {job["id"]}, launching when the last daemon stopped: runner {pid}')
            else:
                self.update(job['id'], state='running')
                self.finish(self.job(job['id']), 'lost', None)
        for job in self.jobs("state = 'running'"):
            log(f'reattached job {job["id"]} ({job["kind"]}, group {job["pgid"]}); the next tick checks it')
            # Whatever a dead daemon stopped is continued; the next tick pauses again if a timing job runs.
            if job['paused']:
                self.resume_build(job, procs)

    def loop(self):
        while True:
            with self.lock:
                try:
                    self.tick()
                except Exception as e:
                    log(f'tick failed: {e!r}')
            time.sleep(TICK_SECONDS)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        for raw in self.rfile:
            try:
                reply = {'ok': True, **self.server.daemon.handle(json.loads(raw))}
            except Exception as e:
                reply = {'ok': False, 'error': str(e)}
            self.wfile.write((json.dumps(reply) + '\n').encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def serve():
    daemon = Daemon()
    try:
        with socket.socket(socket.AF_UNIX) as probe:
            probe.connect(SOCK)
        sys.exit(f'another gpuqd answers on {SOCK}')
    except (FileNotFoundError, ConnectionRefusedError):
        Path(SOCK).unlink(missing_ok=True)
    with daemon.lock:
        daemon.reattach()
    server = Server(SOCK, Handler)
    server.daemon = daemon
    os.chmod(SOCK, 0o600)
    log(f'gpuqd {os.getpid()} serving {SOCK}, state {HOME}')
    threading.Thread(target=daemon.loop, daemon=True).start()
    server.serve_forever()


# ---------------------------------------------------------------- runner

def run(jobdir):
    """Leads the job's session: runs the argv, waits, and writes the exit code for any daemon to read."""
    jobdir = Path(jobdir)
    start = snapshot()[os.getpid()].start
    (jobdir / '.runner').write_text(f'{os.getpid()} {start}\n')
    os.replace(jobdir / '.runner', jobdir / 'runner')
    spec = json.loads((jobdir / 'spec.json').read_text())
    os.nice(spec['nice'])
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: None)
    env = dict(spec['env'], GPUQ_JOB=str(spec['id']), OPENMM_LEASE_PID=str(os.getpid()))
    try:
        child = subprocess.Popen(spec['argv'], cwd=spec['cwd'], env=env)
        code = child.wait()
        if code < 0:
            (jobdir / 'signal').write_text(f'{-code}\n')
            code = 128 - code
    except OSError as e:
        print(f'gpuq: cannot run {spec["argv"][0]}: {e}', flush=True)
        code = 127
    (jobdir / '.exit').write_text(f'{code}\n')
    os.replace(jobdir / '.exit', jobdir / 'exit')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'run':
        run(sys.argv[2])
    elif len(sys.argv) == 1 or sys.argv[1:] == ['serve']:
        serve()
    else:
        sys.exit(__doc__.rsplit('usage: ', 1)[1])
