import plistlib, sys
a = plistlib.load(open(sys.argv[1], "rb")); o = a["$objects"]
for x in o:
    if isinstance(x, dict) and "NS.keys" in x:
        for k, v in zip(x["NS.keys"], x["NS.objects"]):
            name = o[k.data]
            if name in ("counterprofile", "counterscounterprofile", "counterprofileinternal", "counterdevice", "countersshaderprofiler"):
                val = o[v.data]
                cls = o[val["$class"].data]["$classname"] if isinstance(val, dict) and "$class" in val else ""
                print(name, repr(val)[:150], cls)
