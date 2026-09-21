# Build notes for experiment 013

This document records the exact configuration, build, and test steps for the Metal platform in NORPG/openmm branch Objective-C at commit 8f6a7332f4bca326cd43366f2916da396db661ae.

## Hardware and toolchain environments

### Apple M3 Ultra host

- CPU: Apple M3 Ultra, 28 cores.
- GPU: 60 cores.
- RAM: 128 GB unified memory.
- Operating system: macOS 27.0.
- Command Line Tools: 27.0.0.0.1788430756.
- C/C++ compiler: AppleClang 21.0.0.21000334 (`/usr/bin/clang`, `/usr/bin/clang++`).
- Build tools: CMake 4.4.3 and Ninja 1.13.2 executed via `uv run --with cmake --with ninja`.

### Apple M2 remote machine

- Host address: `amir@10.10.10.11`.
- CPU: Apple M2, 8 cores.
- GPU: 10 cores.
- RAM: 8 GB unified memory.
- Operating system: macOS 27.0.
- Command Line Tools: 27.0.0.0.1788430756.
- C/C++ compiler: AppleClang 21.0.0.21000334 (`/usr/bin/clang`, `/usr/bin/clang++`).
- Build tools: CMake 4.4.3 (`/opt/homebrew/bin/cmake`) and Ninja 1.13.2 (`/opt/homebrew/bin/ninja`).

## Worktree preparation

The fork repository `/Users/mas/code/openmm` contains the `norpg` remote pointing to `https://github.com/NORPG/openmm.git`.
Fetching the remote and creating the worktree on the host:

```sh
cd /Users/mas/code/openmm
git fetch norpg
git worktree add /Users/mas/code/wt/openmm-norpg 8f6a7332f4bca326cd43366f2916da396db661ae
```

The worktree was mirrored to the M2 remote machine under `~/lab/013-norpg`:

```sh
ssh amir@10.10.10.11 "mkdir -p ~/lab/013-norpg"
rsync -az --delete --exclude .git --exclude build /Users/mas/code/wt/openmm-norpg/ amir@10.10.10.11:~/lab/013-norpg/
```

## Configure commands and errors encountered

### Configuration error with wrappers

The first configure attempt disabled Python wrappers with `-DOPENMM_BUILD_PYTHON_WRAPPERS=OFF`.
CMake configuration failed with:

```text
CMake Error at .../FindPackageHandleStandardArgs.cmake:290 (message):
  Could NOT find Doxygen (missing: DOXYGEN_EXECUTABLE)
Call Stack (most recent call first):
  wrappers/CMakeLists.txt:1 (find_package)
```

Cause: In `CMakeLists.txt`, `OPENMM_BUILD_C_AND_FORTRAN_WRAPPERS` defaults to `ON`.
When enabled, CMake includes `wrappers/CMakeLists.txt`, which invokes `find_package(Doxygen REQUIRED)`.
Doxygen is not installed on the host.

Resolution: Added `-DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF` to the CMake configuration.

### Compiler warnings

During compilation, Clang reported warnings in vendored libraries:

- In `libraries/asmjit/`: `-Wnontrivial-memcall` warnings for `memset` on non-trivially copyable types `ZoneAllocator` and `FuncArgsAssignment`.
- In standard library headers: `#warning "The selected platform is no longer supported by libc++."` caused by `platforms/metal/CMakeLists.txt` enforcing `CMAKE_OSX_DEPLOYMENT_TARGET="13.0"` on macOS 27 SDK.

Neither warning halted compilation.

### Final configuration command

The following command configured the build directory on both the M3 Ultra and M2:

```sh
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX=build/install \
  -DOPENMM_BUILD_METAL_LIB=ON \
  -DOPENMM_BUILD_SHARED_LIB=ON \
  -DOPENMM_BUILD_STATIC_LIB=OFF \
  -DOPENMM_BUILD_PYTHON_WRAPPERS=OFF \
  -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF \
  -DOPENMM_BUILD_CUDA_LIB=OFF \
  -DOPENMM_BUILD_OPENCL_LIB=OFF \
  -DOPENMM_BUILD_CPU_LIB=ON \
  -DOPENMM_BUILD_REFERENCE_LIB=ON \
  -DBUILD_TESTING=ON
```

## Build execution

### Apple M3 Ultra host build

The build ran using 8 parallel jobs:

```sh
uv run --with cmake --with ninja ninja -C /Users/mas/code/wt/openmm-norpg/build TestMetalComputeContext
```

The targets `libOpenMM.dylib`, `libOpenMMMetal.dylib`, and `TestMetalComputeContext` built without errors.

The install target was verified:

```sh
uv run --with cmake --with ninja ninja -C /Users/mas/code/wt/openmm-norpg/build install
```

### Apple M2 remote build

The build ran using 4 parallel jobs to stay within 8 GB of RAM and avoid disk swapping:

```sh
ssh amir@10.10.10.11 "ninja -C ~/lab/013-norpg/build -j4 TestMetalComputeContext"
```

The targets compiled and linked cleanly.

## Test execution commands

### Apple M3 Ultra host test

```sh
uv run --with cmake ctest \
  --test-dir /Users/mas/code/wt/openmm-norpg/build \
  -R '^TestMetalComputeContext$' \
  --timeout 300 \
  -V > /tmp/ctest-m3ultra.log 2>&1
```

Outcome: Test passed in 0.94 seconds. Exit code 0.

### Apple M2 remote test

```sh
ssh amir@10.10.10.11 "/opt/homebrew/opt/cmake/bin/ctest \
  --test-dir ~/lab/013-norpg/build \
  -R '^TestMetalComputeContext$' \
  --timeout 300 \
  -V" > /tmp/ctest-m2mini.log 2>&1
```

Outcome: Test passed in 1.31 seconds. Exit code 0.
