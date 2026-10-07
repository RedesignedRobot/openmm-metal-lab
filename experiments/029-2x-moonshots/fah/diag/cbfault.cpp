// cbfault: makes one Metal command buffer fail and reports whether OpenMM raises it (GAPS.md gap 4).
//
// A single thread spins on a flag in shared memory, so the command buffer runs until the GPU watchdog
// kills it or the host releases the flag after the time limit (argument 1, default 30 s).  A watchdog
// kill must reach the caller as an OpenMMException from MetalEvent::wait (7c2486c27).  If the kernel
// is released instead, macOS let a compute buffer run that long and this probe can't inject a fault.
//
// It holds the GPU for up to the limit, so it needs an exclusive hold, not a shared correctness one.
//
// Build against a tree T with source S: take the INCLUDES line of TestMetalSort.cpp.o from
// T/build/build.ninja, then
//   clang++ -O2 -std=gnu++17 -mmacosx-version-min=15.0 -D__ARM64__=1 <includes> cbfault.cpp \
//       -LT/build -lOpenMM -lOpenMMMetal -Wl,-rpath,T/build -framework Metal -framework Foundation -o cbfault

// libOpenMMMetal hides its metal-cpp selectors, so this file defines its own for contents().
#define NS_PRIVATE_IMPLEMENTATION
#define MTL_PRIVATE_IMPLEMENTATION
#include "MetalArray.h"
#include "MetalContext.h"
#include "MetalPlatform.h"
#include "openmm/OpenMMException.h"
#include "openmm/System.h"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

using namespace OpenMM;
using namespace std;

static const char* SpinKernel =
    "KERNEL void spin(GLOBAL int* RESTRICT flag, GLOBAL int* RESTRICT out) {\n"
    "    int n = 0;\n"
    "    while (atomic_load_explicit((device atomic_int*) flag, memory_order_relaxed) == 0)\n"
    "        n++;\n"
    "    out[0] = n;\n"
    "}\n";

int main(int argc, char** argv) {
    double limit = (argc > 1 ? atof(argv[1]) : 30.0);
    System system;
    system.addParticle(1.0);
    MetalPlatform platform;
    MetalPlatform::PlatformData platformData(NULL, system, "", "true", "single", "false",
            platform.getPropertyDefaultValue(MetalPlatform::MetalTempDirectory()), "false", "false", 1, NULL);
    MetalContext& context = *platformData.contexts[0];
    context.initialize();
    MetalArray flag(context, 1, sizeof(int), "flag");
    MetalArray out(context, 1, sizeof(int), "out");
    flag.upload(vector<int>{0});
    volatile int* hostFlag = (volatile int*) flag.getDevicePointer()->contents();

    ComputeKernel kernel = context.compileProgram(SpinKernel)->createKernel("spin");
    kernel->addArg(flag);
    kernel->addArg(out);
    kernel->execute(1, 1);
    ComputeEvent event = context.createEvent();
    auto start = chrono::steady_clock::now();
    event->enqueue();

    atomic<bool> finished(false);
    thread release([&] {
        while (!finished && chrono::duration<double>(chrono::steady_clock::now()-start).count() < limit)
            this_thread::sleep_for(chrono::milliseconds(100));
        *hostFlag = 1;
    });
    try {
        event->wait();
        finished = true;
        double seconds = chrono::duration<double>(chrono::steady_clock::now()-start).count();
        printf("RESULT no error after %.1f s: the host released the kernel, no fault was injected\n", seconds);
    }
    catch (const OpenMMException& e) {
        finished = true;
        double seconds = chrono::duration<double>(chrono::steady_clock::now()-start).count();
        printf("RESULT OpenMMException after %.1f s: %s\n", seconds, e.what());
    }
    release.join();
    return 0;
}
