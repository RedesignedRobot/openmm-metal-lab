# 023 fah-client: detect an Apple silicon GPU

## Question

Can the open-source FAH client (fah-client-bastet plus cbang) see an Apple silicon GPU, offer it to a resource group and build core arguments for it? Built and tested on the Mac mini M2, macOS 27.0 26A428. The plan came from `research/2026-09-23-fah-client-apple-gpu.md`.

## Answer

Yes. cbang gets one enum value, a 2-line vendor mapping and a new IOKit helper (`MacOSGPU.cpp`, 71 lines, 31 of them license header). The client gets 23 lines. The patched client lists the M2 GPU as `gpu:soc:0` with vendor 0x106b and device 0x8112. Once a local gpus.json row gives that pair a species, the default group offers the GPU and allocates a work unit to it. The unit's assignment request serializes the GPU without error. The core arguments come out as `-gpu-platform opencl -gpu-vendor apple -opencl-platform 0 -opencl-device 0 -gpu 0`. No request reached FAH. The assignment server was set to 127.0.0.1, where nothing listens on 443.

Upstream bases:

| Repo | Base SHA | Date | Patch |
| --- | --- | --- | --- |
| cbang | 12fa35b852f62a7fac035bad5c1750c9881fd3b8 | 2026-09-19 | `cbang.patch`, 4 files, +122 |
| fah-client-bastet | d85c21a88d0fcca138783cb16b9684e960e0fe04 | 2026-09-11 | `fah-client-bastet.patch`, 1 file, +23 |

Both are `git format-patch` output and apply with `git am` onto those SHAs. I checked that on fresh clones.

## What broke

Two things. The first shows in the unpatched run below. The second comes from reading the source, and the patched run shows it fixed.

1. `GPUResources::detect()` drops every OpenCL device without PCI info (`GPUResources.cpp:157`, `if (!cd.isPCIValid()) continue;`). Apple's OpenCL has no `cl_khr_pci_bus_info`, and the Apple GPU is not an `IOPCIDevice`, so the PCI loop never sees it either. OpenCL enumerates the M2, and then the client throws it away. `info.gpus` stays `{}`.
2. The device would still have failed at the assignment request. OpenCL reports vendor 0x1027f00, which does not fit in the u16 that `GPUResource::writeRequest` reads with `getU16("vendor")`, and `device` was never set, so `getU16("device")` would throw.

## What changed

cbang (`cbang.patch`):
- `src/cbang/hw/GPUVendor.h`: `VENDOR_APPLE = 0x106b`, Apple's PCI vendor ID, which is also the GPU's IOKit `vendor-id`. The client's `type` field becomes `apple`.
- `src/cbang/hw/OpenCLLibrary.cpp` `getVendorID`: map 0x1027f00 to 0x106b, next to the existing AMD-on-Apple fixup.
- `src/cbang/os/osx/MacOSGPU.{h,cpp}`: `getAppleGPUDeviceID()`. It walks `IOAccelerator` services and returns the SoC ID from the first `IONameMatched` of the form `gpu,t` plus four hex digits, for example `gpu,t8112` gives 0x8112. It returns 0 when nothing matches. It uses cbang's `MacOSRef`, `MacOSString::convert` and the non-throwing `String::parseU16`. `MacOSString::convert` throws only if `CFStringGetCString` fails, which the short ASCII names here don't trigger. It passes `MACH_PORT_NULL` (the default main port) rather than the deprecated `kIOMasterPortDefault`, so it adds no warnings. `os/osx` is only built on darwin (`cbang/SConstruct`), so there is no stub for other platforms.

fah-client-bastet (`fah-client-bastet.patch`):
- `src/fah/client/GPUResources.cpp` `detect()`: after the PCI loop, under `#ifdef __APPLE__`, each Apple OpenCL device without PCI info becomes `gpu:soc:<n>`. It gets the OpenCL entry (vendor 0x106b, type, description), `device` set to the SoC ID, and `supported` set when gpus.json has a species for (0x106b, SoC ID). The `MacOSGPU.h` include is under `#ifdef __APPLE__` too, because cbang's `scons install` ships `os/osx` headers only on darwin. Nothing else in the client changes. `isSupported`, `Config::getGPUs`, the group allocator, `writeRequest` and `Unit::run` work as they are.

No gpus.json schema change. The Apple row is `{vendor: 4203, device: <SoC ID>, type: <FAH's choice>, species: N}`. I used type 4 in the test row. The patch does not define a `GPU_APPLE` value, because the client only checks `type` for non-zero and the number is FAH's to pick.

## How it was tested

