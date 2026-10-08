// Read-only bridge to the live Metal neighbor list. No platform changes.
#include "openmm/Context.h"
#include "openmm/internal/ContextImpl.h"
#include "MetalContext.h"
#include "MetalPlatform.h"
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace OpenMM;
using namespace std;

namespace {
class Access : public MetalPlatform {
public:
    MetalContext& metal(Context& context) const {
        ContextImpl& impl = getContextImpl(context);
        if (impl.getPlatform().getName() != "Metal")
            throw OpenMMException("snapshot requires Metal");
        auto& data = *reinterpret_cast<PlatformData*>(impl.getPlatformData());
        if (data.contexts.size() != 1)
            throw OpenMMException("snapshot requires one Metal device");
        return *data.contexts[0];
    }
};

template<class T> vector<T> read(const ArrayInterface& array) {
    if ((array.getSize()*array.getElementSize()) % sizeof(T))
        throw OpenMMException("snapshot array type mismatch");
    vector<T> data(array.getSize()*array.getElementSize()/sizeof(T));
    if (!data.empty()) array.download(data.data());
    return data;
}

template<class T> void write(const string& prefix, const string& name, const vector<T>& data) {
    ofstream out(prefix+"."+name, ios::binary);
    out.write(reinterpret_cast<const char*>(data.data()), data.size()*sizeof(T));
    out.close();
    if (!out) throw OpenMMException("cannot write snapshot "+name);
}
}

extern "C" int snapshot(void* pointer, const char* prefix, char* error, int errorSize) {
    try {
        static const Access access;
        auto& cc = access.metal(*reinterpret_cast<Context*>(pointer));
        auto& nb = cc.getNonbondedUtilities();
        // The caller has completed getState(getForces=True). Downloads also synchronize.
        auto count = read<unsigned int>(nb.getInteractionCount());
        auto tiles = read<int>(nb.getInteractingTiles());
        auto atoms = read<int>(nb.getInteractingAtoms());
        auto singles = read<int>(nb.getSinglePairs());
        if (count.size() < 2 || count[0] > tiles.size() ||
                size_t(count[0])*32 > atoms.size() || size_t(count[1])*2 > singles.size())
            throw OpenMMException("snapshot list overflow");
        tiles.resize(count[0]); atoms.resize(size_t(count[0])*32); singles.resize(size_t(count[1])*2);
        if (cc.getPosq().getElementSize() != 4*sizeof(float))
            throw OpenMMException("snapshot expects float4 direct-force positions");
        write(prefix, "posq", read<float>(cc.getPosq()));
        write(prefix, "tiles", tiles);
        write(prefix, "atoms", atoms);
        write(prefix, "singles", singles);
        write(prefix, "exclusions", read<int>(nb.getExclusionTiles()));
        write(prefix, "order", cc.getAtomIndex());
        Vec3 box[3];
        cc.getPeriodicBoxVectors(box[0], box[1], box[2]);
        vector<double> vectors;
        for (auto& v : box) for (int i = 0; i < 3; i++) vectors.push_back(v[i]);
        write(prefix, "box", vectors);
        return 0;
    } catch (const exception& e) {
        snprintf(error, errorSize, "%s", e.what());
        return -1;
    }
}
