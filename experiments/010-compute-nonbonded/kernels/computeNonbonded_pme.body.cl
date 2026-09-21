#define WARPS_PER_GROUP (FORCE_WORK_GROUP_SIZE/TILE_SIZE)

typedef struct {
    real x, y, z;
    real q;
    real fx, fy, fz;
    float nonbonded2_sigmaEpsilon_x;
float nonbonded2_sigmaEpsilon_y;

#ifndef PARAMETER_SIZE_IS_EVEN
    real padding;
#endif
} AtomData;

/**
 * Compute nonbonded interactions.
 */
__kernel void computeNonbonded(
        __global unsigned long* restrict forceBuffers,
        __global mixed* restrict energyBuffer, __global const real4* restrict posq, __global const unsigned int* restrict exclusions,
        __global const int2* restrict exclusionTiles, unsigned int startTileIndex, unsigned long numTileIndices
#ifdef USE_CUTOFF
        , __global const int* restrict tiles, __global const unsigned int* restrict interactionCount, real4 periodicBoxSize, real4 invPeriodicBoxSize,
        real4 periodicBoxVecX, real4 periodicBoxVecY, real4 periodicBoxVecZ, unsigned int maxTiles, __global const real4* restrict blockCenter,
        __global const real4* restrict blockSize, __global const int* restrict interactingAtoms
#endif
        , __global const float2* restrict global_nonbonded2_sigmaEpsilon) {
    const unsigned int totalWarps = get_global_size(0)/TILE_SIZE;
    const unsigned int warp = get_global_id(0)/TILE_SIZE;
    const unsigned int tgx = get_local_id(0) & (TILE_SIZE-1);
    const unsigned int tbx = get_local_id(0) - tgx;
    const unsigned int localAtomIndex = get_local_id(0);
    mixed energy = 0;
    
    __local AtomData localData[FORCE_WORK_GROUP_SIZE];

    // First loop: process tiles that contain exclusions.

    const unsigned int firstExclusionTile = FIRST_EXCLUSION_TILE+warp*(LAST_EXCLUSION_TILE-FIRST_EXCLUSION_TILE)/totalWarps;
    const unsigned int lastExclusionTile = FIRST_EXCLUSION_TILE+(warp+1)*(LAST_EXCLUSION_TILE-FIRST_EXCLUSION_TILE)/totalWarps;
    for (int pos = firstExclusionTile; pos < lastExclusionTile; pos++) {
        const int2 tileIndices = exclusionTiles[pos];
        const unsigned int x = tileIndices.x;
        const unsigned int y = tileIndices.y;
        real4 force = 0;
        unsigned int atom1 = x*TILE_SIZE + tgx;
        real4 posq1 = posq[atom1];
        float2 nonbonded2_sigmaEpsilon1 = global_nonbonded2_sigmaEpsilon[atom1];

#ifdef USE_EXCLUSIONS
        unsigned int excl = exclusions[pos*TILE_SIZE+tgx];
#endif
        const bool hasExclusions = true;
        if (x == y) {
            // This tile is on the diagonal.

            localData[localAtomIndex].x = posq1.x;
            localData[localAtomIndex].y = posq1.y;
            localData[localAtomIndex].z = posq1.z;
            localData[localAtomIndex].q = posq1.w;
            localData[localAtomIndex].nonbonded2_sigmaEpsilon_x = nonbonded2_sigmaEpsilon1.x;
localData[localAtomIndex].nonbonded2_sigmaEpsilon_y = nonbonded2_sigmaEpsilon1.y;

            SYNC_WARPS;
            for (unsigned int j = 0; j < TILE_SIZE; j++) {
                int atom2 = tbx+j;
                real4 posq2 = (real4) (localData[atom2].x, localData[atom2].y, localData[atom2].z, localData[atom2].q);
                real4 delta = (real4) (posq2.xyz - posq1.xyz, 0);
#ifdef USE_PERIODIC
                APPLY_PERIODIC_TO_DELTA(delta)
#endif
                real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
                real invR = RSQRT(r2);
                real r = r2*invR;
                float2 nonbonded2_sigmaEpsilon2 = (float2) (localData[atom2].nonbonded2_sigmaEpsilon_x, localData[atom2].nonbonded2_sigmaEpsilon_y);

                atom2 = y*TILE_SIZE+j;
#ifdef USE_SYMMETRIC
                real dEdR = 0;
#else
                real4 dEdR1 = (real4) 0;
                real4 dEdR2 = (real4) 0;
#endif
#ifdef USE_EXCLUSIONS
                bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
#endif
                real tempEnergy = 0;
                const real interactionScale = 0.5f;
                {
#if 1
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
    const real alphaR = 2.92028987e+00f*r;
    const real expAlphaRSqr = EXP(-alphaR*alphaR);
#if 1
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
#else
    const real prefactor = 0.0f;
#endif

#ifdef USE_DOUBLE_PRECISION
    const real erfcAlphaR = erfc(alphaR);
#else
    // This approximation for erfc is from Abramowitz and Stegun (1964) p. 299.  They cite the following as
    // the original source: C. Hastings, Jr., Approximations for Digital Computers (1955).  It has a maximum
    // error of 1.5e-7.

    const real t = RECIP(1.0f+0.3275911f*alphaR);
    const real erfcAlphaR = (0.254829592f+(-0.284496736f+(1.421413741f+(-1.453152027f+1.061405429f*t)*t)*t)*t)*t*expAlphaRSqr;
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real eps = nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y;
    real epssig6 = sig6*eps;
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = epssig6*(sig6 - 1.0f);
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
#if 0
    // The multiplicative term to correct for the multiplicative terms that are always
    // present in reciprocal space.
    const real dispersionAlphaR = EWALD_DISPERSION_ALPHA*r;
    const real dar2 = dispersionAlphaR*dispersionAlphaR;
    const real dar4 = dar2*dar2;
    const real dar6 = dar4*dar2;
    const real invR2 = invR*invR;
    const real expDar2 = EXP(-dar2);
    const float2 sigExpProd = nonbonded2_sigmaEpsilon1*nonbonded2_sigmaEpsilon2;
    const real c6 = 64*sigExpProd.x*sigExpProd.x*sigExpProd.x*sigExpProd.y;
    const real coef = invR2*invR2*invR2*c6;
    const real eprefac = 1.0f + dar2 + 0.5f*dar4;
    const real dprefac = eprefac + dar6/6.0f;
    // The multiplicative grid term
    ljEnergy += coef*(1.0f - expDar2*eprefac);
    tempForce += 6.0f*coef*(1.0f - expDar2*dprefac);
    // The potential shift accounts for the step at the cutoff introduced by the
    // transition from additive to multiplicative combintion rules and is only
    // needed for the real (not excluded) terms.  By addin these terms to ljEnergy
    // instead of tempEnergy here, the includeInteraction mask is correctly applied.
    sig2 = sig*sig;
    sig6 = sig2*sig2*sig2*INVCUT6;
    epssig6 = eps*sig6;
    // The additive part of the potential shift
    ljEnergy += epssig6*(1.0f - sig6);
    // The multiplicative part of the potential shift
    ljEnergy += MULTSHIFT6*c6;
#endif
    tempForce += prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? ljEnergy + prefactor*erfcAlphaR : 0;
#else
    tempForce = prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? prefactor*erfcAlphaR : 0;
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#else
#ifdef USE_CUTOFF
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
#else
    unsigned int includeInteraction = (!isExcluded);
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real epssig6 = sig6*(nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y);
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = includeInteraction ? epssig6*(sig6 - 1) : 0;
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
    tempEnergy += ljEnergy;
#endif
#if 1
  #ifdef USE_CUTOFF
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w;
    tempForce += prefactor*(invR - 2.0f*6.72815135e-01f*r2);
    tempEnergy += includeInteraction ? prefactor*(invR + 6.72815135e-01f*r2 - 1.65609137e+00f) : 0;
  #else
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
    tempForce += prefactor;
    tempEnergy += includeInteraction ? prefactor : 0;
  #endif
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#endif
}


                energy += 0.5f*tempEnergy;
#ifdef INCLUDE_FORCES
#ifdef USE_SYMMETRIC
                force.xyz -= delta.xyz*dEdR;
#else
                force.xyz -= dEdR1.xyz;
#endif
#endif
#ifdef USE_EXCLUSIONS
                excl >>= 1;
#endif
                SYNC_WARPS;
            }
        }
        else {
            // This is an off-diagonal tile.

            unsigned int j = y*TILE_SIZE + tgx;
            real4 tempPosq = posq[j];
            localData[localAtomIndex].x = tempPosq.x;
            localData[localAtomIndex].y = tempPosq.y;
            localData[localAtomIndex].z = tempPosq.z;
            localData[localAtomIndex].q = tempPosq.w;
            float2 temp_nonbonded2_sigmaEpsilon = global_nonbonded2_sigmaEpsilon[j];
localData[localAtomIndex].nonbonded2_sigmaEpsilon_x = temp_nonbonded2_sigmaEpsilon.x;
localData[localAtomIndex].nonbonded2_sigmaEpsilon_y = temp_nonbonded2_sigmaEpsilon.y;

            localData[localAtomIndex].fx = 0;
            localData[localAtomIndex].fy = 0;
            localData[localAtomIndex].fz = 0;
            SYNC_WARPS;
#ifdef USE_EXCLUSIONS
            excl = (excl >> tgx) | (excl << (TILE_SIZE - tgx));
#endif
            unsigned int tj = tgx;
            for (j = 0; j < TILE_SIZE; j++) {
                int atom2 = tbx+tj;
                real4 posq2 = (real4) (localData[atom2].x, localData[atom2].y, localData[atom2].z, localData[atom2].q);
                real4 delta = (real4) (posq2.xyz - posq1.xyz, 0);
#ifdef USE_PERIODIC
                APPLY_PERIODIC_TO_DELTA(delta)
#endif
                real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef PRUNE_BY_CUTOFF
                if (r2 < MAX_CUTOFF*MAX_CUTOFF) {
#endif
                    real invR = RSQRT(r2);
                    real r = r2*invR;
                    float2 nonbonded2_sigmaEpsilon2 = (float2) (localData[atom2].nonbonded2_sigmaEpsilon_x, localData[atom2].nonbonded2_sigmaEpsilon_y);

                    atom2 = y*TILE_SIZE+tj;
#ifdef USE_SYMMETRIC
                    real dEdR = 0;
#else
                    real4 dEdR1 = (real4) 0;
                    real4 dEdR2 = (real4) 0;
#endif
#ifdef USE_EXCLUSIONS
                    bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS || !(excl & 0x1));
#endif
                    real tempEnergy = 0;
                    const real interactionScale = 1.0f;
                    {
#if 1
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
    const real alphaR = 2.92028987e+00f*r;
    const real expAlphaRSqr = EXP(-alphaR*alphaR);
#if 1
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
#else
    const real prefactor = 0.0f;
#endif

#ifdef USE_DOUBLE_PRECISION
    const real erfcAlphaR = erfc(alphaR);
#else
    // This approximation for erfc is from Abramowitz and Stegun (1964) p. 299.  They cite the following as
    // the original source: C. Hastings, Jr., Approximations for Digital Computers (1955).  It has a maximum
    // error of 1.5e-7.

    const real t = RECIP(1.0f+0.3275911f*alphaR);
    const real erfcAlphaR = (0.254829592f+(-0.284496736f+(1.421413741f+(-1.453152027f+1.061405429f*t)*t)*t)*t)*t*expAlphaRSqr;
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real eps = nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y;
    real epssig6 = sig6*eps;
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = epssig6*(sig6 - 1.0f);
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
#if 0
    // The multiplicative term to correct for the multiplicative terms that are always
    // present in reciprocal space.
    const real dispersionAlphaR = EWALD_DISPERSION_ALPHA*r;
    const real dar2 = dispersionAlphaR*dispersionAlphaR;
    const real dar4 = dar2*dar2;
    const real dar6 = dar4*dar2;
    const real invR2 = invR*invR;
    const real expDar2 = EXP(-dar2);
    const float2 sigExpProd = nonbonded2_sigmaEpsilon1*nonbonded2_sigmaEpsilon2;
    const real c6 = 64*sigExpProd.x*sigExpProd.x*sigExpProd.x*sigExpProd.y;
    const real coef = invR2*invR2*invR2*c6;
    const real eprefac = 1.0f + dar2 + 0.5f*dar4;
    const real dprefac = eprefac + dar6/6.0f;
    // The multiplicative grid term
    ljEnergy += coef*(1.0f - expDar2*eprefac);
    tempForce += 6.0f*coef*(1.0f - expDar2*dprefac);
    // The potential shift accounts for the step at the cutoff introduced by the
    // transition from additive to multiplicative combintion rules and is only
    // needed for the real (not excluded) terms.  By addin these terms to ljEnergy
    // instead of tempEnergy here, the includeInteraction mask is correctly applied.
    sig2 = sig*sig;
    sig6 = sig2*sig2*sig2*INVCUT6;
    epssig6 = eps*sig6;
    // The additive part of the potential shift
    ljEnergy += epssig6*(1.0f - sig6);
    // The multiplicative part of the potential shift
    ljEnergy += MULTSHIFT6*c6;
#endif
    tempForce += prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? ljEnergy + prefactor*erfcAlphaR : 0;
#else
    tempForce = prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? prefactor*erfcAlphaR : 0;
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#else
#ifdef USE_CUTOFF
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
#else
    unsigned int includeInteraction = (!isExcluded);
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real epssig6 = sig6*(nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y);
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = includeInteraction ? epssig6*(sig6 - 1) : 0;
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
    tempEnergy += ljEnergy;
#endif
#if 1
  #ifdef USE_CUTOFF
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w;
    tempForce += prefactor*(invR - 2.0f*6.72815135e-01f*r2);
    tempEnergy += includeInteraction ? prefactor*(invR + 6.72815135e-01f*r2 - 1.65609137e+00f) : 0;
  #else
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
    tempForce += prefactor;
    tempEnergy += includeInteraction ? prefactor : 0;
  #endif
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#endif
}


                    energy += tempEnergy;
#ifdef INCLUDE_FORCES
#ifdef USE_SYMMETRIC
                    delta.xyz *= dEdR;
                    force.xyz -= delta.xyz;
                    localData[tbx+tj].fx += delta.x;
                    localData[tbx+tj].fy += delta.y;
                    localData[tbx+tj].fz += delta.z;
#else
                    force.xyz -= dEdR1.xyz;
                    localData[tbx+tj].fx += dEdR2.x;
                    localData[tbx+tj].fy += dEdR2.y;
                    localData[tbx+tj].fz += dEdR2.z;
#endif
#endif
#ifdef PRUNE_BY_CUTOFF
                }
#endif
#ifdef USE_EXCLUSIONS
                excl >>= 1;
#endif
                tj = (tj + 1) & (TILE_SIZE - 1);
                SYNC_WARPS;
            }
        }

        // Write results.

#ifdef INCLUDE_FORCES
        unsigned int offset = x*TILE_SIZE + tgx;
        ATOMIC_ADD(&forceBuffers[offset], (mm_ulong) realToFixedPoint(force.x));
        ATOMIC_ADD(&forceBuffers[offset+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force.y));
        ATOMIC_ADD(&forceBuffers[offset+2*PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force.z));
        if (x != y) {
            offset = y*TILE_SIZE + tgx;
            ATOMIC_ADD(&forceBuffers[offset], (mm_ulong) realToFixedPoint(localData[get_local_id(0)].fx));
            ATOMIC_ADD(&forceBuffers[offset+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(localData[get_local_id(0)].fy));
            ATOMIC_ADD(&forceBuffers[offset+2*PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(localData[get_local_id(0)].fz));
        }
#endif
    }

    // Second loop: tiles without exclusions, either from the neighbor list (with cutoff) or just enumerating all
    // of them (no cutoff).

#ifdef USE_NEIGHBOR_LIST
    unsigned int numTiles = interactionCount[0];
    if (numTiles > maxTiles)
        return; // There wasn't enough memory for the neighbor list.
    int pos = (int) (warp*(long)numTiles/totalWarps);
    int end = (int) ((warp+1)*(long)numTiles/totalWarps);
#else
    int pos = (int) (startTileIndex+warp*numTileIndices/totalWarps);
    int end = (int) (startTileIndex+(warp+1)*numTileIndices/totalWarps);
#endif
    int skipBase = 0;
    int currentSkipIndex = tbx;
    __local int atomIndices[FORCE_WORK_GROUP_SIZE];
    __local volatile int skipTiles[FORCE_WORK_GROUP_SIZE];
    skipTiles[get_local_id(0)] = -1;

    while (pos < end) {
        const bool hasExclusions = false;
        real4 force = 0;
        bool includeTile = true;

        // Extract the coordinates of this tile.

        int x, y;
        bool singlePeriodicCopy = false;
#ifdef USE_NEIGHBOR_LIST
        x = tiles[pos];
        real4 blockSizeX = blockSize[x];
        singlePeriodicCopy = (0.5f*periodicBoxSize.x-blockSizeX.x >= MAX_CUTOFF &&
                              0.5f*periodicBoxSize.y-blockSizeX.y >= MAX_CUTOFF &&
                              0.5f*periodicBoxSize.z-blockSizeX.z >= MAX_CUTOFF);
#else
        y = (int) floor(NUM_BLOCKS+0.5f-SQRT((NUM_BLOCKS+0.5f)*(NUM_BLOCKS+0.5f)-2*pos));
        x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
        if (x < y || x >= NUM_BLOCKS) { // Occasionally happens due to roundoff error.
            y += (x < y ? -1 : 1);
            x = (pos-y*NUM_BLOCKS+y*(y+1)/2);
        }

        // Skip over tiles that have exclusions, since they were already processed.

        SYNC_WARPS;
        while (skipTiles[tbx+TILE_SIZE-1] < pos) {
            SYNC_WARPS;
            if (skipBase+tgx < NUM_TILES_WITH_EXCLUSIONS) {
                int2 tile = exclusionTiles[skipBase+tgx];
                skipTiles[get_local_id(0)] = tile.x + tile.y*NUM_BLOCKS - tile.y*(tile.y+1)/2;
            }
            else
                skipTiles[get_local_id(0)] = end;
            skipBase += TILE_SIZE;
            currentSkipIndex = tbx;
            SYNC_WARPS;
        }
        while (skipTiles[currentSkipIndex] < pos)
            currentSkipIndex++;
        includeTile = (skipTiles[currentSkipIndex] != pos);
#endif
        if (includeTile) {
            unsigned int atom1 = x*TILE_SIZE + tgx;

            // Load atom data for this tile.

            real4 posq1 = posq[atom1];
            float2 nonbonded2_sigmaEpsilon1 = global_nonbonded2_sigmaEpsilon[atom1];

#ifdef USE_NEIGHBOR_LIST
            unsigned int j = interactingAtoms[pos*TILE_SIZE+tgx];
#else
            unsigned int j = y*TILE_SIZE + tgx;
#endif
            atomIndices[get_local_id(0)] = j;
            if (j < PADDED_NUM_ATOMS) {
                real4 tempPosq = posq[j];
                localData[localAtomIndex].x = tempPosq.x;
                localData[localAtomIndex].y = tempPosq.y;
                localData[localAtomIndex].z = tempPosq.z;
                localData[localAtomIndex].q = tempPosq.w;
                float2 temp_nonbonded2_sigmaEpsilon = global_nonbonded2_sigmaEpsilon[j];
localData[localAtomIndex].nonbonded2_sigmaEpsilon_x = temp_nonbonded2_sigmaEpsilon.x;
localData[localAtomIndex].nonbonded2_sigmaEpsilon_y = temp_nonbonded2_sigmaEpsilon.y;

                localData[localAtomIndex].fx = 0;
                localData[localAtomIndex].fy = 0;
                localData[localAtomIndex].fz = 0;
            }
            else {
                localData[localAtomIndex].x = 0;
                localData[localAtomIndex].y = 0;
                localData[localAtomIndex].z = 0;
                localData[localAtomIndex].nonbonded2_sigmaEpsilon_x = 0;
localData[localAtomIndex].nonbonded2_sigmaEpsilon_y = 0;

            }
            SYNC_WARPS;
#ifdef USE_PERIODIC
            if (singlePeriodicCopy) {
                // The box is small enough that we can just translate all the atoms into a single periodic
                // box, then skip having to apply periodic boundary conditions later.

                real4 blockCenterX = blockCenter[x];
                APPLY_PERIODIC_TO_POS_WITH_CENTER(posq1, blockCenterX)
                APPLY_PERIODIC_TO_POS_WITH_CENTER(localData[localAtomIndex], blockCenterX)
                SYNC_WARPS;
                unsigned int tj = tgx;
                for (j = 0; j < TILE_SIZE; j++) {
                    int atom2 = tbx+tj;
                    real4 posq2 = (real4) (localData[atom2].x, localData[atom2].y, localData[atom2].z, localData[atom2].q);
                    real4 delta = (real4) (posq2.xyz - posq1.xyz, 0);
                    real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef PRUNE_BY_CUTOFF
                    if (r2 < MAX_CUTOFF*MAX_CUTOFF) {
#endif
                        real invR = RSQRT(r2);
                        real r = r2*invR;
                        float2 nonbonded2_sigmaEpsilon2 = (float2) (localData[atom2].nonbonded2_sigmaEpsilon_x, localData[atom2].nonbonded2_sigmaEpsilon_y);

                        atom2 = atomIndices[tbx+tj];
#ifdef USE_SYMMETRIC
                        real dEdR = 0;
#else
                        real4 dEdR1 = (real4) 0;
                        real4 dEdR2 = (real4) 0;
#endif
#ifdef USE_EXCLUSIONS
                        bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS);
#endif
                        real tempEnergy = 0;
                        const real interactionScale = 1.0f;
                        {
#if 1
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
    const real alphaR = 2.92028987e+00f*r;
    const real expAlphaRSqr = EXP(-alphaR*alphaR);
#if 1
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
#else
    const real prefactor = 0.0f;
#endif

#ifdef USE_DOUBLE_PRECISION
    const real erfcAlphaR = erfc(alphaR);
#else
    // This approximation for erfc is from Abramowitz and Stegun (1964) p. 299.  They cite the following as
    // the original source: C. Hastings, Jr., Approximations for Digital Computers (1955).  It has a maximum
    // error of 1.5e-7.

    const real t = RECIP(1.0f+0.3275911f*alphaR);
    const real erfcAlphaR = (0.254829592f+(-0.284496736f+(1.421413741f+(-1.453152027f+1.061405429f*t)*t)*t)*t)*t*expAlphaRSqr;
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real eps = nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y;
    real epssig6 = sig6*eps;
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = epssig6*(sig6 - 1.0f);
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
#if 0
    // The multiplicative term to correct for the multiplicative terms that are always
    // present in reciprocal space.
    const real dispersionAlphaR = EWALD_DISPERSION_ALPHA*r;
    const real dar2 = dispersionAlphaR*dispersionAlphaR;
    const real dar4 = dar2*dar2;
    const real dar6 = dar4*dar2;
    const real invR2 = invR*invR;
    const real expDar2 = EXP(-dar2);
    const float2 sigExpProd = nonbonded2_sigmaEpsilon1*nonbonded2_sigmaEpsilon2;
    const real c6 = 64*sigExpProd.x*sigExpProd.x*sigExpProd.x*sigExpProd.y;
    const real coef = invR2*invR2*invR2*c6;
    const real eprefac = 1.0f + dar2 + 0.5f*dar4;
    const real dprefac = eprefac + dar6/6.0f;
    // The multiplicative grid term
    ljEnergy += coef*(1.0f - expDar2*eprefac);
    tempForce += 6.0f*coef*(1.0f - expDar2*dprefac);
    // The potential shift accounts for the step at the cutoff introduced by the
    // transition from additive to multiplicative combintion rules and is only
    // needed for the real (not excluded) terms.  By addin these terms to ljEnergy
    // instead of tempEnergy here, the includeInteraction mask is correctly applied.
    sig2 = sig*sig;
    sig6 = sig2*sig2*sig2*INVCUT6;
    epssig6 = eps*sig6;
    // The additive part of the potential shift
    ljEnergy += epssig6*(1.0f - sig6);
    // The multiplicative part of the potential shift
    ljEnergy += MULTSHIFT6*c6;
#endif
    tempForce += prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? ljEnergy + prefactor*erfcAlphaR : 0;
#else
    tempForce = prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? prefactor*erfcAlphaR : 0;
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#else
#ifdef USE_CUTOFF
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
#else
    unsigned int includeInteraction = (!isExcluded);
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real epssig6 = sig6*(nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y);
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = includeInteraction ? epssig6*(sig6 - 1) : 0;
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
    tempEnergy += ljEnergy;
#endif
#if 1
  #ifdef USE_CUTOFF
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w;
    tempForce += prefactor*(invR - 2.0f*6.72815135e-01f*r2);
    tempEnergy += includeInteraction ? prefactor*(invR + 6.72815135e-01f*r2 - 1.65609137e+00f) : 0;
  #else
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
    tempForce += prefactor;
    tempEnergy += includeInteraction ? prefactor : 0;
  #endif
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#endif
}


                        energy += tempEnergy;
#ifdef INCLUDE_FORCES
#ifdef USE_SYMMETRIC
                        delta.xyz *= dEdR;
                        force.xyz -= delta.xyz;
                        localData[tbx+tj].fx += delta.x;
                        localData[tbx+tj].fy += delta.y;
                        localData[tbx+tj].fz += delta.z;
#else
                        force.xyz -= dEdR1.xyz;
                        localData[tbx+tj].fx += dEdR2.x;
                        localData[tbx+tj].fy += dEdR2.y;
                        localData[tbx+tj].fz += dEdR2.z;
#endif
#endif
#ifdef PRUNE_BY_CUTOFF
                    }
#endif
                    tj = (tj + 1) & (TILE_SIZE - 1);
                    SYNC_WARPS;
                }
            }
            else
#endif
            {
                // We need to apply periodic boundary conditions separately for each interaction.

                unsigned int tj = tgx;
                for (j = 0; j < TILE_SIZE; j++) {
                    int atom2 = tbx+tj;
                    real4 posq2 = (real4) (localData[atom2].x, localData[atom2].y, localData[atom2].z, localData[atom2].q);
                    real4 delta = (real4) (posq2.xyz - posq1.xyz, 0);
#ifdef USE_PERIODIC
                    APPLY_PERIODIC_TO_DELTA(delta)
#endif
                    real r2 = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z;
#ifdef PRUNE_BY_CUTOFF
                    if (r2 < MAX_CUTOFF*MAX_CUTOFF) {
#endif
                        real invR = RSQRT(r2);
                        real r = r2*invR;
                        float2 nonbonded2_sigmaEpsilon2 = (float2) (localData[atom2].nonbonded2_sigmaEpsilon_x, localData[atom2].nonbonded2_sigmaEpsilon_y);

                        atom2 = atomIndices[tbx+tj];
#ifdef USE_SYMMETRIC
                        real dEdR = 0;
#else
                        real4 dEdR1 = (real4) 0;
                        real4 dEdR2 = (real4) 0;
#endif
#ifdef USE_EXCLUSIONS
                        bool isExcluded = (atom1 >= NUM_ATOMS || atom2 >= NUM_ATOMS);
#endif
                        real tempEnergy = 0;
                        const real interactionScale = 1.0f;
                        {
#if 1
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
    const real alphaR = 2.92028987e+00f*r;
    const real expAlphaRSqr = EXP(-alphaR*alphaR);
#if 1
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
#else
    const real prefactor = 0.0f;
#endif

#ifdef USE_DOUBLE_PRECISION
    const real erfcAlphaR = erfc(alphaR);
#else
    // This approximation for erfc is from Abramowitz and Stegun (1964) p. 299.  They cite the following as
    // the original source: C. Hastings, Jr., Approximations for Digital Computers (1955).  It has a maximum
    // error of 1.5e-7.

    const real t = RECIP(1.0f+0.3275911f*alphaR);
    const real erfcAlphaR = (0.254829592f+(-0.284496736f+(1.421413741f+(-1.453152027f+1.061405429f*t)*t)*t)*t)*t*expAlphaRSqr;
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real eps = nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y;
    real epssig6 = sig6*eps;
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = epssig6*(sig6 - 1.0f);
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
#if 0
    // The multiplicative term to correct for the multiplicative terms that are always
    // present in reciprocal space.
    const real dispersionAlphaR = EWALD_DISPERSION_ALPHA*r;
    const real dar2 = dispersionAlphaR*dispersionAlphaR;
    const real dar4 = dar2*dar2;
    const real dar6 = dar4*dar2;
    const real invR2 = invR*invR;
    const real expDar2 = EXP(-dar2);
    const float2 sigExpProd = nonbonded2_sigmaEpsilon1*nonbonded2_sigmaEpsilon2;
    const real c6 = 64*sigExpProd.x*sigExpProd.x*sigExpProd.x*sigExpProd.y;
    const real coef = invR2*invR2*invR2*c6;
    const real eprefac = 1.0f + dar2 + 0.5f*dar4;
    const real dprefac = eprefac + dar6/6.0f;
    // The multiplicative grid term
    ljEnergy += coef*(1.0f - expDar2*eprefac);
    tempForce += 6.0f*coef*(1.0f - expDar2*dprefac);
    // The potential shift accounts for the step at the cutoff introduced by the
    // transition from additive to multiplicative combintion rules and is only
    // needed for the real (not excluded) terms.  By addin these terms to ljEnergy
    // instead of tempEnergy here, the includeInteraction mask is correctly applied.
    sig2 = sig*sig;
    sig6 = sig2*sig2*sig2*INVCUT6;
    epssig6 = eps*sig6;
    // The additive part of the potential shift
    ljEnergy += epssig6*(1.0f - sig6);
    // The multiplicative part of the potential shift
    ljEnergy += MULTSHIFT6*c6;
#endif
    tempForce += prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? ljEnergy + prefactor*erfcAlphaR : 0;
#else
    tempForce = prefactor*(erfcAlphaR+alphaR*expAlphaRSqr*1.12837917e+00f);
    tempEnergy += includeInteraction ? prefactor*erfcAlphaR : 0;
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#else
#ifdef USE_CUTOFF
    unsigned int includeInteraction = (!isExcluded && r2 < CUTOFF_0_SQUARED);
#else
    unsigned int includeInteraction = (!isExcluded);
#endif
    real tempForce = 0.0f;
#if 1
    real sig = nonbonded2_sigmaEpsilon1.x + nonbonded2_sigmaEpsilon2.x;
    real sig2 = invR*sig;
    sig2 *= sig2;
    real sig6 = sig2*sig2*sig2;
    real epssig6 = sig6*(nonbonded2_sigmaEpsilon1.y*nonbonded2_sigmaEpsilon2.y);
    tempForce = epssig6*(12.0f*sig6 - 6.0f);
    real ljEnergy = includeInteraction ? epssig6*(sig6 - 1) : 0;
    #if 0
    if (r > LJ_SWITCH_CUTOFF) {
        real x = r-LJ_SWITCH_CUTOFF;
        real switchValue = 1+x*x*x*(LJ_SWITCH_C3+x*(LJ_SWITCH_C4+x*LJ_SWITCH_C5));
        real switchDeriv = x*x*(3*LJ_SWITCH_C3+x*(4*LJ_SWITCH_C4+x*5*LJ_SWITCH_C5));
        tempForce = tempForce*switchValue - ljEnergy*switchDeriv*r;
        ljEnergy *= switchValue;
    }
    #endif
    tempEnergy += ljEnergy;
#endif
#if 1
  #ifdef USE_CUTOFF
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w;
    tempForce += prefactor*(invR - 2.0f*6.72815135e-01f*r2);
    tempEnergy += includeInteraction ? prefactor*(invR + 6.72815135e-01f*r2 - 1.65609137e+00f) : 0;
  #else
    const real prefactor = 1.38935458e+02f*posq1.w*posq2.w*invR;
    tempForce += prefactor;
    tempEnergy += includeInteraction ? prefactor : 0;
  #endif
#endif
    dEdR += includeInteraction ? tempForce*invR*invR : 0;
#endif
}


                        energy += tempEnergy;
#ifdef INCLUDE_FORCES
#ifdef USE_SYMMETRIC
                        delta.xyz *= dEdR;
                        force.xyz -= delta.xyz;
                        localData[tbx+tj].fx += delta.x;
                        localData[tbx+tj].fy += delta.y;
                        localData[tbx+tj].fz += delta.z;
#else
                        force.xyz -= dEdR1.xyz;
                        localData[tbx+tj].fx += dEdR2.x;
                        localData[tbx+tj].fy += dEdR2.y;
                        localData[tbx+tj].fz += dEdR2.z;
#endif
#endif
#ifdef PRUNE_BY_CUTOFF
                    }
#endif
                    tj = (tj + 1) & (TILE_SIZE - 1);
                    SYNC_WARPS;
                }
            }

            // Write results.

#ifdef INCLUDE_FORCES
#ifdef USE_NEIGHBOR_LIST
            unsigned int atom2 = atomIndices[get_local_id(0)];
#else
            unsigned int atom2 = y*TILE_SIZE + tgx;
#endif
            ATOMIC_ADD(&forceBuffers[atom1], (mm_ulong) realToFixedPoint(force.x));
            ATOMIC_ADD(&forceBuffers[atom1+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force.y));
            ATOMIC_ADD(&forceBuffers[atom1+2*PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(force.z));
            if (atom2 < PADDED_NUM_ATOMS) {
                ATOMIC_ADD(&forceBuffers[atom2], (mm_ulong) realToFixedPoint(localData[get_local_id(0)].fx));
                ATOMIC_ADD(&forceBuffers[atom2+PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(localData[get_local_id(0)].fy));
                ATOMIC_ADD(&forceBuffers[atom2+2*PADDED_NUM_ATOMS], (mm_ulong) realToFixedPoint(localData[get_local_id(0)].fz));
            }
#endif
        }
        pos++;
    }
#ifdef INCLUDE_ENERGY
    energyBuffer[get_global_id(0)] += energy;
#endif
    
}

