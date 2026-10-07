// cbhook: checks the host side of a failed Metal command buffer (GAPS.md gap 4) through the test-only hook.
//
// Needs a Metal plugin built with the CMake option OPENMM_METAL_TEST_HOOKS, run with
// OPENMM_METAL_TEST_FAIL_CB=n: the nth command-buffer status check in the process then sees a page-fault
// NSError. cbhook steps a work unit until MetalEvent::wait or poll throws, prints the message, destroys
// that Context, then runs a fresh Context on the same device for 1000 steps. Exit 0 only if the throw
// came, it named the error, and the fresh run ended with a finite energy.
//
// Build against a hook tree T (build.sh with OPENMM_METAL_TEST_HOOKS:BOOL=ON seeded in T/build/CMakeCache.txt):
//   clang++ -std=c++17 -O2 -mmacosx-version-min=15.0 -IT/prefix/include cbhook.cpp -LT/prefix/lib -lOpenMM \
//       -Wl,-rpath,T/prefix/lib -o cbhook
// usage: cbhook <plugin dir> <wu dir>
#include "OpenMM.h"
#include <cmath>
#include <cstdio>
#include <fstream>
#include <memory>
#include <string>

using namespace OpenMM;
using namespace std;

template <class T>
static T* load(const string& path) {
    ifstream in(path);
    if (!in)
        throw OpenMMException("can't read "+path);
    return XmlSerializer::deserialize<T>(in);
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: cbhook <plugin dir> <wu dir>\n");
        return 2;
    }
    Platform::loadPluginsFromDirectory(argv[1]);
    string wu = argv[2];
    unique_ptr<System> system(load<System>(wu+"/system.xml"));
    unique_ptr<State> state(load<State>(wu+"/state.xml"));
    Platform& platform = Platform::getPlatformByName("Metal");
    map<string, string> properties = {{"Precision", "mixed"}};

    int failedAt = -1;
    string message;
    {
        unique_ptr<Integrator> integrator(load<Integrator>(wu+"/integrator.xml"));
        Context context(*system, *integrator, platform, properties);
        context.setState(*state);
        try {
            for (int step = 0; step < 10000; step += 10) {
                integrator->step(10);
                context.getState(State::Energy);
            }
        }
        catch (const OpenMMException& e) {
            failedAt = context.getStepCount();
            message = e.what();
        }
    }
    if (failedAt < 0) {
        printf("RESULT FAIL: no exception in 10000 steps; is OPENMM_METAL_TEST_FAIL_CB set and the hook built in?\n");
        return 1;
    }
    printf("thrown near step %d: %s\n", failedAt, message.c_str());
    bool named = message.find("MTLCommandBufferErrorDomain") != string::npos;

    unique_ptr<Integrator> integrator(load<Integrator>(wu+"/integrator.xml"));
    Context context(*system, *integrator, platform, properties);
    context.setState(*state);
    integrator->step(1000);
    double energy = context.getState(State::Energy).getPotentialEnergy();
    printf("fresh Context: 1000 steps, potential energy %.6f kJ/mol\n", energy);
    bool pass = named && isfinite(energy);
    printf("RESULT %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
