"""Merge forces.py --md tables from several seeds into one baseline: per row, the worst rel|dF|, max|dF|
and rel|dE| over the seeds. Prints the table in forces.py's format.
usage: python md100-baseline.py <table>...
"""
import os
import sys

worst = {}
header = None
for path in sys.argv[1:]:
    rows = 0
    for line in open(path):
        fields = line.split()
        if fields and fields[0] == "test":
            header = line.rstrip("\n")
        if len(fields) != 6 or fields[0] in ("test", "#"):
            continue
        key = (fields[0], fields[1], fields[2])
        values = [float(v) for v in fields[3:]]
        worst[key] = [max(a, b) for a, b in zip(worst.get(key, values), values)]
        rows += 1
    if rows != 12:
        sys.exit(f"{path} has {rows} rows, not 12")
print(header)
for (test, atoms, precision), (rel_force, max_force, rel_energy) in worst.items():
    print(f"{test:12} {int(atoms):7d} {precision:>9} {rel_force:10.3e} {max_force:10.3e} {rel_energy:10.3e}")
print(f"# per-row worst of {len(sys.argv)-1} md100 tables: {' '.join(os.path.basename(p) for p in sys.argv[1:])}")
