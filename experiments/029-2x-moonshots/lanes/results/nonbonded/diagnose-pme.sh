#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
out=$lane/pme-md100-diagnostic
"$lane/venv/bin/python" "$lane/pme-force-diagnostic.py" capture "$out" candidate
"$lane/venv/bin/python" "$lane/pme-force-diagnostic.py" evaluate "$out" candidate
"$root/ultra-int028/venv/bin/python" "$lane/pme-force-diagnostic.py" evaluate "$out" int028
"$lane/venv/bin/python" "$lane/pme-force-diagnostic.py" evaluate "$out" reference
"$root/env/bin/python" "$lane/summarize-pme-diagnostic.py" "$out" > "$out/comparison.json"
cat "$out/comparison.json"
