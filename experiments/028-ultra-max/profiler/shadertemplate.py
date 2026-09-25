"""Write a copy of Xcode's Metal System Trace template with the shader timeline on.

usage: python shadertemplate.py <out.tracetemplate> [<source .tracetemplate>]
No xctrace flag or --recording-options key turns the shader timeline on. The template is a keyed archive whose one
options dict holds shaderprofiler False; the copy points that value at the archive's True object and changes nothing
else. Record with `xcrun xctrace record --template <out.tracetemplate> ...`.
"""
import plistlib
import sys

SOURCE = ("/Applications/Xcode-beta.app/Contents/Applications/Instruments.app/Contents/Packages/GPU.instrdst/"
          "Contents/Templates/Metal System Trace.tracetemplate")

source = sys.argv[2] if len(sys.argv) > 2 else SOURCE
with open(source, "rb") as f:
    archive = plistlib.load(f)
objects = archive["$objects"]
true = plistlib.UID(next(i for i, o in enumerate(objects) if o is True))
changed = 0
for o in objects:
    if not (isinstance(o, dict) and "NS.keys" in o):
        continue
    for i, key in enumerate(o["NS.keys"]):
        if objects[key.data] == "shaderprofiler" and objects[o["NS.objects"][i].data] is False:
            o["NS.objects"][i] = true
            changed += 1
if changed != 1:
    sys.exit(f"expected one shaderprofiler option set False in {source}, found {changed}")
with open(sys.argv[1], "wb") as f:
    plistlib.dump(archive, f, fmt=plistlib.FMT_BINARY)
print(f"wrote {sys.argv[1]}")
