from pathlib import Path
src=Path('/tmp/openmm-metal-bench/ultra-m29-unified/src/platforms/metal/src/MetalCpuFFT.cpp').read_text()
line=src[src.index('struct LineFFT'):src.index('\n};\n}',src.index('struct LineFFT'))+3]
stage=src[src.index('    struct Stage {'):src.index('    struct Job {')]
out='''#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <cmath>
#include <vector>
#include <stdexcept>
#include <cstdio>
using namespace std;
using OpenMMException = runtime_error;
'''+line+'''
struct Impl {
int x,y,z,half,workers;
LineFFT tx,ty,tz;
vector<vector<float>> scratchR,scratchI;
Impl(int a,int b,int c):x(a),y(b),z(c),half(c/2+1),workers(20),tx(a),ty(b),tz(c) {
int n=max(tx.size,max(ty.size,tz.size));
scratchR.resize(workers, vector<float>(n)); scratchI=scratchR;
}
'''+stage+'''
void transform(float* real, float* grid, bool forward) {
Stage stage{this,real,grid,0,forward};
for(int a=0;a<3;a++) {
stage.axis=forward?2-a:a;
dispatch_apply_f(workers,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),&stage,lines);
}
}
};
int main() {
for(int n: {2,3,5,7,11,13,16,21,24,28,32,44,48,55,64,72,80,96,108,128}) {
LineFFT plan(n); vector<float> r(plan.size),i(plan.size),inr(n),ini(n);
for(int j=0;j<n;j++) {r[j]=inr[j]=sin(j*.731);i[j]=ini[j]=cos(j*.413);}
plan.transform(r.data(),i.data(),true);
double error=0;
for(int k=0;k<n;k++) {
double re=0,im=0;
for(int j=0;j<n;j++) {double a=-2*M_PI*j*k/n; re+=inr[j]*cos(a)-ini[j]*sin(a);im+=inr[j]*sin(a)+ini[j]*cos(a);}
error=max(error,hypot(r[k]-re,i[k]-im)/n);
}
plan.transform(r.data(),i.data(),false);
for(int j=0;j<n;j++) error=max(error,double(hypot(r[j]/n-inr[j],i[j]/n-ini[j])));
if(error>1e-5) {printf("FAIL line %d error %.9g\\n",n,error);return 1;}
}
for(auto dims: {vector<int>{7,11,13},vector<int>{21,24,28},vector<int>{32,48,64}}) {
int x=dims[0],y=dims[1],z=dims[2],n=x*y*z; Impl p(x,y,z);
vector<float> real(n),original(n),grid(2*x*y*(z/2+1));
for(int a=0;a<x;a++) for(int b=0;b<y;b++) for(int c=0;c<z;c++) real[(a*y+b)*z+c]=original[(a*y+b)*z+c]=cos(2*M_PI*(double(a)/x+2.*b/y+3.*c/z));
p.transform(real.data(),grid.data(),true);
double error=0;
for(int a=0;a<x;a++) for(int b=0;b<y;b++) for(int c=0;c<=z/2;c++) {int k=2*((a*y+b)*(z/2+1)+c);double expected=(a==1&&b==2&&c==3)?n*.5:0;error=max(error,hypot(grid[k]-expected,grid[k+1])/n);}
p.transform(real.data(),grid.data(),false);
for(int j=0;j<n;j++) error=max(error,double(abs(real[j]/n-original[j])));
if(error>1e-5) {printf("FAIL grid %dx%dx%d error %.9g\\n",x,y,z,error);return 1;}
printf("PASS grid %dx%dx%d max error %.9g\\n",x,y,z,error);
}
printf("PASS CPU FFT direct-DFT and 3D spectral/roundtrip oracle\\n");
}
'''
Path('/tmp/openmm-metal-bench/ultra-m29-unified/tools/cpu-oracle.cpp').write_text(out)
