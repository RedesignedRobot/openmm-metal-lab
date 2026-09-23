<!-- Posted 2026-09-23: CauldronDevelopmentLLC/cbang#213, FoldingAtHome/fah-client-bastet#455, #303 issuecomment-5802602087. Patches: experiments/023-fah-client-apple-gpu (cbang 984c0f31, client bbfe025, both on master as of 12fa35b8 and d85c21a8). -->

# cbang PR: Identify Apple silicon GPUs

Apple silicon GPUs aren't PCI devices, so the client can't identify them yet (FoldingAtHome/fah-client-bastet#303). This adds `VENDOR_APPLE` (0x106b) and maps Apple's OpenCL vendor ID 0x1027f00 to it, next to the existing AMD-on-Apple fixup.

The client side is FoldingAtHome/fah-client-bastet#455. Tested on an M2 Mac mini, macOS 27.

Using Claude Fable 5.1, I wrote and tested this.
# fah-client-bastet PR: Detect Apple silicon GPUs

Part of #303. Needs CauldronDevelopmentLLC/cbang#213.

An Apple silicon GPU's OpenCL device has no PCI info, so `detect()` drops it. On macOS it now becomes `gpu:soc:<n>`, with vendor 0x106b and the SoC ID from IOKit as its device ID (`IONameMatched = "gpu,t8112"` gives 0x8112). It's supported when gpus.json has a species for that pair, so Apple GPUs can be whitelisted without a format change.

Tested on an M2 Mac mini, with the assignment server pointed at localhost:

- Unpatched, the client logs the Apple M2 OpenCL device and lists no GPUs.
- Patched, it lists `gpu:soc:0` (vendor 0x106b, device 0x8112), unsupported with the live gpus.json.
- With a local gpus.json row for (0x106b, 0x8112), the GPU is supported, joins a resource group and gets a well-formed assignment request. The core arguments it builds are `-gpu-platform opencl -gpu-vendor apple -opencl-platform 0 -opencl-device 0 -gpu 0`.

This is step 3 of the plan in #303, using today's 16-bit IDs. Happy to move it to the `<bus>:<vendor>:<device>` string IDs once those land.

Using Claude Fable 5.1, I wrote and tested this.
# Comment on #303

@jcoffland Here's step 3 for Apple silicon: #455 and CauldronDevelopmentLLC/cbang#213. It works with today's gpus.json, so one Apple row is enough to try it. Let me know what you think!
