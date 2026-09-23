# Experiment 018 results

ns/day from OpenMM's unmodified benchmark.py (f9347f6c5). Clock: benchmark.py's host wall clock, 60 s per test, one run per configuration. Ratios over OpenCL single; Apple's OpenCL has no mixed precision, so Metal mixed over OpenCL single is the comparison at Folding@home's precision.

## Apple M2 (10 GPU cores), Mac mini

| Test | Metal single | Metal mixed | OpenCL single | CPU | Metal single / OpenCL | Metal mixed / OpenCL |
|---|---|---|---|---|---|---|
| gbsa | 386.3 | 290.5 | 381.3 | 36.2 | 1.01 | 0.76 |
| rf | 254.1 | 147.0 | 255.5 | 29.1 | 0.99 | 0.58 |
| pme | 200.0 | 134.7 | 197.0 | 29.0 | 1.01 | 0.68 |
| apoa1rf | 58.8 | 39.0 | 59.1 | 7.9 | 0.99 | 0.66 |
| apoa1pme | 47.0 | 35.0 | 46.0 | 7.6 | 1.02 | 0.76 |
| apoa1ljpme | 33.9 | 26.7 | 33.9 | 6.7 | 1.00 | 0.79 |
| amber20-dhfr | 214.2 | 139.9 | 210.5 | 30.4 | 1.02 | 0.66 |
| amber20-cellulose | 10.5 | 8.1 | 10.3 | 1.7 | 1.02 | 0.79 |
| amber20-stmv | 3.8 | 3.0 | 3.7 | 0.6 | 1.03 | 0.81 |

## Apple M3 Pro (18 GPU cores), MacBook Pro

| Test | Metal single | Metal mixed | OpenCL single | CPU | Metal single / OpenCL | Metal mixed / OpenCL |
|---|---|---|---|---|---|---|
| gbsa | 748.8 | 589.0 | 741.5 | 58.9 | 1.01 | 0.79 |
| rf | 466.1 | 301.7 | 454.8 | 45.7 | 1.02 | 0.66 |
| pme | 358.2 | 256.2 | 358.0 | 43.5 | 1.00 | 0.72 |
| apoa1rf | 116.6 | 82.7 | 116.0 | 12.8 | 1.01 | 0.71 |
| apoa1pme | 92.2 | 70.4 | 90.7 | 12.3 | 1.02 | 0.78 |
| apoa1ljpme | 65.6 | 52.5 | 65.6 | 10.8 | 1.00 | 0.80 |
| amber20-dhfr | 386.1 | 266.5 | 380.0 | 45.3 | 1.02 | 0.70 |
| amber20-cellulose | 19.8 | 15.2 | 18.8 | 2.7 | 1.05 | 0.81 |
| amber20-stmv | 7.1 | 5.9 | 6.6 | 0.9 | 1.07 | 0.89 |

## Apple M3 Ultra (60 GPU cores), Mac Studio

| Test | Metal single | Metal mixed | OpenCL single | CPU | Metal single / OpenCL | Metal mixed / OpenCL |
|---|---|---|---|---|---|---|
| gbsa | 1182.1 | 791.1 | 1169.3 | 71.0 | 1.01 | 0.68 |
| rf | 710.2 | 475.8 | 664.7 | 56.8 | 1.07 | 0.72 |
| pme | 536.3 | 374.5 | 518.0 | 49.9 | 1.04 | 0.72 |
| apoa1rf | 288.3 | 210.3 | 279.6 | 20.4 | 1.03 | 0.75 |
| apoa1pme | 183.6 | 148.0 | 180.6 | 17.6 | 1.02 | 0.82 |
| apoa1ljpme | 127.8 | 108.5 | 127.0 | 15.5 | 1.01 | 0.85 |
| amber20-dhfr | 581.9 | 392.9 | 563.1 | 51.0 | 1.03 | 0.70 |
| amber20-cellulose | 48.4 | 40.6 | 47.7 | 5.6 | 1.01 | 0.85 |
| amber20-stmv | 18.5 | 15.8 | 18.6 | 1.7 | 1.00 | 0.85 |

