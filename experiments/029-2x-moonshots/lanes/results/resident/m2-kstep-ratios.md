M2 k-step, 2x15 s. OpenCL ratios derived from the independent infra 3x30 s denominator session, not a paired candidate/OpenCL session.

| Test | Precision | / ultra-int028 Metal | / ultra-int028 OpenCL single (derived) | Raw outdir |
|---|---|---:|---:|---|
| gbsa | single | 1.0683 | 1.2966 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| gbsa | mixed | 1.0884 | 1.0913 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| rf | single | 0.9954 | 1.1480 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| rf | mixed | 0.9987 | 0.9129 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| pme | single | 0.9989 | 1.2283 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| pme | mixed | 1.0033 | 1.0121 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| amber20-dhfr | single | 1.0014 | 1.1979 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |
| amber20-dhfr | mixed | 1.0017 | 0.9755 | `~/lab/ultra-m2.noindex/checks/20260926T190850Z-7484d7bef` |

Denominator raw: `~/lab/ultra-m2.noindex/denominator-20260926T172150Z`. Infra verdict: `PASS 81/81 results wall=3799.1s`.
