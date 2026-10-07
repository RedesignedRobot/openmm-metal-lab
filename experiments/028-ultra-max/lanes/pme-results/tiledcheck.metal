#include <metal_stdlib>
using namespace metal;
typedef float real; typedef float2 real2; typedef float3 real3; typedef float4 real4;
#define KERNEL kernel
#define LOCAL threadgroup
#define GLOBAL device
#define RESTRICT
#define SYNC_THREADS threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device);
#define make_real3 float3
#define make_int3 int3
#define RECIP(x) (1.0f/(x))
#define USE_METAL 1
#define PME_ORDER 5
#define NUM_ATOMS 92224
#define GRID_SIZE_X 98
#define GRID_SIZE_Y 98
#define GRID_SIZE_Z 98
#define EPSILON_FACTOR 11.787089759563214f
#define CHARGE pos.w
#define LOCAL_ID lid
#define LOCAL_SIZE lsize
#define GROUP_ID gid
#define NUM_GROUPS ngroups
#define APPLY_PERIODIC_TO_POS(pos) {real scale = floor(pos.z*invPeriodicBoxSize.z); pos.x -= scale*periodicBoxVecZ.x; pos.y -= scale*periodicBoxVecZ.y; pos.z -= scale*periodicBoxVecZ.z;}
#define ATOMIC_ADD(dest, value) atomic_fetch_add_explicit((device atomic_float*) (dest), value, memory_order_relaxed)
#if defined(USE_METAL) && !defined(USE_FIXED_POINT_CHARGE_SPREADING)
#ifndef SPREAD_TILE_ATOMS
#define SPREAD_TILE_ATOMS 256
#endif
#define SPREAD_TILE_POINTS 7168

#if __METAL_VERSION__ >= 410
typedef atomic_float SpreadTileValue;

inline void addToTile(threadgroup SpreadTileValue* tile, int index, float value) {
    atomic_fetch_add_explicit(&tile[index], value, memory_order_relaxed);
}

inline float loadTile(threadgroup SpreadTileValue* tile, int index) {
    return atomic_load_explicit(&tile[index], memory_order_relaxed);
}
#else
typedef atomic_uint SpreadTileValue;

// Before MSL 4.1 there are no threadgroup float atomics, so add through a compare and swap on the bits.
inline void addToTile(threadgroup SpreadTileValue* tile, int index, float value) {
    uint expected = atomic_load_explicit(&tile[index], memory_order_relaxed);
    while (!atomic_compare_exchange_weak_explicit(&tile[index], &expected, as_type<uint>(as_type<float>(expected)+value), memory_order_relaxed, memory_order_relaxed))
        ;
}

inline float loadTile(threadgroup SpreadTileValue* tile, int index) {
    return as_type<float>(atomic_load_explicit(&tile[index], memory_order_relaxed));
}
#endif

