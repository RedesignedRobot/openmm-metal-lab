#!/bin/sh
# Studio, one lease.sh timing hold: ab.sh screen9, integrated base b69efb0fe against i-wf, i-wfcap and
# i-wfk on gbsa, rf and pme, single and mixed. infra rebuilds ultra-integrated to 89d7f17fc (f1), so
# base loads the b69efb0fe platform plugins snapshotted in plugins-int-b69 through OPENMM_PLUGIN_DIR.
# f1 changes only plugin sources, so the core libs under ultra-integrated/prefix still match. One test per
# call, so --rerun-builds can rerun every (round, test) and still end under the 20 minute cap.
# usage: screen9.sh <test>
set -eu
test="$1"
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-dispatch
PLUGINS=$D/plugins-int-b69
PLUGINS_MD5=0137cb38f26be36bbff53e96aadc1a02
[ "$(md5 -q $PLUGINS/libOpenMMMetal.dylib)" = $PLUGINS_MD5 ] || { echo "plugins-int-b69 changed"; exit 1; }
CORE=/tmp/openmm-metal-bench/ultra-integrated/prefix/lib/libOpenMM.dylib
[ "$(md5 -q $CORE)" = a1f4e8b55f01c16ffb7755bce4a285c6 ] || { echo "ultra-integrated libOpenMM changed"; exit 1; }
# int-b69/venv links to ultra-integrated/venv. ab.sh checks BUILT against src for a build.sh tree, and
# infra synced f1 into ultra-integrated/src before building it, so base goes through a path that is not one.
PB=$D/int-b69/venv/bin/python
OPENMM_PLUGIN_DIR=$PLUGINS $PB -c "import openmm as mm; assert not mm.Platform.getPluginLoadFailures(), mm.Platform.getPluginLoadFailures(); mm.Platform.getPlatformByName(\"Metal\")" \
    || { echo "base cannot load Metal from plugins-int-b69"; exit 1; }
echo "base plugins-int-b69 md5 $PLUGINS_MD5, core libs from ultra-integrated/prefix: $(head -1 /tmp/openmm-metal-bench/ultra-integrated/BUILT)"
PBS=$PB:Metal:single:OPENMM_PLUGIN_DIR=$PLUGINS
PBM=$PB:Metal:mixed:OPENMM_PLUGIN_DIR=$PLUGINS
P1=$D/i-wf/venv/bin/python; P2=$D/i-wfcap/venv/bin/python; P3=$D/i-wfk/venv/bin/python
exec $T/ab.sh --rerun-builds $D/screen9-$test 2 15 $test base=$PBS wf=$P1:Metal:single wfcap=$P2:Metal:single wfk=$P3:Metal:single base-mixed=$PBM wf-mixed=$P1:Metal:mixed wfcap-mixed=$P2:Metal:mixed wfk-mixed=$P3:Metal:mixed
