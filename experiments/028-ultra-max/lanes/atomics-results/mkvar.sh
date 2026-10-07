#!/bin/sh
# Build lab-only Metal plugin variants in the atomics build.sh tree, then put src back to the commit.
# usage: mkvar.sh VARIANT...
#   p0          71a602b43's nonbonded files (no force words)
#   prof        p0 plus the profiler lane's GpuProf.h hooks
#   prof-lo     prof with a one-atomic atomicAdd (wrong forces)
#   prof-plain  prof with a plain read-modify-write atomicAdd (wrong forces)
#   prof-words  the commit plus the hooks
# Each lands in plugins-VARIANT: the installed plugins with this variant's libOpenMMMetal.dylib.
set -e
L=/tmp/openmm-metal-bench/ultra-atomics
M=$L/src/platforms/metal
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
FILES="include/MetalNonbondedUtilities.h src/MetalNonbondedUtilities.cpp src/kernels/nonbonded.metal src/kernels/common.metal include/MetalQueue.h src/MetalArray.cpp src/MetalContext.cpp src/MetalEvent.cpp src/MetalFFT3D.cpp src/MetalQueue.cpp"
[ -f $L/BUILT ] || { echo "no BUILT in $L"; exit 1; }
[ -f $L/pristine.tar ] || (cd $M && tar cf $L/pristine.tar $FILES)
restore() { cd $M && tar xf $L/pristine.tar && rm -f src/GpuProf.h && touch $FILES; }
trap restore EXIT
for v in "$@"; do
  restore
  case $v in
    p0|prof|prof-lo|prof-plain) cp -R $L/ov/p0/. $M/ ;;
    prof-words) ;;
    *) echo "unknown variant $v"; exit 1 ;;
  esac
  case $v in
    prof*) (cd $L/src && patch -s -p1 < $L/ov/prof.patch) && rm -f $M/src/*.orig $M/include/*.orig && cp $L/ov/GpuProf.h $M/src/ ;;
  esac
  case $v in
    prof-lo) cp $L/ov/common-lo.metal $M/src/kernels/common.metal ;;
    prof-plain) cp $L/ov/common-plain.metal $M/src/kernels/common.metal ;;
  esac
  touch $FILES
  nice -n 10 ninja -C $L/build -j6 OpenMMMetal > $L/logs/var-$v.log 2>&1 || { grep -E "error|FAILED" $L/logs/var-$v.log | head; exit 1; }
  rm -rf $L/plugins-$v && cp -R $L/prefix/lib/plugins $L/plugins-$v && cp $L/build/libOpenMMMetal.dylib $L/plugins-$v/
  echo "$v $(md5 -q $L/plugins-$v/libOpenMMMetal.dylib)"
done
restore
trap - EXIT
nice -n 10 ninja -C $L/build -j6 OpenMMMetal > $L/logs/var-restore.log 2>&1
cmp -s $L/build/libOpenMMMetal.dylib $L/prefix/lib/plugins/libOpenMMMetal.dylib && echo "restored: build matches the installed plugin" || echo "restored: build differs from the installed plugin (link timestamps?)"