// Each threadgroup spreads SPREAD_TILE_ATOMS consecutive atoms.  The stored atom order is spatially
// coherent, so their stencils usually fit in one threadgroup tile: accumulate there and flush each
// touched grid point with a single device atomic.  Chunks too spread out go straight to the grid.
KERNEL void gridSpreadChargeTiled(GLOBAL const real4* RESTRICT posq, GLOBAL real* RESTRICT pmeGrid,
        constant real4& periodicBoxSize, constant real4& invPeriodicBoxSize, constant real4& periodicBoxVecX, constant real4& periodicBoxVecY, constant real4& periodicBoxVecZ,
        constant real4& recipBoxVecX, constant real4& recipBoxVecY, constant real4& recipBoxVecZ, GLOBAL const int2* RESTRICT pmeAtomGridIndex,
#ifdef CHARGE_FROM_SIGEPS
        GLOBAL const float2* RESTRICT sigmaEpsilon
#else
        GLOBAL const real* RESTRICT charges
#endif
        , uint lid [[thread_position_in_threadgroup]], uint lsize [[threads_per_threadgroup]], uint gid [[threadgroup_position_in_grid]], uint ngroups [[threadgroups_per_grid]]) {
    LOCAL SpreadTileValue tile[SPREAD_TILE_POINTS];
    LOCAL atomic_int bounds[6];
    LOCAL int3 reference;
    real3 data[PME_ORDER];
    const real scale = RECIP((real) (PME_ORDER-1));
    for (int first = GROUP_ID*SPREAD_TILE_ATOMS; first < NUM_ATOMS; first += NUM_GROUPS*SPREAD_TILE_ATOMS) {
        int last = min(first+SPREAD_TILE_ATOMS, NUM_ATOMS);
        if (LOCAL_ID == 0) {
            real4 pos = posq[pmeAtomGridIndex[first].x];
            APPLY_PERIODIC_TO_POS(pos)
            real3 t = make_real3(pos.x*recipBoxVecX.x+pos.y*recipBoxVecY.x+pos.z*recipBoxVecZ.x,
                                 pos.y*recipBoxVecY.y+pos.z*recipBoxVecZ.y,
                                 pos.z*recipBoxVecZ.z);
            reference = make_int3(((int) ((t.x-floor(t.x))*GRID_SIZE_X)) % GRID_SIZE_X,
                                  ((int) ((t.y-floor(t.y))*GRID_SIZE_Y)) % GRID_SIZE_Y,
                                  ((int) ((t.z-floor(t.z))*GRID_SIZE_Z)) % GRID_SIZE_Z);
            for (int j = 0; j < 3; j++) {
                atomic_store_explicit(&bounds[j], GRID_SIZE_X+GRID_SIZE_Y+GRID_SIZE_Z, memory_order_relaxed);
                atomic_store_explicit(&bounds[j+3], -(GRID_SIZE_X+GRID_SIZE_Y+GRID_SIZE_Z), memory_order_relaxed);
            }
        }
        SYNC_THREADS;

        // Two passes over the chunk: the first finds the bounding box of the atoms' cells, as offsets from the
        // first atom's cell unwrapped across the periodic boundary, and the second spreads.

        int3 low, size;
        bool useTile = false;
        for (int pass = 0; pass < 2; pass++) {
            for (int i = first+LOCAL_ID; i < last; i += LOCAL_SIZE) {
                int atom = pmeAtomGridIndex[i].x;
                real4 pos = posq[atom];
#ifdef CHARGE_FROM_SIGEPS
                const float2 sigEps = sigmaEpsilon[atom];
                const real charge = 8*sigEps.x*sigEps.x*sigEps.x*sigEps.y;
#else
                const real charge = (CHARGE)*EPSILON_FACTOR;
#endif
                if (charge == 0)
                    continue;
                APPLY_PERIODIC_TO_POS(pos)
                real3 t = make_real3(pos.x*recipBoxVecX.x+pos.y*recipBoxVecY.x+pos.z*recipBoxVecZ.x,
                                     pos.y*recipBoxVecY.y+pos.z*recipBoxVecZ.y,
                                     pos.z*recipBoxVecZ.z);
                t.x = (t.x-floor(t.x))*GRID_SIZE_X;
                t.y = (t.y-floor(t.y))*GRID_SIZE_Y;
                t.z = (t.z-floor(t.z))*GRID_SIZE_Z;
                int3 gridIndex = make_int3(((int) t.x) % GRID_SIZE_X,
                                           ((int) t.y) % GRID_SIZE_Y,
                                           ((int) t.z) % GRID_SIZE_Z);
                int3 offset = gridIndex-reference;
                offset.x += (offset.x > GRID_SIZE_X/2 ? -GRID_SIZE_X : (offset.x < -GRID_SIZE_X/2 ? GRID_SIZE_X : 0));
                offset.y += (offset.y > GRID_SIZE_Y/2 ? -GRID_SIZE_Y : (offset.y < -GRID_SIZE_Y/2 ? GRID_SIZE_Y : 0));
                offset.z += (offset.z > GRID_SIZE_Z/2 ? -GRID_SIZE_Z : (offset.z < -GRID_SIZE_Z/2 ? GRID_SIZE_Z : 0));
                if (pass == 0) {
                    atomic_fetch_min_explicit(&bounds[0], offset.x, memory_order_relaxed);
                    atomic_fetch_min_explicit(&bounds[1], offset.y, memory_order_relaxed);
                    atomic_fetch_min_explicit(&bounds[2], offset.z, memory_order_relaxed);
                    atomic_fetch_max_explicit(&bounds[3], offset.x, memory_order_relaxed);
                    atomic_fetch_max_explicit(&bounds[4], offset.y, memory_order_relaxed);
                    atomic_fetch_max_explicit(&bounds[5], offset.z, memory_order_relaxed);
                    continue;
                }
                real3 dr = make_real3(t.x-(int) t.x, t.y-(int) t.y, t.z-(int) t.z);
                data[PME_ORDER-1] = make_real3(0);
                data[1] = dr;
                data[0] = make_real3(1)-dr;
                for (int j = 3; j < PME_ORDER; j++) {
                    real div = RECIP((real) (j-1));
                    data[j-1] = div*dr*data[j-2];
                    for (int k = 1; k < (j-1); k++)
                        data[j-k-1] = div*((dr+make_real3(k))*data[j-k-2] + (make_real3(j-k)-dr)*data[j-k-1]);
                    data[0] = div*(make_real3(1)-dr)*data[0];
                }
                data[PME_ORDER-1] = scale*dr*data[PME_ORDER-2];
                for (int j = 1; j < (PME_ORDER-1); j++)
                    data[PME_ORDER-j-1] = scale*((dr+make_real3(j))*data[PME_ORDER-j-2] + (make_real3(PME_ORDER-j)-dr)*data[PME_ORDER-j-1]);
                data[0] = scale*(make_real3(1)-dr)*data[0];
                int3 local = offset-low;
                for (int ix = 0; ix < PME_ORDER; ix++) {
                    int xbase = gridIndex.x+ix;
                    xbase -= (xbase >= GRID_SIZE_X ? GRID_SIZE_X : 0);
                    xbase = xbase*GRID_SIZE_Y*GRID_SIZE_Z;
                    real dx = charge*data[ix].x;
                    for (int iy = 0; iy < PME_ORDER; iy++) {
                        int ybase = gridIndex.y+iy;
                        ybase -= (ybase >= GRID_SIZE_Y ? GRID_SIZE_Y : 0);
                        ybase = xbase+ybase*GRID_SIZE_Z;
                        int tileBase = ((local.x+ix)*size.y+local.y+iy)*size.z+local.z;
                        real dxdy = dx*data[iy].y;
                        for (int iz = 0; iz < PME_ORDER; iz++) {
                            real add = dxdy*data[iz].z;
                            if (useTile)
                                addToTile(tile, tileBase+iz, add);
                            else {
                                int zindex = gridIndex.z+iz;
                                zindex -= (zindex >= GRID_SIZE_Z ? GRID_SIZE_Z : 0);
                                ATOMIC_ADD(&pmeGrid[ybase+zindex], add);
                            }
                        }
                    }
                }
            }
            if (pass == 0) {
                SYNC_THREADS;
                low = make_int3(atomic_load_explicit(&bounds[0], memory_order_relaxed), atomic_load_explicit(&bounds[1], memory_order_relaxed), atomic_load_explicit(&bounds[2], memory_order_relaxed));
                size = make_int3(atomic_load_explicit(&bounds[3], memory_order_relaxed), atomic_load_explicit(&bounds[4], memory_order_relaxed), atomic_load_explicit(&bounds[5], memory_order_relaxed))-low+make_int3(PME_ORDER);
                useTile = (size.x > 0 && size.x*size.y*size.z <= SPREAD_TILE_POINTS); // size.x <= 0 when every atom is uncharged
                if (useTile) {
                    for (int j = LOCAL_ID; j < size.x*size.y*size.z; j += LOCAL_SIZE)
                        atomic_store_explicit(&tile[j], 0, memory_order_relaxed);
                    SYNC_THREADS;
                }
            }
        }
        if (useTile) {
            SYNC_THREADS;
            int3 origin = reference+low;
            for (int j = LOCAL_ID; j < size.x*size.y*size.z; j += LOCAL_SIZE) {
                real value = loadTile(tile, j);
                if (value == 0)
                    continue;
                int x = (origin.x+j/(size.y*size.z)+2*GRID_SIZE_X)%GRID_SIZE_X;
                int y = (origin.y+(j/size.z)%size.y+2*GRID_SIZE_Y)%GRID_SIZE_Y;
                int z = (origin.z+j%size.z+2*GRID_SIZE_Z)%GRID_SIZE_Z;
                ATOMIC_ADD(&pmeGrid[(x*GRID_SIZE_Y+y)*GRID_SIZE_Z+z], value);
            }
        }
        SYNC_THREADS;
    }
}
#endif

