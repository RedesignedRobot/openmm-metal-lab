"""Summarize the last 200 complete force intervals from existing shader traces."""
from pathlib import Path
import collections
import xml.etree.ElementTree as ET
p=Path('/tmp/openmm-metal-bench/ultra-m29-nonbonded/records-profile-cellulose')
def load(tag):
 pid=(p/(tag+'.pypid')).read_text().strip();texts={};rows=[]
 for _,e in ET.iterparse(p/(tag+'-intervals.xml'),events=('end',)):
  if e.get('id') is not None:
   texts[e.get('id')]=e.text if e.tag in ('start-time','duration') else (e.get('fmt') or e.text or '')
  if e.tag=='row':
   c=list(e)
   def val(x):return texts.get(x.get('ref')) if x.get('ref') else (x.text if x.tag in ('start-time','duration') else x.get('fmt') or x.text or '')
   if f'({pid})' in val(c[11]):rows.append((int(val(c[0])),int(val(c[1])),val(c[2]).rsplit(' (',1)[0]))
   e.clear()
 starts=sorted(t for t,d,n in rows if n=='computeNonbonded')
 lo,hi=starts[-201],starts[-1]
 total=collections.Counter();count=collections.Counter()
 for t,d,n in rows:
  if lo<=t<hi:total[n]+=d/1000;count[n]+=1
 assert count['computeNonbonded']==200
 print(tag,'window seconds',lo/1e9,hi/1e9,'integration launches',count['integrateLangevinMiddleFused'])
 assert not any(count[n] for n in ['lineSearchStep','gradNorm','updateDirBeta'])
 return total,count
(a,ac),(b,bc)=load('maxbits'),load('records')
print('Kernel, MAX_BITS sampled us/force interval, records sampled us/force interval, launches A/B')
for n in sorted(set(a)|set(b),key=lambda n:-abs(a[n]-b[n])):
 print(f'{n:42s} {a[n]/200:9.2f} {b[n]/200:9.2f} {ac[n]:4d} {bc[n]:4d}')
print('Sampled spans overlap and are not exact hardware timings. Both windows exclude minimization.')
