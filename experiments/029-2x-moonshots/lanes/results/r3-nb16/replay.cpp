// Fixed-coordinate diagnostic. The live builder and list remain untouched.
#include "openmm/Context.h"
#include "openmm/internal/ContextImpl.h"
#include "MetalContext.h"
#include "MetalPlatform.h"
#include <cstdio>
#include <vector>
using namespace OpenMM;
namespace {
class Access : public MetalPlatform {
public:
    MetalContext& metal(Context& c) const {
        auto& d = *reinterpret_cast<PlatformData*>(getContextImpl(c).getPlatformData());
        return *d.contexts.at(0);
    }
};
struct Replay {
    MetalContext& cc;
    MetalArray tiles, atoms, counts;
    Replay(MetalContext& c, int n, const int* t, const int* a, const unsigned int* count) : cc(c) {
        tiles.initialize<int>(cc, n, "nb16Tiles");
        atoms.initialize<int>(cc, n*32, "nb16Atoms");
        counts.initialize<unsigned int>(cc, 2, "nb16Counts");
        tiles.upload(t); atoms.upload(a); counts.upload(count);
    }
};
}
extern "C" void* replayCreate(void* context, int n, const int* tiles, const int* atoms,
                               const unsigned int* counts, char* error, int size) {
    try { return new Replay(Access().metal(*reinterpret_cast<Context*>(context)), n, tiles, atoms, counts); }
    catch (const std::exception& e) { snprintf(error, size, "%s", e.what()); return nullptr; }
}
extern "C" int replayRun(void* pointer, int compact, int repeat, long long* output, char* error, int size) {
    try {
        auto& r = *reinterpret_cast<Replay*>(pointer);
        r.cc.clearBuffer(r.cc.getLongForceBuffer());
        for (int i = 0; i < repeat; i++) {
            if (compact) r.cc.getNonbondedUtilities().computeCompactInteractions(-1, r.tiles, r.atoms, r.counts);
            else r.cc.getNonbondedUtilities().computeInteractions(-1, true, false);
            r.cc.getCurrentStream().commit();
        }
        r.cc.getLongForceBuffer().download(output);
        return 0;
    }
    catch (const std::exception& e) { snprintf(error, size, "%s", e.what()); return 1; }
}
extern "C" void replayDestroy(void* pointer) { delete reinterpret_cast<Replay*>(pointer); }
