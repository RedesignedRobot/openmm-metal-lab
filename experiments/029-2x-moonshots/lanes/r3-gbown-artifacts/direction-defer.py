"""Sleep without a lease, then start the guarded diagnostic after the night slot."""
from datetime import datetime, timezone
import os
import time

target = datetime(2026, 9, 28, 7, 5, tzinfo=timezone.utc).timestamp()
delay = max(0, target-time.time())
print(f'No build or lease until 2026-09-28T07:05:00Z; waiting {delay:.0f} seconds.', flush=True)
time.sleep(delay)
script = '/tmp/openmm-metal-bench/ultra-r3-gbown-probe/tools/run-after0700.sh'
os.execv('/bin/sh', ['/bin/sh', script])
