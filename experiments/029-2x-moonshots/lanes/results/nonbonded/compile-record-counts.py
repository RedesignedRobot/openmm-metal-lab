import os, shlex, subprocess
from pathlib import Path
root=Path('/tmp/openmm-metal-bench')
lane=root/'ultra-m29-nonbonded'
candidate=root/'ultra-m29-nonbonded-records'
text=(candidate/'build/build.ninja').read_text()
start=text.index('build platforms/metal/CMakeFiles/OpenMMMetal.dir/src/MetalNonbondedUtilities.cpp.o:')
block=text[start:text.index('\n\n',start)]
includes=next(line.strip().split(' = ',1)[1] for line in block.splitlines() if line.strip().startswith('INCLUDES = '))
command=['/usr/bin/xcrun','clang++','-std=c++17','-O1','-dynamiclib','-DMETALCPP_SYMBOL_VISIBILITY_HIDDEN',*shlex.split(includes),str(lane/'record-counts.cpp'),
         '-L'+str(candidate/'prefix/lib'),'-lOpenMM','-L'+str(candidate/'prefix/lib/plugins'),'-lOpenMMMetal',
         '-Wl,-rpath,'+str(candidate/'prefix/lib'),'-Wl,-rpath,'+str(candidate/'prefix/lib/plugins'),
         '-framework','Foundation','-framework','Metal','-o',str(lane/'record-counts.dylib')]
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode-beta.app/Contents/Developer')
subprocess.run(command,env=env,check=True)
