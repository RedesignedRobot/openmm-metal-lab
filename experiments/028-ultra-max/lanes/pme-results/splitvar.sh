#!/bin/sh
# usage: splitvar.sh   Reassigned 23:30Z to fold duplicate screens: this ticket now runs cand3screen.sh part 1, cand3
# (5bfc934b6, the production split pass plus force fold) against cand2 on pme, apoa1pme, apoa1ljpme and amber20-dhfr
# single, 2 x 15 s. The lab-tree split probe it used to run asks the same question of the same code in knob form.
exec /bin/sh /tmp/openmm-metal-bench/ultra-pme/cand3screen.sh 1
