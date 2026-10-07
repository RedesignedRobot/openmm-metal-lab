// minicore: runs one FAH-style work unit the way a GPU core does, with no Python.
//
// It loads plugins from a directory next to the executable (static.sh links Metal in instead),
// deserializes system.xml, state.xml and integrator.xml, selects the platform and precision from
// flags, checks forces against Reference before the first step, then steps in chunks.  After each
// chunk it checks the energy and writes a binary checkpoint atomically (temporary file, fsync,
// rename) with a length and hash footer.  A restarted process resumes from that checkpoint, so a
// kill at any point costs at most one chunk.
//
// --trace appends one line per step to <out>/trace.txt (see writeTrace), for comparing a killed run
// with a straight one step by step. With --trace, --dump-steps A,B,... writes <out>/dump-<step>.bin
// (raw position, velocity and force doubles) at those steps, and --reload-at S round-trips the Context
// through createCheckpoint and loadCheckpoint in the same process at step S.
//
// --time-compiles reports how long the Context build takes and how much of it is Metal compiling
// (compiletime.cpp), plus the kernels compiled lazily in each chunk.
//
// Exit codes: 0 done, 1 OpenMM error, 2 usage or setup error, 3 bad state (NaN or infinite energy),
// 4 force check against Reference failed.

#include "OpenMM.h"
#include "compiletime.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <set>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

using namespace OpenMM;
using namespace std;

static const double ForceTolerance = 5.0;    // kJ/mol/nm per atom, the alchemiscale-fah default
static const double EnergyTolerance = 10.0;  // kJ/mol
static const double GasConstant = 0.00831446261815324;  // kJ/mol/K

struct Options {
    string wuDir, outDir, pluginDir, platform = "Metal", precision = "single";
    long long steps = 0;
    int checkpointSteps = 1000, seed = 0;
    long long reloadAt = -1;
    set<long long> dumpSteps;
    bool deterministic = false, skipForceCheck = false, trace = false, timeCompiles = false;
};

static bool fileExists(const string& path) {
    struct stat s;
    return stat(path.c_str(), &s) == 0;
}

static string readFile(const string& path) {
    ifstream in(path, ios::binary);
    if (!in)
        throw runtime_error("cannot read "+path);
    stringstream buffer;
    buffer << in.rdbuf();
    return buffer.str();
}

static uint64_t fnv1a(const void* data, size_t size) {
    uint64_t hash = 1469598103934665603ULL;
    const unsigned char* bytes = (const unsigned char*) data;
    for (size_t i = 0; i < size; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static uint64_t fnv1a(const string& data) {
    return fnv1a(data.data(), data.size());
}

// Writes data, then its length and FNV-1a hash, to path.tmp, syncs it and renames it over path.
// MINICORE_CRASH_IN_WRITE=1 stops the process halfway through the temporary file once a checkpoint
// exists, to test a kill mid-write without depending on signal timing.
static void writeAtomically(const string& path, const string& data) {
    string tmp = path+".tmp";
    int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        throw runtime_error("cannot write "+tmp);
    uint64_t footer[2] = {data.size(), fnv1a(data)};
    const char* crash = getenv("MINICORE_CRASH_IN_WRITE");
    if (crash != NULL && string(crash) == "1" && fileExists(path)) {
        write(fd, data.data(), data.size()/2);
        _exit(9);
    }
    bool ok = write(fd, data.data(), data.size()) == (ssize_t) data.size() &&
              write(fd, footer, sizeof(footer)) == (ssize_t) sizeof(footer) &&
              fsync(fd) == 0;
    close(fd);
    if (!ok || rename(tmp.c_str(), path.c_str()) != 0)
        throw runtime_error("failed writing "+path);
}

// Returns the checkpoint body if the footer matches, or an empty string if the file is missing,
// truncated or corrupt.
static string readVerified(const string& path) {
    if (!fileExists(path))
        return "";
    string file = readFile(path);
    if (file.size() < 16)
        return "";
    uint64_t footer[2];
    memcpy(footer, file.data()+file.size()-16, 16);
    string body = file.substr(0, file.size()-16);
    if (footer[0] != body.size() || footer[1] != fnv1a(body))
        return "";
    return body;
}

// The footprint Activity Monitor shows, so a leak over a multi-hour unit shows up in the log.
static double footprintMB() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) != KERN_SUCCESS)
        return -1;
    return info.phys_footprint/1048576.0;
}

