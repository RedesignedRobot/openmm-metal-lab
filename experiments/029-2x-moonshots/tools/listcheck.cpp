// Structural neighbor-list check for the Metal platform, loaded by listcheck.py through ctypes.
// Reads the lists the nonbonded kernel will use for the last force evaluation (exclusion tiles,
// neighbor-list tiles with their interactingAtoms, single pairs) and checks them against every atom
// pair within the cutoff, enumerated on the CPU with a cell list in double precision:
//   uncovered    a non-excluded pair within the cutoff that no tile or single pair computes
//   duplicate    a non-excluded pair within the cutoff computed more than once
//   excluded     an excluded pair outside the exclusion tiles, or also in a neighbor tile or single pair
// Charges play no part. Built against one tree by listcheck.sh:
//   clang++ -std=gnu++17 -shared <tree includes> listcheck.cpp -lOpenMM -lOpenMMMetal
#include "openmm/Context.h"
#include "openmm/internal/ContextImpl.h"
#include "MetalContext.h"
#include "MetalPlatform.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <exception>
#include <vector>

using namespace OpenMM;
using namespace std;

namespace {

// getContextImpl() is a protected member of Platform, as in TestMetalCommandBatching.cpp.
class Access : public MetalPlatform {
public:
    MetalContext& metal(Context& context) const {
        ContextImpl& impl = getContextImpl(context);
        if (impl.getPlatform().getName() != "Metal")
            throw OpenMMException("listcheck: the Context is not on the Metal platform");
        return *reinterpret_cast<PlatformData*>(impl.getPlatformData())->contexts[0];
    }
};

vector<int> download(const MetalArray& array) {
    vector<int> data(array.getSize()*array.getElementSize()/sizeof(int));
    if (array.getSize() > 0)
        array.download(data.data());
    return data;
}

uint64_t key(int a, int b) {
    return ((uint64_t) min(a, b) << 32) | (uint32_t) max(a, b);
}

bool contains(const vector<uint64_t>& sorted, uint64_t k) {
    return binary_search(sorted.begin(), sorted.end(), k);
}

} // namespace

