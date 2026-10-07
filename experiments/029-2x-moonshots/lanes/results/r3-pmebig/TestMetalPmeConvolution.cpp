/** Verify complete fused PME transforms against VkFFT and a double precision FFT.
 * Run with --bench for the daytime timing probe, which performs no correctness assertions.
 */
#include "MetalArray.h"
#include "MetalContext.h"
#include "MetalFFT3D.h"
#include "CommonKernelSources.h"
#include "openmm/System.h"
#include "openmm/internal/AssertionUtilities.h"
#include "pocketfft_hdronly.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <iostream>
#include <numeric>
#include <random>
using namespace OpenMM;
using namespace std;

static double relative(const vector<float>& a, const vector<float>& b, int n) {
    double error = 0, norm = 0;
    for (int i = 0; i < n; i++) { error += pow(double(a[i])-b[i], 2); norm += double(b[i])*b[i]; }
    return sqrt(error/norm);
}

static void runCase(MetalContext& cc, int nx, int ny, int nz, bool dispersion, bool bench) {
    const int n = nx*ny*nz;
    MetalFFT3D fft(cc, nx, ny, nz, true);
    MetalArray grid(cc, 2*n, sizeof(float), "grid"), scratch(cc, n, sizeof(mm_float2), "scratch");
    MetalArray bx(cc, nx, sizeof(float), "bx"), by(cc, ny, sizeof(float), "by"), bz(cc, nz, sizeof(float), "bz");
    vector<float> mods[3];
    int dims[] = {nx, ny, nz};
    for (int d = 0; d < 3; d++)
        for (int i = 0; i < dims[d]; i++) mods[d].push_back(0.6+0.4*cos(M_PI*i/dims[d])*cos(M_PI*i/dims[d]));
    bx.upload(mods[0]); by.upload(mods[1]); bz.upload(mods[2]);
    const double alpha = 2.9, ef = M_PI*M_PI/(alpha*alpha);
    mm_double4 box[] = {mm_double4(0.09,0,0,0), mm_double4(-0.012,0.08,0,0), mm_double4(0.009,-0.008,0.085,0)};
    map<string,string> defines;
    defines["GRID_SIZE_X"] = to_string(nx); defines["GRID_SIZE_Y"] = to_string(ny); defines["GRID_SIZE_Z"] = to_string(nz);
    defines["M_PI"] = cc.doubleToString(M_PI);
    defines["RECIP_EXP_FACTOR"] = cc.doubleToString(ef);
    defines["EWALD_ALPHA"] = cc.doubleToString(alpha);
    if (dispersion) defines["USE_LJPME"] = "1";
    string source = CommonKernelSources::pme;
    size_t start = source.find("KERNEL void reciprocalConvolution");
    source = source.substr(start, source.find("KERNEL void gridInterpolateForce", start)-start);
    ComputeProgram program = cc.compileProgram(source, defines);
    ComputeKernel conv = program->createKernel("reciprocalConvolution"), energy = program->createKernel("gridEvaluateEnergy");
    conv->addArg(scratch); conv->addArg(bx); conv->addArg(by); conv->addArg(bz);
    energy->addArg(scratch); energy->addArg(cc.getEnergyBuffer()); energy->addArg(bx); energy->addArg(by); energy->addArg(bz);
    for (auto b : box) {
        mm_float4 v(b.x,b.y,b.z,0); conv->addArg(v); energy->addArg(v);
    }
    mt19937 rng(2026);
    uniform_real_distribution<float> uniform(-1,1);
    vector<float> input(2*n,0);
    for (int i = 0; i < n; i++) input[i] = uniform(rng);
    auto fused = [&](bool includeEnergy) {
        return fft.execPmeConvolution(grid, scratch, bx, by, bz, box, ef,
                includeEnergy ? &cc.getEnergyBuffer() : NULL, dispersion ? alpha : 0);
    };
    auto baseline = [&](bool includeEnergy) {
        fft.execFFT(grid, scratch, true);
        if (includeEnergy) energy->execute(n);
        conv->execute(n);
        fft.execFFT(scratch, grid, false);
    };
    grid.upload(input);
    if (!fused(false)) {
        cout << "UNSUPPORTED " << nx << 'x' << ny << 'x' << nz << endl;
        return;
    }
    cc.getCurrentStream().finish();
    if (bench) {
        vector<double> timings[2];
        for (int round = 0; round < 22; round++) {
            for (int order = 0; order < 2; order++) {
                int arm = (round+order)%2;
                grid.upload(input);
                cc.getCurrentStream().finish();
                auto begin = chrono::steady_clock::now();
                for (int rep = 0; rep < 5; rep++) {
                    if (arm) fused(false); else baseline(false);
                }
                cc.getCurrentStream().finish();
                double us = chrono::duration<double,micro>(chrono::steady_clock::now()-begin).count()/5;
                if (round >= 2) timings[arm].push_back(us);
            }
        }
        for (auto& values : timings) sort(values.begin(), values.end());
        cout << "TIMING " << nx << 'x' << ny << 'x' << nz << " dispersion=" << dispersion
             << " VkFFT_us=" << timings[0][10] << " fused_us=" << timings[1][10]
             << " saving=" << 1-timings[1][10]/timings[0][10] << endl;
        return;
    }
    auto totalEnergy = [&]() {
        if (cc.getUseMixedPrecision()) {
            vector<double> values; cc.getEnergyBuffer().download(values);
            return accumulate(values.begin(), values.end(), 0.0);
        }
        vector<float> values; cc.getEnergyBuffer().download(values);
        return accumulate(values.begin(), values.end(), 0.0);
    };
    vector<float> vk, result, repeat, forceOnly;
    grid.upload(input); cc.clearBuffer(cc.getEnergyBuffer()); baseline(true); grid.download(vk);
    double vkEnergy = totalEnergy();
    grid.upload(input); cc.clearBuffer(cc.getEnergyBuffer()); ASSERT(fused(true)); grid.download(result);
    double fusedEnergy = totalEnergy();
    grid.upload(input); cc.clearBuffer(cc.getEnergyBuffer()); ASSERT(fused(true)); grid.download(repeat);
    ASSERT(result == repeat);
    grid.upload(input); ASSERT(fused(false)); grid.download(forceOnly);
    ASSERT(relative(forceOnly, result, n) < 2e-6);

    // A double precision CPU transform supplies an independent accuracy control.
    vector<complex<double>> ref(n);
    for (int i = 0; i < n; i++) ref[i] = input[i];
    vector<size_t> shape = {(size_t)nx,(size_t)ny,(size_t)nz}, axes = {0,1,2};
    vector<ptrdiff_t> strides = {(ptrdiff_t)(ny*nz*sizeof(complex<double>)),(ptrdiff_t)(nz*sizeof(complex<double>)),sizeof(complex<double>)};
    pocketfft::c2c(shape,strides,strides,axes,true,ref.data(),ref.data(),1.0);
    auto factor = [&](int x, int y, int z) {
        int mx=x<(nx+1)/2 ? x : x-nx, my=y<(ny+1)/2 ? y : y-ny, mz=z<(nz+1)/2 ? z : z-nz;
        double hx=mx*box[0].x, hy=mx*box[1].x+my*box[1].y, hz=mx*box[2].x+my*box[2].y+mz*box[2].z;
        double m2=hx*hx+hy*hy+hz*hz, volume=box[0].x*box[1].y*box[2].z;
        double mod=double(mods[0][x])*mods[1][y]*mods[2][z];
        if (!dispersion) return m2 == 0 ? 0 : volume/M_PI*exp(-ef*m2)/(m2*mod);
        double m=sqrt(m2), b=M_PI/alpha*m;
        return -(2*M_PI/6)*sqrt(M_PI)*volume/mod*(2*pow(M_PI,3)*sqrt(M_PI)*erfc(b)*m*m2+exp(-b*b)*(pow(alpha,3)-2*alpha*M_PI*M_PI*m2));
    };
    double referenceEnergy=0;
    for (int x=0;x<nx;x++) for (int y=0;y<ny;y++) for (int z=0;z<nz;z++)
        referenceEnergy += 0.5*factor(x,y,z)*norm(ref[(x*ny+y)*nz+z]);
    for (int x=0;x<nx;x++) for (int y=0;y<ny;y++) for (int z=0;z<=nz/2;z++)
        ref[(x*ny+y)*nz+z] *= factor(x,y,z);
    for (int x=0;x<nx;x++) for (int y=0;y<ny;y++) for (int z=nz/2+1;z<nz;z++)
        ref[(x*ny+y)*nz+z] = conj(ref[(((nx-x)%nx)*ny+(ny-y)%ny)*nz+nz-z]);
    pocketfft::c2c(shape,strides,strides,axes,false,ref.data(),ref.data(),1.0);
    vector<float> expected(n);
    for (int i=0;i<n;i++) expected[i]=ref[i].real();
    double delta=relative(result,vk,n), fusedError=relative(result,expected,n), vkError=relative(vk,expected,n);
    cout << "CHECK " << nx << 'x' << ny << 'x' << nz << " dispersion=" << dispersion
         << " mixed=" << cc.getUseMixedPrecision() << " fused/VkFFT=" << delta
         << " reference_fused=" << fusedError << " reference_VkFFT=" << vkError
         << " energy_delta=" << abs(fusedEnergy-vkEnergy)/abs(vkEnergy)
         << " energy_reference_fused=" << abs(fusedEnergy-referenceEnergy)/abs(referenceEnergy)
         << " energy_reference_VkFFT=" << abs(vkEnergy-referenceEnergy)/abs(referenceEnergy) << endl;
    ASSERT(delta < 2e-6);
    ASSERT(fusedError <= 1.02*vkError+1e-7);
    ASSERT(abs(fusedEnergy-vkEnergy) < 2e-6*abs(vkEnergy));
}

