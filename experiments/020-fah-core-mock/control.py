"""Control for mockcore.py's restart continuity: does a platform other than Metal continue bit for bit
after a checkpoint restart?

usage: python control.py <wu-dir> <platform> <precision> <steps> <checkpoint-interval>
Runs mockcore's uninterrupted and bin-restart runs, and the fresh-Context force comparison, on the
given platform with only the Precision property, and prints one JSON line.
"""
import json
import sys

import openmm as mm

import mockcore


class ControlWorkUnit(mockcore.WorkUnit):
    def __init__(self, path, platform, precision):
        super().__init__(path)
        self.platform, self.precision = platform, precision

    def context(self, platform=None, properties=None, fresh_system=False):
        return super().context(self.platform, {"Precision": self.precision}, fresh_system)


def main():
    wu_dir, platform, precision = sys.argv[1:4]
    steps, interval = int(sys.argv[4]), int(sys.argv[5])
    wu = ControlWorkUnit(wu_dir, platform, precision)
    uninterrupted, fresh_forces = mockcore.run_uninterrupted(wu, steps, interval)
    binary = mockcore.run_binary_restarted(wu, steps, interval)
    print(json.dumps({"wu": wu.name, "platform": platform, "precision": precision, "steps": steps,
                      "checkpoint_interval": interval, "fresh_context_forces": fresh_forces,
                      "bin_restart_vs_uninterrupted": mockcore.compare(uninterrupted, binary),
                      "openmm": mm.version.full_version}))


if __name__ == "__main__":
    main()
