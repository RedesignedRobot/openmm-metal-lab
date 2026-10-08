#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
T=/tmp/openmm-metal-bench/ultra-tools
. "$T/../hosts.env"
R=$HOME/lab/ultra-m2.noindex/m29-mixed-minimizer-evidence
ssh -o ConnectTimeout=15 "$M2" "mkdir -p $R"
rsync "$D/minimize.py" "$D/minimizer-m2-run.sh" "$D/minimizer-m2-test.sh" "$D/minimizer-m2-round.sh" "$M2:$R/"
# When submitted just after our own standard M2 build, that job already holds
# job.lock through the full nine-test check. Share its installation protection;
# each workload still acquires a separate GPU lease. Otherwise take job.lock.
if [ "${1:-}" = own-check ]; then
    ssh -o ConnectTimeout=15 "$M2" 'test -f $HOME/lab/ultra-m2.noindex/cand-m29-mixed-minimizer-source-b60e2c40f9/BUILT && test ! -f $HOME/lab/ultra-m2.noindex/uploads/bc5d1b6ff3d14a3ba115713107294f69/exit && pgrep -P 24804 >/dev/null && /bin/sh $HOME/lab/ultra-m2.noindex/m29-mixed-minimizer-evidence/minimizer-m2-round.sh'
else
    ssh -o ConnectTimeout=15 "$M2" '/opt/homebrew/bin/python3 $HOME/lab/ultra-m2.noindex/tools/locked.py $HOME/lab/ultra-m2.noindex/job.lock /bin/sh $HOME/lab/ultra-m2.noindex/m29-mixed-minimizer-evidence/minimizer-m2-round.sh'
fi
mkdir -p "$D/minimizer-m2"
rsync -rlpc "$M2:$R/results/" "$D/minimizer-m2/"
rsync "$M2:$R/verdict.txt" "$D/minimizer-m2-verdict.txt"
