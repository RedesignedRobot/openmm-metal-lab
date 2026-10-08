#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
[ -f "$root/READY" ] || { echo 'READY missing'; exit 2; }
[ -f "$lane/BUILT" ] || { echo 'candidate BUILT missing'; exit 2; }
"$root/ultra-tools/gate.sh" --quick "$lane"
"$lane/screen.sh" maxbits-screen-small 2 15 gbsa,rf,pme,amber20-dhfr
"$lane/screen.sh" maxbits-screen-apoa1 2 15 apoa1rf,apoa1pme,apoa1ljpme
"$lane/screen.sh" maxbits-screen-cellulose 2 15 amber20-cellulose
"$lane/screen.sh" maxbits-screen-stmv 2 15 amber20-stmv
printf '%s\n' 'MAX_BITS SCREEN COMPLETE' > "$lane/maxbits-screen.verdict"
