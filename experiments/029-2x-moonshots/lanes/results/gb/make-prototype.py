from pathlib import Path
import re
p=Path('~/code/wt/m29-gb/platforms/common/src/kernels/gbsaObc.cc')
s=p.read_text()
s=s.replace('SYNC_WARPS', 'GB_TILE_SYNC')
s=s.replace('localData[tbx+tj].bornSum', 'GB_BORN_Y')
for a,b in [('fx','x'),('fy','y'),('fz','z'),('fw','w')]:
 s=s.replace('localData[tbx+tj].'+a, 'GB_FORCE_Y_'+b.upper())
s=s.replace('localData[LOCAL_ID]', 'GB_OWN')
s=s.replace('localData[tbx+tj]', 'GB_OTHER(tbx+tj)')
s=s.replace('localData[tbx+j]', 'GB_OTHER(tbx+j)')
s=s.replace('atomIndices[LOCAL_ID]', 'GB_ATOM_OWN')
s=s.replace('atomIndices[tbx+tj]', 'GB_ATOM_OTHER(tbx+tj)')
s=s.replace('for (unsigned int j = 0; j < TILE_SIZE; j++) {', 'for (unsigned int j = 0; j < TILE_SIZE; j++) {\n                GB_LOAD(j)')
s=re.sub(r'(?m)^(\s*)for \(j = 0; j < TILE_SIZE; j\+\+\) \{', r'\1for (j = 0; j < TILE_SIZE; j++) {\n\1    GB_LOAD(tj)', s)
s=re.sub(r'(?m)^(\s*)tj = \(tj \+ 1\)', r'\1GB_FINISH(tj)\n\1tj = (tj + 1)', s)
for typename in ('AtomData1','AtomData2'):
 old=f'    LOCAL {typename} localData[FORCE_WORK_GROUP_SIZE];'
 new=f'''#ifdef GB_REGISTER_TILES
    {typename} localData = {{}};
    int localAtomIndex = 0;
#else
{old}
#endif'''
 assert old in s
 s=s.replace(old,new)
start='    int skipBase = 0;'
end='    skipTiles[LOCAL_ID] = -1;'
s=s.replace(start,'#ifndef GB_REGISTER_TILES\n'+start).replace(end,end+'\n#endif')
helpers1='''
#ifdef GB_REGISTER_TILES
inline AtomData1 shuffleGBData(AtomData1 data, uint lane) {
    AtomData1 other = {};
    other.x = simd_shuffle(data.x, lane);
    other.y = simd_shuffle(data.y, lane);
    other.z = simd_shuffle(data.z, lane);
    other.radius = simd_shuffle(data.radius, lane);
    other.scaledRadius = simd_shuffle(data.scaledRadius, lane);
    return other;
}
inline real zeroGBPair(AtomData1 data) {
    return 0;
}
inline void finishGBPair(PRIVATE AtomData1& data, real value, uint lane) {
    data.bornSum += simd_shuffle(value, lane);
}
#endif
'''
helpers2='''
#ifdef GB_REGISTER_TILES
inline AtomData2 shuffleGBData(AtomData2 data, uint lane) {
    AtomData2 other = {};
    other.x = simd_shuffle(data.x, lane);
    other.y = simd_shuffle(data.y, lane);
    other.z = simd_shuffle(data.z, lane);
    other.q = simd_shuffle(data.q, lane);
    other.bornRadius = simd_shuffle(data.bornRadius, lane);
    return other;
}
inline real4 zeroGBPair(AtomData2 data) {
    return make_real4(0);
}
inline void finishGBPair(PRIVATE AtomData2& data, real4 value, uint lane) {
    real4 force = simd_shuffle(value, lane);
    data.fx += force.x;
    data.fy += force.y;
    data.fz += force.z;
    data.fw += force.w;
}
#endif
'''
s=s.replace('} AtomData1;', '} AtomData1;\n'+helpers1)
s=s.replace('} AtomData2;', '} AtomData2;\n'+helpers2)
header='''// Cutoff Metal tiles keep atom data and Y sums in SIMD registers.  All shuffles
// execute before the per-pair predicates, including on padded atom lanes.
#if defined(USE_METAL) && defined(USE_CUTOFF)
#define GB_REGISTER_TILES
#define GB_OWN localData
#define GB_OTHER(index) otherData
#define GB_ATOM_OWN localAtomIndex
#define GB_ATOM_OTHER(index) otherAtom
#define GB_BORN_Y gbPair
#define GB_FORCE_Y_X gbPair.x
#define GB_FORCE_Y_Y gbPair.y
#define GB_FORCE_Y_Z gbPair.z
#define GB_FORCE_Y_W gbPair.w
#define GB_TILE_SYNC
#define GB_LOAD(index) \\
    auto otherData = shuffleGBData(localData, (index)); \\
    auto gbPair = zeroGBPair(localData); \\
    int otherAtom = simd_shuffle(localAtomIndex, (index));
// The lane owning Y gathers its contribution from X = Y - pair iteration.
// This preserves the original per-Y accumulation order and per-tile fixed point.
#define GB_FINISH(index) finishGBPair(localData, gbPair, (2*tgx-(index)) & (TILE_SIZE-1));
#else
#define GB_OWN localData[LOCAL_ID]
#define GB_OTHER(index) localData[index]
#define GB_ATOM_OWN atomIndices[LOCAL_ID]
#define GB_ATOM_OTHER(index) atomIndices[index]
#define GB_BORN_Y localData[tbx+tj].bornSum
#define GB_FORCE_Y_X localData[tbx+tj].fx
#define GB_FORCE_Y_Y localData[tbx+tj].fy
#define GB_FORCE_Y_Z localData[tbx+tj].fz
#define GB_FORCE_Y_W localData[tbx+tj].fw
#define GB_TILE_SYNC SYNC_WARPS
#define GB_LOAD(index)
#define GB_FINISH(index)
#endif

'''
assert s.count('GB_LOAD(')==8
assert s.count('GB_FINISH(')==6
p.write_text(header+s)
