from pathlib import Path
p=Path('platforms/metal/src/kernels/cooperativeShake.metal')
s=p.read_text(); s=s[:s.index('// Four adjacent lanes')]+r'''// A half SIMD group owns one cluster: four atoms, with xyz and a padding
// component per atom. The kick and state updates run across atoms as well as
// coordinates. Constraint corrections retain their Gauss-Seidel bond order.
DEVICE mixed shakeShuffle(mixed value, ushort source) {
    return mixed(simd_shuffle(value.hi, source), simd_shuffle(value.lo, source));
}

template <bool velocities>
DEVICE void cooperativeShake(int4 atoms, float4 params, mixed tol, int atomIndex,
        int component, mixed pos, PRIVATE mixed& value) {
    ushort base = (LOCAL_ID & 31) & ~15u;
    mixed direction = shakeShuffle(pos, base+component)-pos;
    float2 norm;
    float velocityNorm;
    if (velocities) {
        float d = (float) direction;
        float sq = d*d;
        ushort quartet = base+4*atomIndex;
        velocityNorm = (simd_shuffle(sq, quartet)+simd_shuffle(sq, quartet+1))+
                simd_shuffle(sq, quartet+2);
    }
    else
        norm = shakeCompensatedDot(direction, direction);
    float maxResidual = params.z*(float) tol;
    for (int iteration = 0; iteration < 15; iteration++) {
        bool converged = true;
        for (int j = 1; j < 4; j++) {
            if (atoms[j] == -1)
                continue;
            mixed bondDirection = shakeShuffle(direction, base+4*j+component);
            mixed difference = shakeShuffle(value, base+component)-
                    shakeShuffle(value, base+4*j+component);
            float correction;
            if (velocities) {
                float2 product = shakeCompensatedDot(difference, bondDirection);
                float bondNorm = simd_shuffle(velocityNorm, base+4*j);
                correction = -2.0f*params.y*(product.x+product.y)/bondNorm;
                if (fabs(correction) > tol)
                    converged = false;
            }
            else {
                float2 product = shakeCompensatedDot(bondDirection, difference);
                float2 square = shakeCompensatedDot(difference, difference);
                float2 bondNorm = simd_shuffle(norm, base+4*j);
                float2 term = component == 0 ? float2(params.z, 0) :
                              component == 1 ? -bondNorm :
                              component == 2 ? -2.0f*product : -square;
                float2 residualParts = shakeCompensatedSum(term);
                float residual = residualParts.x+residualParts.y;
                if (fabs(residual) < maxResidual)
                    continue;
                correction = residual*params.y/((product.x+product.y)+(bondNorm.x+bondNorm.y));
                converged = false;
            }
            float shift = (float) bondDirection*correction;
            if (atomIndex == 0)
                value += shift*params.x;
            else if (atomIndex == j)
                value -= shift*params.w;
        }
        if (converged)
            break;
    }
}

template <bool constrained>
DEVICE void cooperativeIntegrationStep(int4 atoms, float4 params, mixed tol,
        int paddedNumAtoms, GLOBAL real4* posq, GLOBAL real4* posqCorrection,
        GLOBAL mixed4* velm, GLOBAL const mm_long* force, GLOBAL const mixed* paramBuffer,
        GLOBAL const mixed2* dt, GLOBAL const float4* random, unsigned int randomIndex) {
    int component = LOCAL_ID & 3;
    int atomIndex = constrained ? ((LOCAL_ID >> 2) & 3) : 0;
    int atom = atoms[atomIndex];
    mixed pos = 0, vel = 0, delta = 0, oldDelta = 0;
    mixed invMass = atom == -1 ? (mixed) 0 : velm[atom].w;
    mixed fscale = dt[0].y/(mixed) 0x100000000;
    mixed halfdt = 0.5f*dt[0].y;
    mixed invDt = 1/dt[0].y;
    if (atom != -1 && component < 3) {
        pos = (mixed) ((GLOBAL real*) posq)[4*atom+component] +
                ((GLOBAL real*) posqCorrection)[4*atom+component];
        vel = ((GLOBAL mixed*) velm)[4*atom+component];
        if (invMass != 0)
            vel += fscale*invMass*force[atom+component*paddedNumAtoms];
    }
    if (constrained)
        cooperativeShake<true>(atoms, params, tol, atomIndex, component, pos, vel);
    if (invMass != 0) {
        delta = halfdt*vel;
        float noise = component < 3 ? random[randomIndex+atom][component] : 0;
        vel = paramBuffer[0]*vel + paramBuffer[1]*SQRT(invMass)*noise;
        delta += halfdt*vel;
        oldDelta = delta;
    }
    if (constrained)
        cooperativeShake<false>(atoms, params, tol, atomIndex, component, pos, delta);
    if (invMass != 0 && component < 3) {
        vel += (delta-oldDelta)*invDt;
        ((GLOBAL mixed*) velm)[4*atom+component] = vel;
        mixed newPos = pos+delta;
        real hi = (real) newPos;
        ((GLOBAL real*) posq)[4*atom+component] = hi;
        ((GLOBAL real*) posqCorrection)[4*atom+component] = (real) (newPos-hi);
    }
}

KERNEL void applyCooperativeShake(int numClusters, mixed tol, GLOBAL const real4* oldPos,
        GLOBAL mixed4* values, GLOBAL const int4* clusterAtoms, GLOBAL const float4* clusterParams,
        GLOBAL const real4* posqCorrection, int velocities) {
    int component = LOCAL_ID & 3;
    int atomIndex = (LOCAL_ID >> 2) & 3;
    for (int index = GLOBAL_ID/16; index < numClusters; index += GLOBAL_SIZE/16) {
        int4 atoms = clusterAtoms[index];
        int atom = atoms[atomIndex];
        mixed pos = 0, value = 0;
        if (atom != -1 && component < 3) {
            pos = (mixed) ((GLOBAL const real*) oldPos)[4*atom+component] +
                    ((GLOBAL const real*) posqCorrection)[4*atom+component];
            value = ((GLOBAL mixed*) values)[4*atom+component];
        }
        if (velocities)
            cooperativeShake<true>(atoms, clusterParams[index], tol, atomIndex, component, pos, value);
        else
            cooperativeShake<false>(atoms, clusterParams[index], tol, atomIndex, component, pos, value);
        if (atom != -1 && component < 3)
            ((GLOBAL mixed*) values)[4*atom+component] = value;
    }
}
#endif
'''
p.write_text(s)
p=Path('platforms/metal/src/kernels/fusedLangevinMiddle.metal');s=p.read_text().replace('four lanes per SHAKE cluster or free atom','16 lanes per SHAKE cluster and four per free atom').replace('((4*numShake+31)/32)*32','((16*numShake+31)/32)*32').replace('int cluster = work/4;','int cluster = work/16;').replace('cooperativeShakeStep(shakeAtoms[cluster], shakeParams[cluster], tol, LOCAL_ID & 3,','cooperativeIntegrationStep<true>(shakeAtoms[cluster], shakeParams[cluster], tol,').replace('cooperativeShakeStep(make_int4(freeAtoms[index], -1, -1, -1), make_float4(0), tol, LOCAL_ID & 3,','cooperativeIntegrationStep<false>(make_int4(freeAtoms[index], -1, -1, -1), make_float4(0), tol,');p.write_text(s)
p=Path('platforms/metal/src/MetalIntegrationUtilities.cpp');s=p.read_text().replace('shakeAtoms.getSize()*(cooperative ? 4 : 1)','shakeAtoms.getSize()*(cooperative ? 16 : 1)').replace('((4*numShake+31)/32)*32','((16*numShake+31)/32)*32');p.write_text(s)
