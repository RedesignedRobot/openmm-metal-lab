from pathlib import Path
root=Path('/tmp/openmm-metal-bench/ultra-m29-mixed-census/src')
p=root/'platforms/metal/src/MetalContext.cpp';s=p.read_text()
s=s.replace('#include "MetalContext.h"','#include "MetalContext.h"\n#include <mutex>\n#include <cstdio>')
s=s.replace('using namespace std;', '''using namespace std;
static map<void*, string> censusNames;
static map<string, pair<double, long>> censusData;
static mutex censusLock;
static bool censusEnabled = getenv("OPENMM_METAL_CENSUS") != NULL;''')
s=s.replace('''MetalContext::~MetalContext() {
    pushAsCurrent();''','''MetalContext::~MetalContext() {
    pushAsCurrent();
    if (censusEnabled) {
        getCurrentStream().finish();
        getCurrentStream().finish();
        lock_guard<mutex> g(censusLock);
        for (auto& e : censusData)
            fprintf(stderr, "CENSUS %s %ld %.3f\\n", e.first.c_str(), e.second.second, e.second.first*1e6);
        censusData.clear();
    }''')
s=s.replace('kernelArguments[kernel] = args;', 'kernelArguments[kernel] = args;\n    censusNames[kernel] = name;')
a='    encoder->dispatchThreadgroups(MTL::Size(gridSize, 1, 1), MTL::Size(blockSize, 1, 1));'
s=s.replace(a,a+'''
    if (censusEnabled) {
        string name = censusNames[kernel];
        queue.getCommandBuffer()->addCompletedHandler([name](MTL::CommandBuffer* b) {
            lock_guard<mutex> g(censusLock);
            censusData[name].first += b->GPUEndTime()-b->GPUStartTime();
            censusData[name].second++;
        });
        queue.commit();
    }''');p.write_text(s)
p=root/'platforms/metal/include/MetalIntegrationUtilities.h';s=p.read_text().replace('ComputeKernel langevinMiddleKernel;', 'ComputeKernel langevinMiddleKernel;\n    std::vector<ComputeKernel> censusKernels;');p.write_text(s)
p=root/'platforms/metal/src/kernels/fusedLangevinMiddle.metal';original=p.read_text();s=original
for name,start,end in [('Settle','0','numSettle'),('Shake','numSettle','numSettle+numShake'),('Free','numSettle+numShake','numUnits')]:
    s+='\n'+original.replace('integrateLangevinMiddleFused(', 'integrateLangevinMiddleFused'+name+'(').replace('for (int unit = GLOBAL_ID; unit < numUnits; unit += GLOBAL_SIZE)',f'for (int unit = {start}+GLOBAL_ID; unit < {end}; unit += GLOBAL_SIZE)')
p.write_text(s)
p=root/'platforms/metal/src/MetalIntegrationUtilities.cpp';s=p.read_text();a=s.index('        langevinMiddleKernel = program->createKernel(');b=s.index('\n    }\n    if (context.getUseMixedPrecision())',a)
body=s[a:b].replace('program->createKernel("integrateLangevinMiddleFused")','program->createKernel(kernelName)')
s=s[:a]+'''        vector<string> names = {"integrateLangevinMiddleFused"};
        if (getenv("OPENMM_METAL_CENSUS_SPLIT"))
            names = {"integrateLangevinMiddleFusedSettle", "integrateLangevinMiddleFusedShake", "integrateLangevinMiddleFusedFree"};
        for (string kernelName : names) {
'''+body+'''
            censusKernels.push_back(langevinMiddleKernel);
        }'''+s[b:]
a=s.index('    if (context.getUseMixedPrecision())\n        langevinMiddleKernel->setArg(4, tol);');b=s.index('    return true;',a)
body=s[a:b].replace('prepareRandomNumbers(context.getPaddedNumAtoms())','randomIndex')
s=s[:a]+'''    unsigned int randomIndex = prepareRandomNumbers(context.getPaddedNumAtoms());
    for (ComputeKernel kernel : censusKernels) {
        langevinMiddleKernel = kernel;
'''+body+'    }\n'+s[b:];p.write_text(s)
(root/'.commit').write_text('7484d7bef401f813dc871c1e156578954606d4ea-census-only\n')
