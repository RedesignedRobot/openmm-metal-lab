#!/bin/sh
# Summarize probe 1a's records (no GPU).
L=/tmp/openmm-metal-bench/ultra-atomics
O=$L/p1a/out
for f in $O/*.rec; do
  tag=$(basename $f .rec)
  $L/venv/bin/python $L/p1a/summarize.py $O/$tag.txt $f 12 > $O/$tag.sum 2>&1
  gzip -f $f
done
echo summarized
