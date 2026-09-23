#!/bin/sh
# Build one OpenMM variant into its own directory, without touching any shared install or Python env.
# usage: build.sh <source-tree> <variant-dir> <python> <build-python>
#   <source-tree>   a `git archive` export with the commit hash in commit.txt
#   <variant-dir>   gets build/ and prefix/, plus python.sh, which runs <python> with this variant's
#                   Python module first on PYTHONPATH
#   <python>        the interpreter the variant runs under (the Studio's shared env)
#   <build-python>  the interpreter that builds the module: a venv with numpy, Cython and setuptools
#                   at <python>'s versions and NO openmm.  OpenMM's setup.py imports openmm and simtk
#                   from the interpreter it runs under and deletes those installs, even for a plain
#                   `setup.py build`, so building with <python> would wipe the shared env's openmm.
#                   Made once with:
#                     <python> -m venv <build-python-dir>
#                     <build-python-dir>/bin/pip install numpy==2.5.3 cython==3.3.0 setuptools==84.0.0
# cmake, ninja, swig and doxygen come from <python>'s bin directory.
# OPENCL=ON also builds the OpenCL platform; TESTS=OFF skips the C++ tests; JOBS sets ninja's parallelism.
set -eu
src=$1 dir=$2 py=$3 buildpy=$4
if "$buildpy" -c "import openmm" 2>/dev/null || "$buildpy" -c "import simtk" 2>/dev/null; then
    echo "$buildpy can import openmm or simtk; OpenMM's setup.py would delete that install" >&2
    exit 1
fi
PATH=$(dirname "$py"):$PATH
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
cmake -S "$src" -B "$dir/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$dir/prefix" \
  -DPYTHON_EXECUTABLE="$buildpy" \
  -DOPENMM_BUILD_OPENCL_LIB="${OPENCL:-OFF}" -DOPENMM_BUILD_CUDA_LIB=OFF \
  -DBUILD_TESTING="${TESTS:-ON}" > "$dir/configure.log"
ninja -C "$dir/build" -j "${JOBS:-16}" > "$dir/build.log"
ninja -C "$dir/build" install > "$dir/install.log"
(cd "$dir/build/python" && cmake -P "$dir/build/wrappers/python/pysetupbuild.cmake") > "$dir/pythonbuild.log" 2>&1
if grep -q REMOVING "$dir/pythonbuild.log"; then
    echo "setup.py removed an installed openmm; see $dir/pythonbuild.log" >&2
    exit 1
fi
site=$(dirname "$(dirname "$(find "$dir/build/python/build" -maxdepth 3 -name "_openmm*.so" | head -1)")")
cat > "$dir/python.sh" <<EOF
#!/bin/sh
PYTHONPATH="$site" exec "$py" "\$@"
EOF
chmod +x "$dir/python.sh"
"$dir/python.sh" -c "import openmm, openmm.version as v; print(openmm.__file__, v.openmm_library_path)"
cp "$src/commit.txt" "$dir/commit.txt"
