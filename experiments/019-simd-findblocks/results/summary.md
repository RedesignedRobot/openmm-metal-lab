| Test | Precision | Before ns/day median (min-max, n) | After ns/day median (min-max, n) | After/before |
| :--- | :--- | ---: | ---: | ---: |
| amber20-cellulose | mixed |     8.12 (8.10-8.14, n=3) |     9.15 (9.15-9.16, n=3) | 1.127 |
| amber20-cellulose | single |    10.51 (10.51-10.51, n=3) |    12.30 (12.25-12.30, n=3) | 1.170 |
| apoa1pme | mixed |    35.04 (35.01-35.05, n=3) |    39.98 (39.86-39.99, n=3) | 1.141 |
| apoa1pme | single |    46.98 (46.96-47.04, n=3) |    56.11 (56.10-56.16, n=3) | 1.195 |
| apoa1rf | mixed |    38.98 (38.97-39.00, n=3) |    45.13 (45.12-45.20, n=3) | 1.158 |
| apoa1rf | single |    58.83 (58.81-58.88, n=3) |    73.98 (73.92-73.98, n=3) | 1.257 |
| pme | mixed |   134.75 (134.74-134.90, n=3) |   142.55 (142.51-142.93, n=3) | 1.058 |
| pme | single |   199.69 (199.44-200.16, n=3) |   217.15 (216.77-217.24, n=3) | 1.087 |
| fah-dhfr | mixed |    54.50 (54.47-54.59, n=3) |    55.64 (55.61-55.80, n=3) | 1.021 |
| fah-dhfr | single |    81.57 (81.52-82.19, n=3) |    84.72 (84.56-86.00, n=3) | 1.039 |
| fah-nav | mixed |     8.49 (8.49-8.49, n=3) |     9.11 (9.10-9.11, n=3) | 1.073 |
| fah-nav | single |    11.27 (11.27-11.27, n=3) |    12.38 (12.37-12.39, n=3) | 1.098 |

| Test | Precision | Install | ms/step (host wall) | findBlocks ms/step (GPU) | findBlocks share | Rebuild fraction | Rebuild ms | Skip ms |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| amber20-cellulose | mixed | after | 37.608 | 4.331 | 11.5% | 0.501 | 8.710 | 0.004 |
| amber20-cellulose | mixed | before | 42.547 | 9.206 | 21.6% | 0.501 | 18.361 | 0.004 |
| amber20-cellulose | single | after | 28.004 | 4.328 | 15.5% | 0.501 | 8.702 | 0.004 |
| amber20-cellulose | single | before | 32.877 | 9.212 | 28.0% | 0.501 | 18.376 | 0.004 |
| apoa1pme | mixed | after | 8.570 | 0.862 | 10.1% | 0.498 | 1.726 | 0.004 |
| apoa1pme | mixed | before | 9.834 | 2.009 | 20.4% | 0.496 | 4.042 | 0.004 |
| apoa1pme | single | after | 6.120 | 0.855 | 14.0% | 0.498 | 1.712 | 0.004 |
| apoa1pme | single | before | 7.273 | 2.023 | 27.8% | 0.499 | 4.049 | 0.004 |
| apoa1rf | mixed | after | 7.563 | 0.888 | 11.7% | 0.457 | 1.934 | 0.004 |
| apoa1rf | mixed | before | 8.681 | 1.943 | 22.4% | 0.444 | 4.366 | 0.004 |
| apoa1rf | single | after | 4.601 | 0.870 | 18.9% | 0.447 | 1.940 | 0.003 |
| apoa1rf | single | before | 5.686 | 1.958 | 34.4% | 0.449 | 4.353 | 0.003 |
| pme | mixed | after | 2.436 | 0.200 | 8.2% | 0.498 | 0.398 | 0.003 |
| pme | mixed | before | 2.572 | 0.338 | 13.1% | 0.501 | 0.671 | 0.003 |
| pme | single | after | 1.602 | 0.203 | 12.7% | 0.500 | 0.402 | 0.004 |
| pme | single | before | 1.727 | 0.337 | 19.5% | 0.501 | 0.668 | 0.003 |