static string executableDir() {
    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0)
        return ".";
    string p(path);
    return p.substr(0, p.rfind('/'));
}

static void usage() {
    cerr << "usage: minicore --wu DIR --out DIR --steps N [--platform Metal] [--precision single|mixed]\n"
            "                [--checkpoint-steps K] [--plugins DIR] [--seed S] [--deterministic] [--skip-force-check]\n"
            "                [--time-compiles] [--trace [--dump-steps A,B,...] [--reload-at S]]\n";
    exit(2);
}

static Options parseOptions(int argc, char** argv) {
    Options opt;
    opt.pluginDir = executableDir()+"/plugins";
    for (int i = 1; i < argc; i++) {
        string arg = argv[i];
        bool hasValue = (i+1 < argc);
        if (arg == "--deterministic")
            opt.deterministic = true;
        else if (arg == "--skip-force-check")
            opt.skipForceCheck = true;
        else if (arg == "--trace")
            opt.trace = true;
        else if (arg == "--time-compiles")
            opt.timeCompiles = true;
        else if (!hasValue)
            usage();
        else if (arg == "--wu")
            opt.wuDir = argv[++i];
        else if (arg == "--out")
            opt.outDir = argv[++i];
        else if (arg == "--plugins")
            opt.pluginDir = argv[++i];
        else if (arg == "--platform")
            opt.platform = argv[++i];
        else if (arg == "--precision")
            opt.precision = argv[++i];
        else if (arg == "--steps")
            opt.steps = atoll(argv[++i]);
        else if (arg == "--seed")
            opt.seed = atoi(argv[++i]);
        else if (arg == "--reload-at")
            opt.reloadAt = atoll(argv[++i]);
        else if (arg == "--dump-steps") {
            stringstream list(argv[++i]);
            string item;
            while (getline(list, item, ','))
                opt.dumpSteps.insert(atoll(item.c_str()));
        }
        else if (arg == "--checkpoint-steps")
            opt.checkpointSteps = atoi(argv[++i]);
        else
            usage();
    }
    if (opt.wuDir.empty() || opt.outDir.empty() || opt.steps <= 0 || opt.checkpointSteps <= 0)
        usage();
    return opt;
}

template <class T>
static T* load(const string& path) {
    ifstream in(path);
    if (!in)
        throw runtime_error("cannot read "+path);
    return XmlSerializer::deserialize<T>(in);
}

// Compares forces and energy against Reference, the check a core runs before trusting a GPU.
static bool forcesMatchReference(Context& context, const System& system) {
    State gpu = context.getState(State::Positions | State::Forces | State::Energy);
    VerletIntegrator integrator(0.001);
    Context reference(system, integrator, Platform::getPlatformByName("Reference"));
    Vec3 a, b, c;
    gpu.getPeriodicBoxVectors(a, b, c);
    reference.setPeriodicBoxVectors(a, b, c);
    reference.setPositions(gpu.getPositions());
    for (auto& param : context.getParameters())
        reference.setParameter(param.first, param.second);
    State ref = reference.getState(State::Forces | State::Energy);
    double maxForceError = 0;
    for (int i = 0; i < system.getNumParticles(); i++) {
        Vec3 d = gpu.getForces()[i]-ref.getForces()[i];
        maxForceError = max(maxForceError, sqrt(d.dot(d)));
    }
    double energyError = fabs(gpu.getPotentialEnergy()-ref.getPotentialEnergy());
    printf("force check: max|dF| %.4g kJ/mol/nm, |dE| %.4g kJ/mol\n", maxForceError, energyError);
    return maxForceError <= ForceTolerance && energyError <= EnergyTolerance && isfinite(maxForceError) && isfinite(energyError);
}

// A seed of 0 in the integrator or barostat XML picks a new seed per Context; comparing runs needs a
// fixed one.
static void setSeed(System& system, Integrator& integrator, int seed) {
    for (int i = 0; i < system.getNumForces(); i++)
        if (MonteCarloBarostat* barostat = dynamic_cast<MonteCarloBarostat*>(&system.getForce(i)))
            barostat->setRandomNumberSeed(seed);
    if (CustomIntegrator* custom = dynamic_cast<CustomIntegrator*>(&integrator))
        custom->setRandomNumberSeed(seed);
    else if (LangevinMiddleIntegrator* langevin = dynamic_cast<LangevinMiddleIntegrator*>(&integrator))
        langevin->setRandomNumberSeed(seed);
    else if (LangevinIntegrator* langevin = dynamic_cast<LangevinIntegrator*>(&integrator))
        langevin->setRandomNumberSeed(seed);
    else
        throw runtime_error("--seed is not supported for this integrator");
}

