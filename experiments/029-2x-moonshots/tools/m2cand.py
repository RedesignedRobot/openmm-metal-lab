"""Submit a verified dirty snapshot to the M2's serialized build/check pipeline."""
import argparse
import hashlib
import re
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--baseline', action='store_true')
parser.add_argument('-r', default='2', type=int)
parser.add_argument('-s', default='15', type=int)
parser.add_argument('-t', default='all')
parser.add_argument('worktree')
a = parser.parse_args()
here = Path(__file__).resolve().parent
host = os.environ['M2']
token = uuid.uuid4().hex
source = Path(a.worktree).resolve()
label = re.sub(r'[^A-Za-z0-9_.-]', '-', source.name)[:40]
candidate = 'cand-' + label + '-' + hashlib.sha256(str(source).encode()).hexdigest()[:10]
ssh = ['ssh', '-o', 'ConnectTimeout=15', host]

def remote(command):
    return subprocess.check_output(ssh + [command], text=True, timeout=60)

# Absolute, because quoted paths and argv lists never expand ~.
root = remote('cd && pwd').strip() + '/lab/ultra-m2.noindex'
upload = f'{root}/uploads/{token}'

if not a.baseline:
    print('Waiting for the M2 8ae6cf17b forces baseline', flush=True)
    while remote(f'if [ -f {root}/BASE_READY ]; then sed -n \'s/^commit //p\' {root}/BASE_READY; fi').strip() != '8ae6cf17bef6a6084f4f0d12fa6aa5705dd73374':
        time.sleep(30)

stage = Path('/tmp/openmm-metal-bench') / f'ultra-m2-transfer-{token}'
try:
    subprocess.run([str(here / 'sync.sh'), a.worktree, str(stage)], check=True)
    archive = stage / 'src.tar.gz'
    subprocess.run(['tar', '-czf', str(archive), '-C', str(stage), 'src', 'blobs.txt'], check=True)
    remote('mkdir -p ' + shlex.quote(upload))
    # Install the helpers atomically; the entrypoint also works after an initial tools install.
    for name in ['m2-lease.sh', 'cutoff_pairs.py', 'm2summary.py']:
        subprocess.run(['rsync', str(here / name), f'{host}:{upload}/{name}'], check=True)
        remote(f'cp {upload}/{name} {root}/tools/{name}.{token} && chmod +x {root}/tools/{name}.{token} && mv {root}/tools/{name}.{token} {root}/tools/{name}')
    subprocess.run(['rsync', '--partial', str(archive), f'{host}:{upload}/src.tar.gz'], check=True)
    command = ['/opt/homebrew/bin/python3', f'{root}/tools/locked.py', f'{root}/job.lock',
               f'{root}/tools/m2-run.sh', upload, 'base' if a.baseline else candidate,
               '-r', str(a.r), '-s', str(a.s), '-t', a.t]
    body = shlex.join(command) + '; rc=$?; echo "$rc" > ' + shlex.quote(upload + '/exit')
    launch = 'nohup /bin/sh -c ' + shlex.quote(body) + ' > ' + shlex.quote(upload + '/run.log') + ' 2>&1 < /dev/null & echo $!'
    pid = remote('/bin/sh -c ' + shlex.quote(launch)).strip()
    print(f'M2 pid={pid} log={upload}/run.log', flush=True)
    last = ''
    while True:
        result = remote('if [ -f ' + upload + '/exit ]; then cat ' + upload + '/exit; fi').strip()
        if result:
            print(remote('tail -40 ' + upload + '/run.log'), flush=True)
            raise SystemExit(int(result))
        line = remote('tail -1 ' + upload + '/run.log').strip()
        if line != last:
            print(line, flush=True)
            last = line
        time.sleep(30)
finally:
    shutil.rmtree(stage)
