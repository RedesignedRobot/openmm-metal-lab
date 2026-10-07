Host clock; confirmed 3x30 s per arm. Ratios use medians. All retained rounds have zero missing results and zero build overlap.

| Test | Precision | Candidate ns/day | / int028 Metal | / int028 OpenCL single | Raw ab.sh outdir |
|---|---|---:|---:|---:|---|
| gbsa | single | 1603.03 | 0.9993 | 1.3756 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-gbsa |
| gbsa | mixed | 1236.36 | 0.9996 | 1.0609 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-gbsa |
| rf | single | 1450.17 | 1.1881 | 2.1896 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-rf |
| rf | mixed | 1181.01 | 1.1529 | 1.7832 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-rf |
| pme | single | 986.95 | 1.0899 | 1.8966 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-pme |
| pme | mixed | 854.12 | 1.0774 | 1.6413 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-pme |
| apoa1rf | single | 456.80 | 1.1040 | 1.6295 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1rf |
| apoa1rf | mixed | 384.76 | 1.0808 | 1.3725 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1rf |
| apoa1pme | single | 307.47 | 1.0158 | 1.7003 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1pme |
| apoa1pme | mixed | 272.75 | 1.0164 | 1.5083 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1pme |
| apoa1ljpme | single | 239.32 | 1.0003 | 1.8757 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1ljpme |
| apoa1ljpme | mixed | 217.67 | 1.0046 | 1.7060 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-apoa1ljpme |
| amber20-dhfr | single | 1015.88 | 1.0854 | 1.8030 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-dhfr |
| amber20-dhfr | mixed | 865.97 | 1.0793 | 1.5369 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-dhfr |
| amber20-cellulose | single | 81.95 | 0.9990 | 1.7109 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-cellulose |
| amber20-cellulose | mixed | 74.55 | 1.0001 | 1.5564 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-cellulose |
| amber20-stmv | single | 30.19 | 0.9987 | 1.6305 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-stmv-single |
| amber20-stmv | mixed | 27.61 | 0.9978 | 1.4914 | ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-stmv-mixed; ~/code/metal/bench.noindex/ultra-m29-nonbonded/maxbits-confirm-amber20-stmv-single |