Everything ran on the mini under the lease. `run.sh` starts a client in an empty directory with `--verbosity 5`, no account, `--assignment-servers 127.0.0.1` and `--api-server https://127.0.0.1`. It copies in a gpus.json so the client never downloads one, and refuses to start if the copy fails. That guard came after the post-review rerun, when a bad `GPUS_JSON` path left the directory empty and the client fetched `https://api.foldingathome.org/gpus` once, the public GPU table every client downloads. No assignment request left the mini. `ws_probe.py` reads `info.gpus` from the client's loopback websocket, the same JSON the web UI gets, and can enable a GPU and set the machine to fold. The stock gpus.json was fetched once from api.foldingathome.org (1890 rows, vendors 0x1002, 0x10de and 0x8086 only).

Builds: `scons debug=1 strict=0` against Homebrew OpenSSL 3.6.4, with scons 4.11.1 from a venv. Apple clang 21 fails the default `strict=1` debug build in unpatched upstream code (`-Wnontrivial-memcall` in bundled re2, `-Wnonnull` in `db/Column.cpp`, deprecations in `PCIInfo.cpp`, `MacOSSystemInfo.cpp` and `MacOSPowerManagement.cpp`). `strict=0` drops only `-Werror`, and `-Wall` stays on. The new code builds without warnings (`results/build-fixed.log`).

### 1. Unpatched: the GPU is seen and dropped

`results/unpatched-log.txt:707`, then no `gpus =` line for the rest of the run. `results/unpatched-state-before.json` is `{}`.

```
18:38:52:D3:Platform:OpenCL: Apple (0) Device:Apple M2 (0) Vendor:0x1027f00 PCI:??:??:?? Compute:1.2 Driver:1.0 GPU:true
18:39:07:I1:Clean exit
```

### 2. Patched, stock gpus.json: detected, not supported

`results/patched-stock-log.txt:707-719`

```
18:52:07:D3:Platform:OpenCL: Apple (0) Device:Apple M2 (0) Vendor:0x106b PCI:??:??:?? Compute:1.2 Driver:1.0 GPU:true
18:52:07:I3:gpus = {
18:52:07:I3:  "gpu:soc:0": {
18:52:07:I3:    "vendor": 4203,
18:52:07:I3:    "type": "apple",
18:52:07:I3:    "description": "Apple M2",
18:52:07:I3:    "opencl": {"platform": 0, "device": 0, "compute": "1.2", "driver": "1.0"},
18:52:07:I3:    "device": 33042,
18:52:07:I3:    "supported": false
18:52:07:I3:  }
18:52:07:I3:}
```

33042 is 0x8112, which matches `ioreg` on the mini: `AGXAcceleratorG14G`, `"IONameMatched" = "gpu,t8112"`, `"vendor-id" = <6b100000>`, `"gpu-core-count" = 10`.

### 3. Patched, local Apple row: offered to the group, request serializes

gpus.json = stock plus `results/gpus-apple-row.json`: `{"vendor": 4203, "device": 33042, "type": 4, "species": 8}`. `ws_probe.py enable gpu:soc:0` set the default group to `cpus: 0`, enabled the GPU and set the machine to fold. `results/patched-apple-log.txt:1059-1081` and `:1128-1135`:

```
18:52:24:D1:Default:Remaining CPUs: 0, Remaining GPUs: 1, Active WUs: 0
18:52:24:I1:Default:Added new work unit: cpus:0 gpus:gpu:soc:0
18:52:24:I1:WU1:Requesting WU assignment for user Anonymous team 0 from https://127.0.0.1/api/assign
...
18:52:24:D3:WU1:    "gpu:soc:0": {
18:52:24:D3:WU1:      "gpu": "apple",
18:52:24:D3:WU1:      "vendor": 4203,
18:52:24:D3:WU1:      "device": 33042,
18:52:24:D3:WU1:      "opencl": {"platform": 0, "device": 0, "compute": "1.2", "driver": "1.0"}
18:52:24:D3:WU1:    }
...
18:52:24:D3:CON3:Failed to write request
18:52:24:E :OUT3:Failed response: EOF
18:52:24:I1:WU1:Retry #1 in 2 secs
```

The request body is built by `writeRequest`, so both `getU16` calls passed. The connection to 127.0.0.1:443 was refused (`nc -z 127.0.0.1 443` exits 1 on the mini), and the client retried with backoff until it was stopped. No account, token or FAH host was involved.

### 4. Core arguments

`Unit::run()` only runs after a signed assignment and a signed core download, which needs FAH. To exercise the real argument code, `results/test-instrumentation.patch` moves the GPU branch of `Unit::run()` into `Unit::addCoreGPUArgs()`, re-indented but otherwise unchanged, and logs its output from `Unit::assign()`. This patch is test-only and not part of the deliverable. `results/instrumented-apple-log.txt:1082`:

