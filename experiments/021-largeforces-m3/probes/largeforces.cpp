// Reproduces testLargeForces (tests/TestLocalEnergyMinimizer.h) with per-iteration dumps.
// usage: largeforces <platform> <precision> [quiet]
#include "OpenMM.h"
#include "sfmt/SFMT.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using namespace OpenMM;
using namespace std;

static const int numParticles = 10;

struct Dumper : public MinimizationReporter {
    bool report(int iteration, const vector<double>& x, const vector<double>& grad, map<string, double>& args) override {
        double gmax = 0, gnorm = 0, xmax = 0;
        for (int i = 0; i < (int) grad.size(); i++) {
            gmax = max(gmax, fabs(grad[i]));
            gnorm += grad[i]*grad[i];
        }
        for (int i = 0; i < numParticles; i++)
            xmax = max(xmax, sqrt(x[3*i]*x[3*i]+x[3*i+1]*x[3*i+1]+x[3*i+2]*x[3*i+2]));
        printf("iter %3d  E %.9e  |g| %.6e  max|g| %.6e  maxdist %.6e\n", iteration, args["system energy"], sqrt(gnorm), gmax, xmax);
        return false;
    }
};

int main(int argc, char** argv) {
    Platform::loadPluginsFromDirectory(Platform::getDefaultPluginsDirectory());
    string platformName = argv[1];
    map<string, string> props;
    if (platformName == "Metal" || platformName == "OpenCL" || platformName == "CUDA")
        props["Precision"] = argv[2];
    bool quiet = argc > 3 && strcmp(argv[3], "quiet") == 0;

    System system;
    NonbondedForce* nonbonded = new NonbondedForce();
    system.addForce(nonbonded);
    for (int i = 0; i < numParticles; i++) {
        system.addParticle(1.0);
        nonbonded->addParticle(0.1, 0.2, 1.0);
    }
    vector<Vec3> positions(numParticles);
    OpenMM_SFMT::SFMT sfmt;
    init_gen_rand(0, sfmt);
    for (int i = 0; i < numParticles; i++)
        positions[i] = Vec3(genrand_real2(sfmt), genrand_real2(sfmt), genrand_real2(sfmt))*1e-2;

    VerletIntegrator integrator(0.01);
    Platform& platform = Platform::getPlatformByName(platformName);
    Context context(system, integrator, platform, props);
    printf("platform %s precision %s device %s\n", platformName.c_str(), argv[2],
           props.empty() ? "-" : platform.getPropertyValue(context, platformName == "OpenCL" ? "DeviceName" : "DeviceName").c_str());
    context.setPositions(positions);

    State s0 = context.getState(State::Forces | State::Energy);
    printf("initial E %.9e\n", s0.getPotentialEnergy());
    for (int i = 0; i < numParticles; i++) {
        Vec3 f = s0.getForces()[i];
        printf("  f[%d] = % .9e % .9e % .9e\n", i, f[0], f[1], f[2]);
    }

    Dumper dumper;
    LocalEnergyMinimizer::minimize(context, 1.0, 0, quiet ? NULL : &dumper);
    State state = context.getState(State::Positions | State::Energy);
    double maxdist = 0.0;
    for (int i = 0; i < numParticles; i++) {
        Vec3 r = state.getPositions()[i];
        maxdist = max(maxdist, sqrt(r.dot(r)));
    }
    printf("final E %.9e maxdist %.9e -> %s\n", state.getPotentialEnergy(), maxdist, (maxdist > 1.0 && maxdist < 10.0) ? "PASS" : "FAIL");
    return 0;
}
