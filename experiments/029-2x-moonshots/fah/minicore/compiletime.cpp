// compiletime: wall time the Metal device spends compiling, for minicore --time-compiles.
//
// It replaces two methods on the system device's class through the Objective-C runtime:
// newLibraryWithSource:options:error: (MSL source to a library, the step OpenMM's Metal plugin runs
// for every program) and newComputePipelineStateWithFunction:options:reflection:error: (one pipeline
// per kernel). Each replacement times the original call and adds it to a running total. Both calls
// are synchronous, so the totals are wall time spent inside the compiler.

#include "compiletime.h"
#include <chrono>
#include <objc/runtime.h>

using namespace std;

extern "C" id MTLCreateSystemDefaultDevice(void);

static IMP originalNewLibrary = NULL, originalNewPipeline = NULL;
static CompileTimes totals;

static double secondsSince(chrono::steady_clock::time_point start) {
    return chrono::duration<double>(chrono::steady_clock::now()-start).count();
}

static id timedNewLibrary(id self, SEL sel, id source, id options, id* error) {
    auto start = chrono::steady_clock::now();
    id library = ((id (*)(id, SEL, id, id, id*)) originalNewLibrary)(self, sel, source, options, error);
    totals.librarySeconds += secondsSince(start);
    totals.libraries++;
    return library;
}

static id timedNewPipeline(id self, SEL sel, id function, unsigned long options, id* reflection, id* error) {
    auto start = chrono::steady_clock::now();
    id pipeline = ((id (*)(id, SEL, id, unsigned long, id*, id*)) originalNewPipeline)(self, sel, function, options, reflection, error);
    totals.pipelineSeconds += secondsSince(start);
    totals.pipelines++;
    return pipeline;
}

void installCompileTimers() {
    Class device = object_getClass(MTLCreateSystemDefaultDevice());
    Method library = class_getInstanceMethod(device, sel_registerName("newLibraryWithSource:options:error:"));
    Method pipeline = class_getInstanceMethod(device, sel_registerName("newComputePipelineStateWithFunction:options:reflection:error:"));
    if (library == NULL || pipeline == NULL)
        return;
    originalNewLibrary = method_setImplementation(library, (IMP) timedNewLibrary);
    originalNewPipeline = method_setImplementation(pipeline, (IMP) timedNewPipeline);
}

CompileTimes compileTimes() {
    return totals;
}
