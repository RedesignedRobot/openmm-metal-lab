"""Write Metal System Trace templates that record a GPU counter profile on this Mac's GPU, shader timeline on or off.

usage: python countertmpl.py <out dir> <profiles, e.g. 0,1,2> [shader=1|0]
Writes <out dir>/cp<N>[-noshader].tracetemplate for each profile N.
The 028 limiter probe set counterprofile 1-7 and every trace still recorded only "RT Unit Active": the shipped
template leaves counterdevice 0, and its trace's recording options read "Counter Set: (null)". counterdevice and
counterdeviceinternal hold a GPU's IORegistry entry id (Apple's templates carry ids such as 0x10000094f from the
machine they were saved on), so this copy sets both to this machine's AGXAccelerator id, sets counterprofile and
counterprofileinternal to N, and sets shaderprofiler as asked. Everything else stays as shipped.
"""
import os
import plistlib
import re
import subprocess
import sys

SOURCE = ("/Applications/Xcode-beta.app/Contents/Applications/Instruments.app/Contents/Packages/GPU.instrdst/"
          "Contents/Templates/Metal System Trace.tracetemplate")


def gpu_registry_id():
    out = subprocess.run(["ioreg", "-r", "-c", "IOAccelerator", "-d", "1"], capture_output=True, text=True).stdout
    ids = re.findall(r"<class AGXAccelerator\w*, id (0x[0-9a-f]+)", out)
    if len(ids) != 1:
        sys.exit(f"expected one AGXAccelerator, found {ids}")
    return int(ids[0], 16)


def write(out, profile, shader, device):
    with open(SOURCE, "rb") as f:
        archive = plistlib.load(f)
    objects = archive["$objects"]

    def ref(value):
        for i, o in enumerate(objects):
            if type(o) is type(value) and o == value:
                return plistlib.UID(i)
        objects.append(value)
        return plistlib.UID(len(objects) - 1)

    wanted = {"counterdevice": device, "counterdeviceinternal": device, "counterprofile": profile,
              "counterprofileinternal": profile, "shaderprofiler": bool(shader)}
    options = [o for o in objects if isinstance(o, dict) and "NS.keys" in o
               and "counterdeviceinternal" in [objects[k.data] for k in o["NS.keys"]]]
    if len(options) != 1:
        sys.exit(f"expected one GPU options dict in {SOURCE}, found {len(options)}")
    o = options[0]
    keys = [objects[k.data] for k in o["NS.keys"]]
    for key, value in wanted.items():
        o["NS.objects"][keys.index(key)] = ref(value)
    with open(out, "wb") as f:
        plistlib.dump(archive, f, fmt=plistlib.FMT_BINARY)


out_dir, profiles = sys.argv[1], [int(p) for p in sys.argv[2].split(",")]
shader = len(sys.argv) < 4 or sys.argv[3] != "shader=0"
device = gpu_registry_id()
os.makedirs(out_dir, exist_ok=True)
for n in profiles:
    path = os.path.join(out_dir, f"cp{n}{'' if shader else '-noshader'}.tracetemplate")
    write(path, n, shader, device)
    print(f"wrote {path} (device {device:#x}, profile {n}, shader timeline {'on' if shader else 'off'})")
