// Analysis-only C ABI for the existing double precision Reference PME engine.
#include "openmm/reference/ReferencePME.h"
#include <algorithm>
#include <exception>
#include <string>
using namespace OpenMM;
static thread_local std::string lastError;
extern "C" const char* pme_error() { return lastError.c_str(); }
extern "C" int evaluate_pme(int n, int order, const int* grid, double alpha,
        const double* xyz, const double* charge, const double* box,
        int dispersion, double* result, double* energy) {
    try {
        std::vector<Vec3> positions(n), forces(n, Vec3());
        std::vector<double> charges(charge, charge+n);
        Vec3 vectors[3];
        for (int i=0; i<n; ++i)
            positions[i] = Vec3(xyz[3*i], xyz[3*i+1], xyz[3*i+2]);
        for (int i=0; i<3; ++i)
            vectors[i] = Vec3(box[3*i], box[3*i+1], box[3*i+2]);
        ReferencePME pme(alpha, n, grid, order, 1.0);
        *energy = 0;
        if (dispersion)
            pme.exec_dpme(positions, forces, charges, vectors, *energy);
        else
            pme.exec(positions, forces, charges, vectors, *energy);
        for (int i=0; i<n; ++i)
            for (int j=0; j<3; ++j)
                result[3*i+j] = forces[i][j];
        return 0;
    } catch (const std::exception& e) {
        lastError = e.what();
        return 1;
    }
}
