#!/usr/bin/env python3
"""tracecmp.py <straight out dir> <killed out dir> [barostat frequency]

Compares the trace.txt that minicore --trace writes for a straight run and a killed-and-restarted run.
For every restart it checks that the state the new process loaded is bit for bit the state the killed
run had at that step, and whether it still equals the straight run there. Then it finds the first step
where the two trajectories differ and which of box, positions and velocities differ first, and
compares the potential energy and temperature averages of the two runs.
"""
import math
import sys


def read_trace(path):
    """Returns (loads, steps): loads is a list of (step, hashes, steps written before this load),
    steps maps step -> (hashes, energy fields) from the last process that wrote that step."""
    loads, steps = [], {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) not in (5, 7) or parts[0] not in ("load", "step"):
                continue  # a line cut off by a kill
            step, hashes = int(parts[1]), tuple(parts[2:5])
            if parts[0] == "load":
                loads.append((step, hashes, dict(steps)))
            else:
                steps[step] = (hashes, tuple(float(x) for x in parts[5:]))
    return loads, steps


def block_stats(values, blocks=10):
    blocks = max(2, min(blocks, len(values) // 2))
    n = len(values) // blocks * blocks
    mean = sum(values) / len(values)
    sd = math.sqrt(sum((v - mean) ** 2 for v in values) / (len(values) - 1))
    size = n // blocks
    means = [sum(values[i * size:(i + 1) * size]) / size for i in range(blocks)]
    bmean = sum(means) / blocks
    se = math.sqrt(sum((m - bmean) ** 2 for m in means) / (blocks - 1) / blocks)
    return mean, sd, se


def main():
    straight_loads, straight = read_trace(sys.argv[1] + "/trace.txt")
    loads, killed = read_trace(sys.argv[2] + "/trace.txt")
    frequency = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    names = ("positions", "velocities", "box")

    for step, hashes, before in loads:
        if step == 0:
            continue
        own = before.get(step, (None,))[0]
        ref = straight.get(step, (None,))[0]
        print("restart at step %d: loaded state %s the killed run's own step %d, %s the straight run" % (
            step, "equals" if hashes == own else "DIFFERS FROM", step,
            "equals" if hashes == ref else "differs from"))

    first = None
    for step in sorted(set(straight) & set(killed)):
        if straight[step][0] != killed[step][0]:
            first = step
            break
    if first is None:
        print("no step differs")
    else:
        restart = max(s for s, _, _ in loads if s < first)
        differ = [names[i] for i in range(3) if straight[first][0][i] != killed[first][0][i]]
        note = ""
        if frequency:
            note = ", a barostat step" if first % frequency == 0 else ", not a barostat step"
        print("first difference at step %d, %d steps after the restart at step %d%s: %s" % (
            first, first - restart, restart, note, ", ".join(differ)))
        box_first = next((s for s in sorted(set(straight) & set(killed))
                          if straight[s][0][2] != killed[s][0][2]), None)
        print("first box difference: %s" % ("none" if box_first is None else "step %d" % box_first))

    for label, trace in (("straight", straight), ("killed", killed)):
        rows = [trace[s][1] for s in sorted(trace) if trace[s][1]]
        pe = block_stats([r[0] for r in rows])
        t = block_stats([r[1] for r in rows])
        print("%-8s %d samples: PE %.1f sd %.1f se %.1f kJ/mol, T %.2f sd %.2f se %.2f K" % (
            label, len(rows), pe[0], pe[1], pe[2], t[0], t[1], t[2]))


if __name__ == "__main__":
    main()
