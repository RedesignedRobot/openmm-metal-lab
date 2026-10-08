M2 full prototype, 2x15 s. OpenCL ratios are derived from infra's separate 3x30 s frozen-baseline denominator.

| Test | Precision | Metal ns/day | / ultra-int028 Metal | / ultra-int028 OpenCL single (derived) | Raw M2 outdir |
|---|---|---:|---:|---:|---|
| gbsa | single | 484.834 | 1.0674 | 1.2955 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| gbsa | mixed | 410.080 | 1.0894 | 1.0923 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| rf | single | 291.620 | 0.9996 | 1.1529 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| rf | mixed | 230.207 | 0.9936 | 0.9083 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| pme | single | 238.981 | 0.9976 | 1.2267 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| pme | mixed | 195.083 | 0.9938 | 1.0026 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| amber20-dhfr | single | 248.111 | 0.9992 | 1.1953 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |
| amber20-dhfr | mixed | 200.379 | 0.9941 | 0.9681 | `~/lab/ultra-m2.noindex/checks/20260926T202041Z-7484d7bef` |

Denominator raw: `~/lab/ultra-m2.noindex/denominator-20260926T172150Z`. Infra verdict: `PASS 81/81 results wall=3799.1s`.