static void printGlobals(Integrator& integrator) {
    CustomIntegrator* custom = dynamic_cast<CustomIntegrator*>(&integrator);
    if (custom == NULL)
        return;
    for (int i = 0; i < custom->getNumGlobalVariables(); i++)
        printf("global %s %.17g\n", custom->getGlobalVariableName(i).c_str(), custom->getGlobalVariable(i));
}

static double degreesOfFreedom(const System& system) {
    int dof = 0;
    for (int i = 0; i < system.getNumParticles(); i++)
        if (system.getParticleMass(i) > 0)
            dof += 3;
    dof -= system.getNumConstraints();
    for (int i = 0; i < system.getNumForces(); i++)
        if (dynamic_cast<const CMMotionRemover*>(&system.getForce(i)) != NULL)
            dof -= 3;
    return dof;
}

// One trace line: label, step count, then FNV-1a hashes of the position, velocity and box doubles.
// Every 10th step adds the potential energy and the temperature. A resumed process writes a "load"
// line first, so its starting state can be matched bit for bit against the step its checkpoint holds.
static void writeTrace(FILE* trace, const char* label, Context& context, double dof) {
    bool withEnergy = context.getStepCount() % 10 == 0;
    State state = context.getState(State::Positions | State::Velocities | (withEnergy ? State::Energy : 0));
    Vec3 box[3];
    state.getPeriodicBoxVectors(box[0], box[1], box[2]);
    const vector<Vec3>& pos = state.getPositions();
    const vector<Vec3>& vel = state.getVelocities();
    fprintf(trace, "%s %lld %016llx %016llx %016llx", label, context.getStepCount(),
            (unsigned long long) fnv1a(pos.data(), pos.size()*sizeof(Vec3)),
            (unsigned long long) fnv1a(vel.data(), vel.size()*sizeof(Vec3)),
            (unsigned long long) fnv1a(box, sizeof(box)));
    if (withEnergy)
        fprintf(trace, " %.6f %.4f", state.getPotentialEnergy(), 2*state.getKineticEnergy()/(dof*GasConstant));
    fprintf(trace, "\n");
    fflush(trace);
}

static void writeDump(Context& context, const string& outDir) {
    State state = context.getState(State::Positions | State::Velocities | State::Forces);
    ofstream out(outDir+"/dump-"+to_string(context.getStepCount())+".bin", ios::binary);
    for (const vector<Vec3>* v : {&state.getPositions(), &state.getVelocities(), &state.getForces()})
        out.write((const char*) v->data(), v->size()*sizeof(Vec3));
}

// Prints the wall time since start and the Metal library and pipeline compile time since before.
static void printCompileTime(const char* what, chrono::steady_clock::time_point start, const CompileTimes& before) {
    double total = chrono::duration<double>(chrono::steady_clock::now()-start).count();
    CompileTimes now = compileTimes();
    double libraries = now.librarySeconds-before.librarySeconds, pipelines = now.pipelineSeconds-before.pipelineSeconds;
    printf("%s %.3f s: libraries %.3f s (%d), pipelines %.3f s (%d), other %.3f s\n", what, total, libraries,
           now.libraries-before.libraries, pipelines, now.pipelines-before.pipelines, total-libraries-pipelines);
}

#ifdef MINICORE_STATIC
// static.sh links OpenMM and the Metal platform in, the way a shipped core would; there are no plugins.
extern "C" void registerMetalPlatform();
#endif

