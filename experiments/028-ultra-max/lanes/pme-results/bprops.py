"""Run benchmark.py with extra platform properties from EXTRA_PROPS ("Name=value,Name=value")."""
import os, sys, runpy
import openmm as mm

extra = dict(kv.split('=', 1) for kv in os.environ.get('EXTRA_PROPS', '').split(',') if kv)
if extra:
    original = mm.Context.__init__
    def patched(self, system, integrator, *args):
        args = list(args)
        if len(args) == 1:
            args.append({})
        if len(args) >= 2:
            args[1] = {**args[1], **extra}
        original(self, system, integrator, *args)
    mm.Context.__init__ = patched
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
