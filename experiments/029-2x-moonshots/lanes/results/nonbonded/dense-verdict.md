# Dense force blocks: DEAD

Two 15 s rounds, single precision. Cellulose has no build overlap. The second STMV dense round overlapped a build; its two rounds agree within 0.1%.

| Test | Dense ns/day | / int028 | / MAX_BITS 0 | / int028 OpenCL single | Raw ab.sh outdir |
|---|---:|---:|---:|---:|---|
| apoa1rf | 104.605 | 0.2530 | 0.2282 | 0.3720 | /tmp/openmm-metal-bench/ultra-m29-nonbonded/blocks-screen-apoa1rf |
| amber20-cellulose | 26.863 | 0.3272 | 0.3381 | 0.5618 | /tmp/openmm-metal-bench/ultra-m29-nonbonded/blocks-screen-amber20-cellulose |
| amber20-stmv | 5.506 | 0.1816 | 0.1817 | 0.2968 | /tmp/openmm-metal-bench/ultra-m29-nonbonded/blocks-screen-amber20-stmv |

Neither large target reaches the required 1.10x int028. No confirmation run is justified for this design. The default must retain the old path.