int main(int argc, char** argv) {
    try {
        bool bench = argc > 1 && string(argv[1]) == "--bench";
        string precision = argc > 1 && !bench ? argv[1] : "single";
        System system; system.addParticle(1);
        MetalPlatform platform;
        MetalPlatform::PlatformData data(NULL,system,"","true",precision,"false",
                platform.getPropertyDefaultValue(MetalPlatform::MetalTempDirectory()),"false","false",1,NULL);
        MetalContext& cc = *data.contexts[0]; cc.initialize();
        runCase(cc,98,98,98,false,bench);
        runCase(cc,231,112,110,false,bench);
        runCase(cc,198,200,200,false,bench);
        runCase(cc,49,49,49,true,bench);
        if (!bench) {
            runCase(cc,26,33,35,false,false); // radix 13, odd z, incomplete batches
            // A prime outside the butterfly library must leave both arrays untouched.
            MetalFFT3D unsupported(cc,17,17,17,true);
            MetalArray untouched(cc,2*17*17*17,sizeof(float),"untouched");
            vector<float> before(untouched.getSize(),0.25f), after;
            untouched.upload(before);
            mm_double4 box[3];
            ASSERT(!unsupported.execPmeConvolution(untouched,untouched,untouched,untouched,untouched,box,1));
            untouched.download(after);
            ASSERT(before == after);
        }
    } catch (const exception& e) { cerr << e.what() << endl; return 1; }
    cout << "Done" << endl;
}
