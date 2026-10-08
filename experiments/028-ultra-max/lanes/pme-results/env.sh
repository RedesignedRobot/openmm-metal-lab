#!/bin/sh
# usage: env.sh ROOT script.py args...   ROOT is a build.sh tree (venv) or the lab tree (build/python + prefix).
# Never waits for builds (RULES bans build waits inside a hold). Logs load and top processes to stderr, then runs at nice 0.
R=$1; shift
if [ "$(ps -o nice= -p $$ | tr -d ' ')" != "0" ]; then echo "refusing: nice is not 0" >&2; exit 3; fi
echo "load $(sysctl -n vm.loadavg) at $(date -u +%H:%M:%SZ)" >&2
ps -axo pcpu,command -r | head -5 | cut -c1-120 >&2
unset PYTHONPATH
if [ -x $R/venv/bin/python ]; then exec $R/venv/bin/python "$@"; fi
export PYTHONPATH=$(ls -d $R/build/python/build/lib*)
export DYLD_LIBRARY_PATH=$R/prefix/lib
export OPENMM_PLUGIN_DIR=$R/prefix/lib/plugins
exec /tmp/openmm-metal-bench/env/bin/python "$@"
