"""Classify a serialized System's constraints the way OpenMM's IntegrationUtilities.cpp does:
SETTLE triangles, then SHAKE clusters, and whatever is left goes to CCMA.

usage: python3 constraints.py <dir> [<dir> ...]   (each dir holds a system.xml)
FAHBench dhfr: 21,069 SETTLE atoms (7,023 waters), 0 SHAKE clusters, 3,072 CCMA constraints. benchmark.py's systems (HBonds): 0 CCMA.
"""
import re, sys
for w in sys.argv[1:]:
    s=open(f"{w}/system.xml").read()
    ps=s[s.index("<Particles>"):s.index("</Particles>")]
    masses=[float(m) for m in re.findall(r'mass="([^"]*)"',ps)]
    n=len(masses)
    a1=[];a2=[];dist=[]
    for tag in re.findall(r'<Constraint [^>]*>',s):
        a=dict(re.findall(r'(\w+)="([^"]*)"',tag)); p1,p2,d=int(a['p1']),int(a['p2']),float(a['d'])
        if masses[p1]!=0 or masses[p2]!=0: a1.append(p1);a2.append(p2);dist.append(d)
    cc=[0]*n
    for p,q in zip(a1,a2): cc[p]+=1; cc[q]+=1
    import struct
    f32=lambda x: struct.unpack("f",struct.pack("f",x))[0]
    sc=[dict() for _ in range(n)]
    for p,q,d in zip(a1,a2,dist):
        if cc[p]==2 and cc[q]==2: sc[p][q]=f32(d); sc[q][p]=f32(d)
    settle=[]
    for i in range(n):
        if len(sc[i])==2:
            k=sorted(sc[i]); p1,p2=k
            if len(sc[p1])!=2 or len(sc[p2])!=2 or p2 not in sc[p1]: sc[i].clear()
            else: settle.append(i)
        else: sc[i].clear()
    shake=[False]*n; nsettle=0
    for x in settle:
        k=sorted(sc[x]); y,z=k
        d12,d13,d23=sc[x][y],sc[x][z],sc[y][z]
        if d12==d13 or d12==d23 or d13==d23:
            shake[x]=shake[y]=shake[z]=True; nsettle+=1
    clusters={}; inval=[False]*n
    class C:
        def __init__(s,c): s.c=c;s.p=[];s.d=None;s.pim=None;s.valid=True
        def add(s,pid,d,im):
            if len(s.p)==3 or (s.p and abs(d-s.d)/s.d>1e-8) or (s.p and abs(im-s.pim)/s.pim>1e-8): s.valid=False
            else: s.p.append(pid); s.d=d; s.pim=im
        def mark(s):
            s.valid=False; inval[s.c]=True
            for p in s.p:
                inval[p]=True; o=clusters.get(p)
                if o and o.valid: o.mark()
    for p,q,d in zip(a1,a2,dist):
        if shake[p]: continue
        first = True if cc[p]>1 else False if cc[q]>1 else p<q
        c,per=(p,q) if first else (q,p)
        if c not in clusters: clusters[c]=C(c)
        cl=clusters[c]; cl.add(per,d,1/masses[per])
        if cc[per]!=1 or inval[p] or inval[q]:
            cl.mark(); o=clusters.get(per)
            if o and o.valid: o.mark()
    ns=0
    for c in sorted(clusters):
        cl=clusters[c]
        if cl.valid:
            cl.valid = (not inval[cl.c]) and len(cl.p)==cc[cl.c] and not any(inval[x] for x in cl.p)
            if cl.valid: ns+=1
    for c in sorted(clusters):
        cl=clusters[c]
        if cl.valid:
            for x in [cl.c]+cl.p: shake[x]=True
    nccma=sum(1 for p in a1 if not shake[p])
    hh=sum(1 for p,q in zip(a1,a2) if masses[p]<4.5 and masses[q]<4.5)
    print(w,"atoms",n,"constraints",len(a1),"settle atoms",nsettle,"shake",ns,"CCMA",nccma,"H-H constraints",hh)
