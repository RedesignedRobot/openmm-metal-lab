"""Run one timed workload with OPENMM_METAL_PROFILE set and print one JSON line joining its
result with the platform's profile summary.

usage: profrun.py <variant-python> <variant-label> <workload> <precision> <mode> [seconds] [platform]
  <variant-python>  a python.sh made by build.sh
  <workload>        a FAHBench work unit directory, run by 017's fahwu.py, or bench:<test>, run by
                    OpenMM's examples/benchmarks/benchmark.py from the directory in BENCHMARKS
  <mode>            0 (profiling off), 1 (census) or kernels (one command buffer per dispatch)
  [platform]        Metal (default) or OpenCL
Both scripts time with the host wall clock over whole steps. fahwu.py builds three contexts and
benchmark.py one, and only the timed context takes steps, so there is at most one profile line.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FAHWU = os.path.join(HERE, "..", "017-three-chips", "fahwu.py")
BENCHMARKS = os.environ.get("BENCHMARKS", "/tmp/openmm-metal-perf/benchmarks")


def fahwu(python, wu, platform, precision, seconds, env):
    run = subprocess.run([python, FAHWU, wu, platform, precision, seconds], env=env, capture_output=True, text=True)
    return run, (json.loads(run.stdout) if run.returncode == 0 else None)


def benchmark(python, test, platform, precision, seconds, env):
    with tempfile.TemporaryDirectory() as tmp:
        outfile = os.path.join(tmp, "result.json")
        run = subprocess.run([python, "benchmark.py", f"--platform={platform}", f"--precision={precision}",
                              f"--test={test}", f"--seconds={seconds}", f"--outfile={outfile}"],
                             cwd=BENCHMARKS, env=env, capture_output=True, text=True)
        if run.returncode != 0 or not os.path.exists(outfile):
            return run, None
        r = json.load(open(outfile))["benchmarks"][0]
    return run, {"wu": f"bench-{test}", "platform": platform, "precision": precision, "ns_per_day": r["ns_per_day"],
                 "steps": r["steps"], "wall_s": r["elapsed_time"], "clock": "host wall (benchmark.py datetime), whole steps"}


def main():
    python, label, workload, precision, mode = sys.argv[1:6]
    seconds = sys.argv[6] if len(sys.argv) > 6 else "60"
    platform = sys.argv[7] if len(sys.argv) > 7 else "Metal"
    env = dict(os.environ, OPENMM_METAL_PROFILE=mode)
    if workload.startswith("bench:"):
        run, result = benchmark(python, workload[len("bench:"):], platform, precision, seconds, env)
    else:
        run, result = fahwu(python, workload, platform, precision, seconds, env)
    if result is None:
        sys.exit(f"{workload} failed: {run.stderr[-4000:]}")
    profiles = [json.loads(line.split(" ", 1)[1]) for line in run.stderr.splitlines()
                if line.startswith("OPENMM_METAL_PROFILE ")]
    if platform == "Metal" and mode != "0" and len(profiles) != 1:
        sys.exit(f"expected one profile line, got {len(profiles)}: {run.stderr[-4000:]}")
    print(json.dumps({"variant": label, "mode": mode, "run": result, "profile": profiles[0] if profiles else None}))


if __name__ == "__main__":
    main()
