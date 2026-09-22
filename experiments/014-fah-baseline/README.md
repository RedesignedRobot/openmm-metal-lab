# 014 Folding@home work unit baseline on the M2

## Question

What do the three FAHBench work units run at on the M2 today, and how close is each platform to Reference? These are the numbers a Metal platform has to beat.

## Method

`fahwu.py <wu> <platform> <precision> 60`, driven by `run.sh`, one job at a time on an otherwise idle mini.

- Work units: FoldingAtHome/fah-bench `workunits/` (dhfr-implicit, dhfr, nav), states loaded with the pre-7.0 root tag renamed to `<State>`.
- Speed: host wall clock over whole steps, 200 warm-up steps, then blocks of 100 steps each closed by an energy read, for 60 s.
- Agreement: forces and potential energy at the start state against Reference (double), as FAHBench checks.
- Machine: Mac mini M2 (10 GPU cores, 8 GB), macOS 27.0 (26A428). OpenMM 8.6 from `~/lab/venv`.

## Result

Clock: host wall, whole steps.

| Work unit | Atoms | Integrator | OpenCL single ns/day | CPU ns/day | OpenCL rel. force error | OpenCL rel. energy error |
| --- | --- | --- | --- | --- | --- | --- |
| dhfr-implicit | 2,489 | Verlet 2 fs | 192.0 | 18.2 | 2.5e-5 | 1.0e-6 |
| dhfr (PME) | 23,558 | Verlet 2 fs | 68.4 | 19.8 | 1.2e-6 | 1.8e-6 |
| nav (PME, barostat) | 173,112 | Langevin 2 fs | 10.95 | 1.49 | 1.8e-6 | 4.2e-7 |

Raw: `results-m2-20260922T221326Z.jsonl`.

On the M2, OpenCL `mixed` and `double` fail with "No compatible OpenCL platform is available": the device has no `cl_khr_fp64`, and OpenCLContext refuses mixed without it.

## What it changes

Folding@home GPU cores run `mixed` (core22 announcements, `<precision v="mixed"/>` in core.xml, FAH staff Dec 2025: "all GPU folding cores ... use [FP64] for some critical calculations"). So the OpenCL numbers above are for a mode Folding@home does not run. A Metal platform that only does single precision does not unblock Folding@home. Mixed precision without fp64 hardware is the problem to solve; experiment 015 measures what it costs.