static int run(const Options& opt) {
#ifdef MINICORE_STATIC
    registerMetalPlatform();
#else
    Platform::loadPluginsFromDirectory(opt.pluginDir);
#endif
    for (const string& failure : Platform::getPluginLoadFailures())
        printf("plugin load failure: %s\n", failure.c_str());
    unique_ptr<System> system(load<System>(opt.wuDir+"/system.xml"));
    unique_ptr<Integrator> integrator(load<Integrator>(opt.wuDir+"/integrator.xml"));
    if (opt.seed != 0)
        setSeed(*system, *integrator, opt.seed);
    Platform& platform = Platform::getPlatformByName(opt.platform);
    // Pass only the properties this platform declares; Context creation rejects any other name.
    map<string, string> properties;
    const vector<string>& names = platform.getPropertyNames();
    if (find(names.begin(), names.end(), "Precision") != names.end())
        properties["Precision"] = opt.precision;
    if (opt.deterministic)
        properties["DeterministicForces"] = "true";
    if (opt.timeCompiles)
        installCompileTimers();
    auto buildStart = chrono::steady_clock::now();
    CompileTimes mark = compileTimes();
    Context context(*system, *integrator, platform, properties);
    if (opt.timeCompiles)
        printCompileTime("context build", buildStart, mark);
    printf("platform %s, %d atoms\n", platform.getName().c_str(), system->getNumParticles());
    for (auto& property : properties)
        printf("%s = %s\n", property.first.c_str(), platform.getPropertyValue(context, property.first).c_str());

    string checkpointPath = opt.outDir+"/checkpoint.bin";
    string checkpoint = readVerified(checkpointPath);
    if (checkpoint.empty()) {
        if (fileExists(checkpointPath))
            printf("checkpoint failed its length or hash check, restarting from state.xml\n");
        unique_ptr<State> state(load<State>(opt.wuDir+"/state.xml"));
        context.setState(*state);
        context.setStepCount(0);
        if (!opt.skipForceCheck && !forcesMatchReference(context, *system))
            return 4;
    }
    else {
        istringstream in(checkpoint);
        context.loadCheckpoint(in);
        printf("resumed at step %lld\n", context.getStepCount());
    }

    FILE* trace = NULL;
    double dof = degreesOfFreedom(*system);
    if (opt.trace) {
        trace = fopen((opt.outDir+"/trace.txt").c_str(), "a");
        writeTrace(trace, "load", context, dof);
        if (opt.dumpSteps.count(context.getStepCount()))
            writeDump(context, opt.outDir);
    }
    while (context.getStepCount() < opt.steps) {
        int chunk = (int) min<long long>(opt.checkpointSteps, opt.steps-context.getStepCount());
        if (trace == NULL)
            integrator->step(chunk);
        for (int i = 0; trace != NULL && i < chunk; i++) {
            integrator->step(1);
            writeTrace(trace, "step", context, dof);
            if (opt.dumpSteps.count(context.getStepCount()))
                writeDump(context, opt.outDir);
            if (context.getStepCount() == opt.reloadAt) {
                stringstream roundTrip;
                context.createCheckpoint(roundTrip);
                context.loadCheckpoint(roundTrip);
            }
        }
        State state = context.getState(State::Energy);
        double energy = state.getPotentialEnergy()+state.getKineticEnergy();
        if (!isfinite(energy)) {
            printf("bad state at step %lld: energy %g\n", context.getStepCount(), energy);
            return 3;
        }
        ostringstream out;
        context.createCheckpoint(out);
        writeAtomically(checkpointPath, out.str());
        printf("step %lld energy %.6f footprint %.1f MB\n", context.getStepCount(), energy, footprintMB());
        if (opt.timeCompiles) {
            // Kernels a Context compiles lazily, on its first force evaluation, land in this line.
            CompileTimes now = compileTimes();
            printf("chunk compiles: libraries %.3f s (%d), pipelines %.3f s (%d)\n", now.librarySeconds-mark.librarySeconds,
                   now.libraries-mark.libraries, now.pipelineSeconds-mark.pipelineSeconds, now.pipelines-mark.pipelines);
            mark = now;
        }
    }

    // final.bin holds the raw position and velocity doubles, for bitwise comparison between runs.
    State final = context.getState(State::Positions | State::Velocities | State::Energy | State::Parameters);
    ofstream stateOut(opt.outDir+"/final-state.xml");
    XmlSerializer::serialize<State>(&final, "State", stateOut);
    ofstream rawOut(opt.outDir+"/final.bin", ios::binary);
    rawOut.write((const char*) final.getPositions().data(), final.getPositions().size()*sizeof(Vec3));
    rawOut.write((const char*) final.getVelocities().data(), final.getVelocities().size()*sizeof(Vec3));
    printGlobals(*integrator);
    printf("done %lld steps\n", context.getStepCount());
    return 0;
}

int main(int argc, char** argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    Options opt = parseOptions(argc, argv);
    mkdir(opt.outDir.c_str(), 0755);
    ofstream(opt.outDir+"/minicore.pid") << getpid() << endl;
    try {
        return run(opt);
    }
    catch (const OpenMMException& e) {
        printf("OpenMM error: %s\n", e.what());
        return 1;
    }
    catch (const exception& e) {
        printf("error: %s\n", e.what());
        return 2;
    }
}
