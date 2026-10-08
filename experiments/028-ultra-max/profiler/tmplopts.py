import plistlib, sys
a = plistlib.load(open(sys.argv[1], "rb")); o = a["$objects"]
def val(u):
    v = o[u.data] if isinstance(u, plistlib.UID) else u
    if isinstance(v, dict) and "NS.string" in v: return v["NS.string"]
    if isinstance(v, dict) and "NS.keys" in v: return {val(k): val(x) for k, x in zip(v["NS.keys"], v["NS.objects"])}
    if isinstance(v, dict) and "NS.objects" in v: return [val(x) for x in v["NS.objects"]]
    return v
for x in o:
    if isinstance(x, dict) and "NS.keys" in x:
        d = val(plistlib.UID(o.index(x)))
        if any(isinstance(k, str) and ("counter" in k.lower() or "shaderprofiler" in k.lower() or "profile" in k.lower()) for k in d):
            print({k: (v if len(repr(v)) < 200 else repr(v)[:200]) for k, v in d.items()})