// stats: [0] pairs within cutoff, [1] uncovered, [2] duplicate, [3] excluded pairs wrong,
//        [4] neighbor tiles, [5] single pairs, [6] exclusion tiles, [7] list overflow (1 if a count
//        exceeds its array, which makes the kernel skip the list).
// report: up to maxReport rows of (atom1, atom2, kind) with kind 1 uncovered, 2 duplicate, 3 excluded;
// distances go to reportDistance. Atom indices are the System's. dropTile >= 0 blanks that neighbor tile
// on the host copy first, the negative control: the check must then report uncovered pairs. Returns the
// number of rows, or -1 with the message in error.
extern "C" int listcheck(void* contextPointer, const double* positions, const double* box, double cutoff,
        const int* exclusionPairs, int numExclusions, int dropTile, int maxReport, long long* stats, int* report,
        double* reportDistance, char* error, int errorSize) {
    try {
        static const Access access;
        MetalContext& cc = access.metal(*reinterpret_cast<Context*>(contextPointer));
        MetalNonbondedUtilities& nb = cc.getNonbondedUtilities();
        const int tileSize = MetalContext::TileSize;
        const int numAtoms = cc.getNumAtoms();
        const int padded = cc.getPaddedNumAtoms();
        const vector<int>& atomIndex = cc.getAtomIndex();
        vector<int> sortedOf(numAtoms);
        for (int s = 0; s < numAtoms; s++)
            sortedOf[atomIndex[s]] = s;

        vector<int> exclusionTiles = download(nb.getExclusionTiles());
        vector<int> count = download(nb.getInteractionCount());
        vector<int> tiles = download(nb.getInteractingTiles());
        vector<int> interactingAtoms = download(nb.getInteractingAtoms());
        vector<int> singlePairs = download(nb.getSinglePairs());
        long long numTiles = count.empty() ? 0 : (unsigned int) count[0];
        long long numSingle = count.size() < 2 ? 0 : (unsigned int) count[1];
        stats[7] = (numTiles > (long long) tiles.size() || numSingle > (long long) singlePairs.size()/2);
        numTiles = min(numTiles, (long long) tiles.size());
        numSingle = min(numSingle, (long long) singlePairs.size()/2);
        stats[4] = numTiles;
        stats[5] = numSingle;
        stats[6] = exclusionTiles.size()/2;
        if (dropTile >= numTiles)
            throw OpenMMException("listcheck: --drop-tile is past the last neighbor tile");
        if (dropTile >= 0)
            fill_n(interactingAtoms.begin()+(long long) dropTile*tileSize, tileSize, padded);

        vector<uint64_t> exclusionTileKeys;
        for (size_t t = 0; t+1 < exclusionTiles.size(); t += 2)
            exclusionTileKeys.push_back(key(exclusionTiles[t], exclusionTiles[t+1]));
        sort(exclusionTileKeys.begin(), exclusionTileKeys.end());
        vector<uint64_t> singleKeys;
        for (long long p = 0; p < numSingle; p++)
            singleKeys.push_back(key(singlePairs[2*p], singlePairs[2*p+1]));
        sort(singleKeys.begin(), singleKeys.end());
        // For each sorted atom, the x blocks of the neighbor tiles that list it on the y side (CSR).
        vector<long long> start(padded+1, 0);
        for (long long p = 0; p < numTiles*tileSize; p++)
            if (interactingAtoms[p] >= 0 && interactingAtoms[p] < padded)
                start[interactingAtoms[p]+1]++;
        for (int s = 0; s < padded; s++)
            start[s+1] += start[s];
        vector<int> yBlocks(start[padded]);
        vector<long long> fill(start.begin(), start.end()-1);
        for (long long p = 0; p < numTiles*tileSize; p++) {
            int j = interactingAtoms[p];
            if (j >= 0 && j < padded)
                yBlocks[fill[j]++] = tiles[p/tileSize];
        }
        for (int s = 0; s < padded; s++)
            sort(yBlocks.begin()+start[s], yBlocks.begin()+start[s+1]);
        auto tileCount = [&](int y, int xBlock) {
            auto range = equal_range(yBlocks.begin()+start[y], yBlocks.begin()+start[y+1], xBlock);
            return (int) (range.second-range.first);
        };
        auto coverage = [&](int i, int j, int& inList) {
            int a = sortedOf[i], b = sortedOf[j];
            int inTile = contains(exclusionTileKeys, key(a/tileSize, b/tileSize)) ? 1 : 0;
            inList = tileCount(b, a/tileSize)+tileCount(a, b/tileSize)+(contains(singleKeys, key(a, b)) ? 1 : 0);
            return inTile;
        };

        // Exclusions per atom (System indices).
        vector<vector<int> > excluded(numAtoms);
        for (int e = 0; e < numExclusions; e++) {
            excluded[exclusionPairs[2*e]].push_back(exclusionPairs[2*e+1]);
            excluded[exclusionPairs[2*e+1]].push_back(exclusionPairs[2*e]);
        }
        int rows = 0;
        auto add = [&](int i, int j, int kind, double r) {
            if (rows >= maxReport)
                return;
            report[3*rows] = i;
            report[3*rows+1] = j;
            report[3*rows+2] = kind;
            reportDistance[rows++] = r;
        };
        auto distance = [&](int i, int j) {
            double r2 = 0;
            for (int k = 0; k < 3; k++) {
                double d = positions[3*j+k]-positions[3*i+k];
                if (box[k] > 0)
                    d -= box[k]*floor(d/box[k]+0.5);
                r2 += d*d;
            }
            return sqrt(r2);
        };
        for (int i = 0; i < numAtoms; i++)
            for (int j : excluded[i]) {
                if (j <= i)
                    continue;
                int inList;
                if (coverage(i, j, inList) != 1 || inList != 0) {
                    stats[3]++;
                    add(i, j, 3, distance(i, j));
                }
            }

        // Cell list over the periodic box (or the bounding box without one), cells at least the cutoff wide.
        bool periodic = box[0] > 0;
        double low[3], size[3];
        int cells[3];
        for (int k = 0; k < 3; k++) {
            low[k] = 0;
            size[k] = box[k];
            if (!periodic) {
                double hi = -1e300;
                low[k] = 1e300;
                for (int i = 0; i < numAtoms; i++) {
                    low[k] = min(low[k], positions[3*i+k]);
                    hi = max(hi, positions[3*i+k]);
                }
                size[k] = hi-low[k]+1e-9;
            }
            cells[k] = max(1, (int) floor(size[k]/cutoff));
            if (periodic && cells[k] < 3)
                throw OpenMMException("listcheck: fewer than 3 cells across the box");
        }
        auto cellOf = [&](int i, int k) {
            double x = positions[3*i+k]-low[k];
            if (periodic)
                x -= size[k]*floor(x/size[k]);
            return min(cells[k]-1, (int) floor(x/size[k]*cells[k]));
        };
        long long numCells = (long long) cells[0]*cells[1]*cells[2];
        vector<int> cellStart(numCells+1, 0), cellAtoms(numAtoms), cellIndex(numAtoms);
        for (int i = 0; i < numAtoms; i++) {
            cellIndex[i] = (cellOf(i, 0)*cells[1]+cellOf(i, 1))*cells[2]+cellOf(i, 2);
            cellStart[cellIndex[i]+1]++;
        }
        for (long long c = 0; c < numCells; c++)
            cellStart[c+1] += cellStart[c];
        vector<int> cellFill(cellStart.begin(), cellStart.end()-1);
        for (int i = 0; i < numAtoms; i++)
            cellAtoms[cellFill[cellIndex[i]]++] = i;
        double cutoff2 = cutoff*cutoff;
        for (int i = 0; i < numAtoms; i++) {
            int ci[3] = {cellOf(i, 0), cellOf(i, 1), cellOf(i, 2)};
            for (int dx = -1; dx <= 1; dx++)
            for (int dy = -1; dy <= 1; dy++)
            for (int dz = -1; dz <= 1; dz++) {
                int c[3] = {ci[0]+dx, ci[1]+dy, ci[2]+dz};
                bool skip = false;
                for (int k = 0; k < 3; k++) {
                    if (periodic)
                        c[k] = (c[k]+cells[k])%cells[k];
                    else if (c[k] < 0 || c[k] >= cells[k])
                        skip = true;
                }
                if (skip)
                    continue;
                long long cell = ((long long) c[0]*cells[1]+c[1])*cells[2]+c[2];
                for (int p = cellStart[cell]; p < cellStart[cell+1]; p++) {
                    int j = cellAtoms[p];
                    if (j <= i)
                        continue;
                    double r2 = 0;
                    for (int k = 0; k < 3; k++) {
                        double d = positions[3*j+k]-positions[3*i+k];
                        if (periodic)
                            d -= box[k]*floor(d/box[k]+0.5);
                        r2 += d*d;
                    }
                    if (r2 >= cutoff2 || find(excluded[i].begin(), excluded[i].end(), j) != excluded[i].end())
                        continue;
                    stats[0]++;
                    int inList;
                    int total = coverage(i, j, inList)+inList;
                    if (total == 0) {
                        stats[1]++;
                        add(i, j, 1, sqrt(r2));
                    }
                    else if (total > 1) {
                        stats[2]++;
                        add(i, j, 2, sqrt(r2));
                    }
                }
            }
        }
        return rows;
    }
    catch (const exception& e) {
        snprintf(error, errorSize, "%s", e.what());
        return -1;
    }
}
