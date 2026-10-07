import datetime, os, select, signal, sys
pid = int(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
stop = (now+datetime.timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
kq = select.kqueue()
try:
    kq.control([select.kevent(pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 0, 0)
except ProcessLookupError:
    sys.exit(0)
remaining = max(0, (stop-now).total_seconds()-1)
if kq.control(None, 1, remaining):
    print("screen launcher finished before cutoff", flush=True)
elif os.path.exists(f"/tmp/openmm-lease/members/{pid}"):
    print("hold started before midnight; allow completion", flush=True)
else:
    os.kill(pid, signal.SIGTERM)
    print("night cutoff: canceled this lane's unstarted screen ticket; requeue after 07:00Z", flush=True)
