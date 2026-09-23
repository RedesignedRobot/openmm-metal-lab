#!/bin/sh
# Build and test the saturating fixed-point fix on the Mac Studio, then time it against its base.
# Every step holds the Studio's OpenMM lease on its own, so no single hold runs long.
# Layout under $B: src/{base,fix,oclfix} are `git archive` exports with commit.txt; v/<variant> gets
# build/ and prefix/, plus python.sh for Metal variants (module built, never installed, so no shared
# env changes). Tools (cmake, ninja, swig) and Python come from the Studio's shared env, read only.
set -u
B=/tmp/openmm-metal-bench/021
ENV=/tmp/openmm-metal-bench/env
export PATH=$ENV/bin:$PATH
cd $B

leased() {
    what=$1; shift
    until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
    echo "largeforces $(date -u +%H:%MZ) $what" > /tmp/openmm-lease/owner
    echo "== lease taken $(date -u +%H:%M:%SZ) $what"
    "$@"
    status=$?
    rm -rf /tmp/openmm-lease
    echo "== lease released $(date -u +%H:%M:%SZ) $what exit $status"
    return $status
}

configure() {   # <variant> <opencl ON|OFF> <tests ON|OFF>
    cmake -S $B/src/$1 -B $B/v/$1/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_INSTALL_PREFIX=$B/v/$1/prefix -DPYTHON_EXECUTABLE=$ENV/bin/python \
        -DOPENMM_BUILD_OPENCL_LIB=$2 -DOPENMM_BUILD_CUDA_LIB=OFF -DBUILD_TESTING=$3 > $B/v/$1/configure.log 2>&1
}

build_metal() {   # <variant> <tests ON|OFF>
    mkdir -p $B/v/$1
    configure $1 OFF $2 &&
    ninja -C $B/v/$1/build -j 16 > $B/v/$1/build.log 2>&1 &&
    ninja -C $B/v/$1/build install > $B/v/$1/install.log 2>&1 &&
    (cd $B/v/$1/build/python && cmake -P $B/v/$1/build/wrappers/python/pysetupbuild.cmake) > $B/v/$1/pythonbuild.log 2>&1 || return 1
    site=$(dirname "$(dirname "$(find $B/v/$1/build/python/build -maxdepth 3 -name "_openmm*.so" | head -1)")")
    printf '#!/bin/sh\nPYTHONPATH="%s" exec "%s" "$@"\n' "$site" "$ENV/bin/python" > $B/v/$1/python.sh
    chmod +x $B/v/$1/python.sh
    $B/v/$1/python.sh -c "import openmm, openmm.version as v; print(openmm.__file__, v.openmm_library_path, [openmm.Platform.getPlatform(i).getName() for i in range(openmm.Platform.getNumPlatforms())])"
}

build_opencl_tests() {   # <variant>
    mkdir -p $B/v/$1
    configure $1 ON ON &&
    ninja -C $B/v/$1/build -j 16 TestOpenCLLocalEnergyMinimizer TestOpenCLCustomCentroidBondForce TestOpenCLATMForce > $B/v/$1/build.log 2>&1
}

metal_ctest() {   # <Single|Mixed>
    (cd $B/v/fix/build && ctest -R "^TestMetal.*$1\$" -j 4 --timeout 1500 --output-on-failure > $B/ctest-metal-$1.log 2>&1)
    tail -6 $B/ctest-metal-$1.log
}

opencl_ctest() {
    (cd $B/v/oclfix/build && for r in 1 2 3; do ctest -R "^TestOpenCL(LocalEnergyMinimizer|CustomCentroidBondForce|ATMForce)Single\$" --output-on-failure; done > $B/ctest-opencl.log 2>&1)
    grep -E "tests passed|Passed|Failed" $B/ctest-opencl.log
}

timing() {
    for round in 1 2; do
        order="base fix"; [ $round = 2 ] && order="fix base"
        for wu in dhfr nav; do
            for v in $order; do
                line=$($B/v/$v/python.sh $B/lane/fahwu.py $B/fah-wu/$wu Metal single 30 2>>$B/timing.err)
                echo "{\"round\": $round, \"variant\": \"$v\", \"commit\": \"$(cat $B/src/$v/commit.txt)\", \"wu\": \"$wu\", \"result\": $line}" | tee -a $B/timing.jsonl
            done
        done
    done
}

step=${1:-all}
case $step in
all)
    leased "021 build base (Metal, no tests)" build_metal base OFF || exit 1
    leased "021 build fix (Metal + tests)" build_metal fix ON || exit 1
    leased "021 build oclfix (OpenCL tests)" build_opencl_tests oclfix || exit 1
    leased "021 ctest Metal Single" metal_ctest Single
    leased "021 ctest Metal Mixed" metal_ctest Mixed
    leased "021 ctest OpenCL minimizer/centroid/ATM x3" opencl_ctest
    leased "021 timing dhfr+nav base vs fix" timing
    echo LANE-DONE
    ;;
*)
    "$@"
    ;;
esac