```
18:52:45:I1:WU1:TEST core GPU args for gpu:soc:0: -gpu-platform opencl -gpu-vendor apple -opencl-platform 0 -opencl-device 0 -gpu 0
```

The mini clone was reset to the patch commit afterwards.

### 5. Web client

`fah-web-client-bastet` 2081438 (`src/GPUFieldset.vue:60-68`) reads `gpu.type`, `gpu.supported`, `gpu.device.toString(16)`, `gpu.vendor.toString(16)` and `gpu.opencl.compute`. The client sends all of them, with `device` and `vendor` as JSON integers (`results/patched-apple-state-after.json`). `ws_probe.py` computes the same hex string, `8112`, so the page would show "PCI Device ID 0x8112" and "PCI Vendor ID 0x106b". `GroupSettings.vue:135` shows the enable checkbox when `supported` is true. Nothing in the web client parses the resource ID. I did not render the page.

## Unverified

- Any Mac other than the M2. I have IOKit data for the M2 (here) and the M3 Pro (research doc) only.
- The assignment server's handling of `gpu: "apple"` and vendor 0x106b. It is closed source.
- A release build (`debug=0`), a full x86_64 or universal build, and a non-darwin build. `MacOSGPU.cpp` alone compiles for both `-arch arm64` and `-arch x86_64` with `-Wall -Werror`, deprecations excepted. The client block is inside `#ifdef __APPLE__` and the helper lives in `os/osx`, so Linux and Windows builds do not compile the new code.
- The web page itself. The check above is by reading the source.

## M3 Ultra (Studio)

Reasoned from source only. I ran nothing on the Studio. The code path is the same. What could differ:

1. The gpus.json row needs the Studio's own SoC ID, read from `ioreg -r -c IOAccelerator` there. Asahi's table has no M3 Ultra entry, so I don't know the value. M1 Ultra is T6002 and M2 Ultra is T6022.
2. If the Ultra's `IONameMatched` is not `gpu,t` plus four hex digits, the helper returns 0, and the GPU shows up with device 0 and `supported: false`. It would not crash or disappear.
3. If the Ultra exposes two OpenCL GPU devices or two `IOAccelerator` entries, the patch lists `gpu:soc:0` and `gpu:soc:1` with the same device ID. I expect one of each but have not checked.

## Review notes

A fresh-context review found no correctness bug on single-GPU Apple silicon and no behavior change for AMD, NVIDIA or Intel. Changes taken from it: the helper moved from `hw/` to `os/osx/` and uses cbang's CF helpers; the unused `GPU_APPLE` enum value was dropped; the IOKit lookup now runs once per `detect()` instead of once per device; `VENDOR_APPLE` sits in numeric order. Two points to raise upstream before merging, not fixed here:

- The SoC ID shares the (vendor, device) keyspace with Apple's real PCI device IDs, for example the T2 and the NVMe controllers on Intel Macs. If FAH ever adds an Apple row whose ID equals a real Apple PCI device, clients that see that device would list a phantom unsupported `apple` GPU. jcoffland's 2026-01-28 plan moves to string IDs to separate these, so present this patch as a stopgap that works with today's u16 schema.
- `gpu:soc:0` is persisted in each group's config. If upstream later renames it, users who enabled the GPU lose that setting on upgrade. Agree on the ID string before merge.

## Files

- `cbang.patch`, `fah-client-bastet.patch`: the deliverable.
- `run.sh`, `ws_probe.py`: the test harness.
- `results/`: raw logs and state dumps for each run, the three build logs, the test gpus.json row, and the test-only instrumentation patch.
- Mini: `~/lab/fah-client/` has the clones with the patch commits (cbang 92edc613, client fc6a5f9) and the binaries `fah-client-unpatched`, `fah-client-patched` and `fah-client-instrumented`.

## Verification

A fresh-context verifier rebuilt both patches from fresh clones on the mini (`~/lab/verify-023/VERIFY.md` there) and confirmed claims 1 to 4: `git am` applies, the unpatched client drops the GPU, the patched one lists `gpu:soc:0` as 0x106b/0x8112, and with the Apple row it is supported and the request carries both u16 fields. The only connect target in its 4 runs was 127.0.0.1. A probe calling `getAppleGPUDeviceID()` 200,000 times leaked no Mach ports or memory (`leaks` reports 0). Its three low findings (the "cannot throw" wording, the unguarded include, the deprecated constant) are fixed in the current patches, cbang 775da343 and client 3029bea, rebuilt and rerun in `results/fixed/`.
