"""Write a copy of Xcode's Metal System Trace template with a GPU counter profile and the shader timeline on.

usage: python countertemplate.py <out.tracetemplate> <counter profile> [<source .tracetemplate>]
The template's options dict holds counterprofile 0 and shaderprofiler False, and no shipped template sets another
profile. GPUPlugin names its profiles Limiters, Occupancy, Utilizations, OMU Influences (External), Memory Bandwidth,
One Pass and Raytracing, but not their numbers, so limiter.sh finds the number by what gpu-counter-info records. The
integer 0 object is shared by other options, so the copy appends a new integer object and points counterprofile at it.
"""
import plistlib
import sys

SOURCE = ("/Applications/Xcode-beta.app/Contents/Applications/Instruments.app/Contents/Packages/GPU.instrdst/"
          "Contents/Templates/Metal System Trace.tracetemplate")

source = sys.argv[3] if len(sys.argv) > 3 else SOURCE
with open(source, "rb") as f:
    archive = plistlib.load(f)
objects = archive["$objects"]
true = plistlib.UID(next(i for i, o in enumerate(objects) if o is True))
objects.append(int(sys.argv[2]))
profile = plistlib.UID(len(objects) - 1)
changed = {"shaderprofiler": 0, "counterprofile": 0}
for o in objects:
    if not (isinstance(o, dict) and "NS.keys" in o):
        continue
    for i, key in enumerate(o["NS.keys"]):
        name, value = objects[key.data], objects[o["NS.objects"][i].data]
        if name == "shaderprofiler" and value is False:
            o["NS.objects"][i] = true
            changed[name] += 1
        if name == "counterprofile" and value == 0 and value is not False:
            o["NS.objects"][i] = profile
            changed[name] += 1
if changed != {"shaderprofiler": 1, "counterprofile": 1}:
    sys.exit(f"expected one shaderprofiler False and one counterprofile 0 in {source}, found {changed}")
with open(sys.argv[1], "wb") as f:
    plistlib.dump(archive, f, fmt=plistlib.FMT_BINARY)
print(f"wrote {sys.argv[1]}")
