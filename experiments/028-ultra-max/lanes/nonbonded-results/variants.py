import re, sys
p=sys.argv[1]
s=open(p).read()
def rep(a,b,n):
    global s
    assert s.count(a)==n, (a, s.count(a))
    s=s.replace(a,b)
hdr='''#if defined(USE_CUTOFF) && !defined(NB_NOBRANCH)
#define NB_BRANCH 1
#endif
#ifdef NB_TGP
#define NB_TGP_STORE localPosq[threadIdx.x] = shflPosq; localIndex[threadIdx.x] = atomIndex;
#define NB_POSQ2 localPosq[tbx+((tgx+j)&(TILE_SIZE-1))]
#define NB_ATOM2 localIndex[tbx+((tgx+j)&(TILE_SIZE-1))]
#define NB_ROTATE_INDEX
#else
#define NB_TGP_STORE
#define NB_POSQ2 shflPosq
#define NB_ATOM2 atomIndex
#define NB_ROTATE_INDEX atomIndex = warpRotateLeft(atomIndex);
#endif
#ifdef NB_TGF
#define NB_TGF_STORE localForce[threadIdx.x] = make_real4(0);
#define NB_ADD_FORCE2(f) localForce[tbx+((tgx+j)&(TILE_SIZE-1))] += make_real4((f).x, (f).y, (f).z, 0);
#define NB_ITER_SYNC SYNC_WARPS
#define NB_TGF_LOAD SYNC_WARPS shflForce = localForce[threadIdx.x].xyz;
#else
#define NB_TGF_STORE
#define NB_ADD_FORCE2(f) shflForce.x += (f).x; shflForce.y += (f).y; shflForce.z += (f).z;
#define NB_ITER_SYNC
#define NB_TGF_LOAD
#endif
#if defined(NB_TGP) || defined(NB_TGF)
#define NB_TG_STORE SYNC_WARPS NB_TGP_STORE NB_TGF_STORE SYNC_WARPS
#else
#define NB_TG_STORE
#endif

'''
rep('''    const unsigned int tgx = threadIdx.x & (TILE_SIZE-1); // index within the warp
''','''    const unsigned int tgx = threadIdx.x & (TILE_SIZE-1); // index within the warp
    const unsigned int tbx = threadIdx.x - tgx;
#ifdef NB_TGP
    threadgroup real4 localPosq[THREAD_BLOCK_SIZE];
    threadgroup int localIndex[THREAD_BLOCK_SIZE];
#endif
#ifdef NB_TGF
    threadgroup real4 localForce[THREAD_BLOCK_SIZE];
#endif
''',1)
def sub(pat, r, n):
    global s
    s, k = re.subn(pat, r, s)
    assert k == n, (pat, k)
sub(r'#ifdef USE_CUTOFF\n(\s*)if \(r2 < MAX_CUTOFF_SQUARED\) \{\n#endif', r'#ifdef NB_BRANCH\n\1if (r2 < MAX_CUTOFF_SQUARED) {\n#endif', 4)
sub(r'#ifdef USE_CUTOFF\n(\s*)\}\n#endif', r'#ifdef NB_BRANCH\n\1}\n#endif', 4)
sub(r'real4 posq2 = shflPosq;', 'real4 posq2 = NB_POSQ2;', 3)
sub(r'(?<!unsigned )int atom2 = atomIndex;', 'int atom2 = NB_ATOM2;', 3)
sub(r'shflForce\.x \+= delta\.x;\n\s*shflForce\.y \+= delta\.y;\n\s*shflForce\.z \+= delta\.z;', 'NB_ADD_FORCE2(delta)', 3)
sub(r'shflForce\.x \+= dEdR2\.x;\n\s*shflForce\.y \+= dEdR2\.y;\n\s*shflForce\.z \+= dEdR2\.z;', 'NB_ADD_FORCE2(dEdR2)', 3)
sub(r'atomIndex = warpRotateLeft\(atomIndex\);', 'NB_ROTATE_INDEX\n                NB_ITER_SYNC', 3)
rep('''            LOAD_LOCAL_PARAMETERS_FROM_GLOBAL
#ifdef USE_EXCLUSIONS
            excl = (excl >> tgx)''','''            LOAD_LOCAL_PARAMETERS_FROM_GLOBAL
            NB_TG_STORE
#ifdef USE_EXCLUSIONS
            excl = (excl >> tgx)''',1)
rep('''                APPLY_PERIODIC_TO_POS_WITH_CENTER(shflPosq, blockCenterX)
''','''                APPLY_PERIODIC_TO_POS_WITH_CENTER(shflPosq, blockCenterX)
                NB_TG_STORE
''',1)
rep('''                // We need to apply periodic boundary conditions separately for each interaction.
''','''                // We need to apply periodic boundary conditions separately for each interaction.
                NB_TG_STORE
''',1)
rep('''            const unsigned int offset = atomIndex;''','''            NB_TGF_LOAD
            const unsigned int offset = atomIndex;''',1)
rep('''            unsigned int atom2 = atomIndex;
            if (atom2 < PADDED_NUM_ATOMS) {''','''            NB_TGF_LOAD
            unsigned int atom2 = atomIndex;
            if (atom2 < PADDED_NUM_ATOMS) {''',1)
s=hdr+s
open(p,'w').write(s)
