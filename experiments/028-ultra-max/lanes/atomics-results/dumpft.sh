#!/bin/sh
# One lease: force dump for base and words, then the force-eval timing screen.
L=/tmp/openmm-metal-bench/ultra-atomics
$L/dumprun.sh base words
$L/ft.sh $L/ft-words.txt 2 single 300 pme,apoa1pme,apoa1rf,gbsa,rf base words lo
