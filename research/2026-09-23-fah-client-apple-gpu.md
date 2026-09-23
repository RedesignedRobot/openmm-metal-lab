# FAH client: what it takes to detect and assign an Apple silicon GPU

Date: 2026-09-23. Sources: fah-client-bastet master d85c21a (2026-09-11, package.json 8.5.7), cbang master 12fa35b8 (2026-09-19), fah-web-client-bastet 2081438 (2026-09-20), live api.foldingathome.org/gpus, and OpenCL/IOKit queries on the M3 Pro laptop (macOS 27.0 26A428, metadata only, no kernels).

## Summary

1. Recommended patch: in cbang, add `VENDOR_APPLE = 0x106b` to `GPUVendor.h`, map Apple's OpenCL vendor ID 0x1027f00 to 0x106b in `OpenCLLibrary::getVendorID`, and add a ~20-line IOKit helper that turns the GPU's `IONameMatched = "gpu,t6030"` into device ID 0x6030. In fah-client-bastet, add ~15 lines to `GPUResources::detect` under `#ifdef __APPLE__` that keep the non-PCI Apple OpenCL GPU as `gpu:soc:0` and look up its species in gpus.json by (0x106b, 0x6030).
2. The drop happens at `GPUResources.cpp:157`, `if (!cd.isPCIValid()) continue;`. Apple OpenCL offers no PCI extension, so bus/slot/function stay -1. Removing that one line is not enough: `supported` is only set in the PCI loop (`:217`), and `writeRequest` calls `getU16("device")` (`GPUResource.cpp:96`), which throws when the key is missing.
3. I checked this on the M3 Pro under macOS 27.0. OpenCL still loads and reports `Apple M3 Pro`, vendor 0x1027f00, type GPU, driver `1.2 1.0`, with no `cl_khr_pci_bus_info`, no `cl_khr_device_uuid` and no `cl_khr_fp64`. IOKit's `AGXAcceleratorG15X` has `vendor-id` 0x106b, `IONameMatched` "gpu,t6030" and `gpu-core-count` 18.
4. Species gate: the live gpus.json has 1890 rows keyed by u16 vendor/device, and none use vendor 0x106b. A row `{vendor: 0x106b, device: 0x6030, type: 4, species: N}` fits the current format without a schema change. The assignment server still has to learn an Apple species constraint. That code is closed source and I could not check it.
5. For a GPU work unit, the client passes the core `-gpu-platform cuda|opencl -gpu-vendor <type> -opencl-platform P -opencl-device D [-cuda-*/-hip-*] -gpu D [-gpu-uuid U]` (`Unit.cpp:639-667`). With the patch, an Apple GPU gets `-gpu-platform opencl -gpu-vendor apple -opencl-platform 0 -opencl-device 0 -gpu 0`. A `metal` platform flag is a separate follow-up.
6. The hard blocker is outside the client. No macOS GPU FahCore exists, and the client only runs cores signed with the FAH key usage `core%02x` (`Core.cpp:133-135`). Our Metal OpenMM reaches volunteers only through a core that FAH builds and signs.
7. Maintainer position: on 2025-11-18 jcoffland said "We'd need a completely different strategy". On 2026-01-28 he posted a three-step plan (non-PCI gpus.json IDs `<bus>:<vendor ID>:<device ID>`, AS/DB changes, OS-specific client enumeration) and wrote "This is a priority though". No related commit has landed in either repo since.
8. Pitch the patch as step 3 of his plan, with IDs that map onto his format: type `soc:106b:6030` and instance `gpu:soc:0`. Frame it as a draft PR plus a comment on #303, not a surprise PR.
9. Build: FAH ships macOS 8.5.6 as a universal binary (x86_64 + arm64; I checked with `file`). The source build is `brew install scons openssl@3`, then set `CBANG_HOME` and `OPENSSL_HOME`, then `scons -C cbang` and `scons -C fah-client-bastet`. Use `debug=1` to get the per-device OpenCL log lines.
10. Unverified: the AS side, how Core22 parses arguments, whether M1/M2/M3 Ultra shows up as one GPU (I believe so but did not check), and the species split for M5 Pro and M5 Max, which share SoC ID T6050.

## 1. How the client enumerates GPUs, and where Apple GPUs get dropped

The flow runs in `GPUResources::detect()` (`fah-client-bastet/src/fah/client/GPUResources.cpp:151-247`). Everything below comes from reading the source.

- OpenCL probing happens in cbang's `OpenCLLibrary` constructor (`cbang/src/cbang/hw/OpenCLLibrary.cpp:212-276`). On macOS it dlopens `/System/Library/Frameworks/OpenCL.framework/OpenCL` (`:54-56`) and walks every platform and device with `CL_DEVICE_TYPE_ALL`. It keeps a device only if `ComputeDevice::isValid()` passes (`:273`), which needs non-zero driver and compute versions (`ComputeDevice.cpp:42-45`).
- PCI info on OpenCL devices comes from `cl_khr_pci_bus_info` if the extension is present (`OpenCLLibrary.cpp:266-268`). Otherwise the vendor-specific path (`:390-397`) handles AMD and NVIDIA only; Intel is a `TODO` and everything else falls through to `default: break`. On Apple, the PCI fields stay at -1.
- In the client, `get_gpus<LIB>()` keeps devices with `isValid() && gpu` (`GPUResources.cpp:66`). Apple's GPU passes both checks: type is GPU, and the driver string `1.2 1.0` parses to 1.0 in `getDriverVersion` (`OpenCLLibrary.cpp:285-308`).
- Drop point: `GPUResources.cpp:157` has `if (!cd.isPCIValid()) continue;`. `isPCIValid()` needs bus, slot and function (`ComputeDevice.cpp:61-63`), and the Apple GPU has none of them.
- CUDA probing is compiled out on Apple (`GPUResources.cpp:164-178`). HIP probing uses the same PCI skip (`:183`).
- The PCI bus walk (`:194-221`) builds `PCIInfo` from IOKit `IOPCIDevice` entries (`cbang/src/cbang/hw/PCIInfo.cpp:175-220`) and skips entries without `vendor-id` and `device-id` (`:189`). The Apple GPU is an `AppleARMIODevice` child, not an `IOPCIDevice`, so it never shows up. Each PCI device is looked up with `gpuIndex.find(vendor, device)` (`GPUResources.cpp:199`), and non-GPUs are skipped (`:205`).
- The support rule is `supported = species != 0 && found by OpenCL/CUDA/HIP` (`:215-217`). A GPU that skips the PCI loop never gets `supported`, and `GPUResource::isSupported` requires it (`GPUResource.cpp:83-88`). `Config::getGPUs` only offers supported and enabled GPUs to groups (`Config.cpp:127-143`).
- The species table is gpus.json, downloaded from `https://api.foldingathome.org/gpus` (`GPUResources.cpp:144`). The client uses a cached copy from its working directory while it is less than 5 days old (`:125-139`). `cb::GPU` stores vendor, device, type and species as `uint16_t` (`cbang/src/cbang/hw/GPU.h:49-53`), and `GPUIndex` keys on (vendor, device) (`GPUIndex.cpp:48-51`). GPU types are 1 AMD, 2 NVIDIA and 3 Intel (`GPUType.h:47-52`). `GPUVendor` knows only 0x1002, 0x10de and 0x8086 (`GPUVendor.h:46-51`).
- Live gpus.json, fetched 2026-09-23: 1890 rows, keys `{vendor, device, type, species, description}`, vendors 0x10de/0x1002/0x8086 only, types {0, 1, 2, 3}. No Apple rows.

A second, independent failure: if the Apple device got past line 157, `GPUResource::set` would store `vendor` = 0x1027f00 (`GPUResource.cpp:55-57`). The assignment request then calls `getU16("vendor")` and `getU16("device")` (`GPUResource.cpp:95-96`). cbang's `getU16` throws on out-of-range values (`cbang/src/cbang/json/Number.h:103-116`), and `device` would be missing altogether. The web UI also assumes both exist: it calls `gpu.device.toString(16)` (`fah-web-client-bastet/src/GPUFieldset.vue:67-68`).

Measured on this laptop (macOS 27.0, M3 Pro, metadata queries only):

```
OpenCL platform 0: Apple | OpenCL 1.2 (Aug  8 2026 15:27:26)
 dev 0 'Apple M3 Pro' vendorID=0x1027f00 type=4(GPU) driver='1.2 1.0' version='OpenCL 1.2 '
 ext: cl_APPLE_* cl_khr_gl_event cl_khr_byte_addressable_store cl_khr_*_int32_*_atomics
      cl_khr_3d_image_writes cl_khr_image2d_from_buffer cl_khr_depth_images
IOKit AGXAcceleratorG15X (provider AppleARMIODevice):
 "vendor-id" = <6b100000>  "IONameMatched" = "gpu,t6030"  "model" = "Apple M3 Pro"  "gpu-core-count" = 18
```

This matches the 2021 M1 clinfo output in [hashcat#2976](https://github.com/hashcat/hashcat/issues/2976), which also shows vendor 0x1027f00 and driver `1.2 1.0`. `t6030` is M3 Pro in the [Asahi SoC codename table](https://asahilinux.org/docs/hw/soc/soc-codenames/). The extension list has no `cl_khr_fp64`, which matters for the core and not the client.

## 2. How the client tells a core which GPU to use

All from `Unit::run()` (`fah-client-bastet/src/fah/client/Unit.cpp:610-684`):

- The unit's GPU list comes from the assignment response (`assignment.data.gpus`, `:597`). `run()` uses only `gpus[0]` (`:641`).
- `-gpu-uuid <uuid>` is passed when the resource has a UUID (`:645-648`). On Apple none is set, because the device lacks `cl_khr_device_uuid`.
- `-gpu-platform cuda|opencl` (`:651-654`). HIP never gets its own value here. Open PR [#442](https://github.com/FoldingAtHome/fah-client-bastet/pull/442) (stoney-arch, 2026-05-04) adds `getGPUPlatform()` returning cuda, hip or opencl. jcoffland replied on 2026-05-05: "This is still a draft so I'll wait to merge."
- `-gpu-vendor <type>`, the lowercased `GPUVendor` name, for example `nvidia` (`:657-658`, `GPUResource.cpp:41-43`). An unknown vendor would come out as `unknown_enum` (`cbang/src/cbang/enum/MakeEnumerationImpl.def:196`).
- `addGPUArgs` emits `-<name>-platform P -<name>-device D` for opencl, and for cuda/hip when enabled (`Unit.cpp:93-101`, `:660-662`).
- `-gpu <opencl device index>` (`:664-667`), a legacy flag.
- Other arguments: `-dir <id> -suffix 01 -version <client> -lifeline <pid>` (`:628-635`).
- The assignment request sends the AS `{gpu: type, vendor: u16, device: u16, cuda/hip/opencl: {platform, device, compute, driver}}` per GPU (`GPUResource.cpp:91-106`, `Unit.cpp:1120-1125`), plus `project.beta` and `project.key` (`:1094-1101`). The client never sends species. I infer from this that the AS does its own species lookup from vendor and device.
- Cores are verified before they run: SHA-256 against the assignment, then the certificate chain, FAH key usage `core|core<type>`, and signature (`Core.cpp:125-136`, `App.cpp:336-354`). A self-built core will not run under a stock client.

How Core22 parses these flags is closed source and unverified. The flag names above are what the client sends, not what I have seen a core accept.

## 3. Smallest correct patch, and how to get a species gate

### Recommended patch

cbang, four small changes:

1. `src/cbang/hw/GPUVendor.h:51`: add `CBANG_ENUM_VALUE(VENDOR_APPLE, 0x106b)`. 0x106b is Apple's PCI vendor ID (cbang already lists it at `PCIVendor.cpp:215`) and the value IOKit reports in the GPU's `vendor-id`. As a result, `type` becomes `apple`.
2. `src/cbang/hw/OpenCLLibrary.cpp:336-337`: next to the existing "Integrated AMD cards on Apple" fixup, add
   ```cpp
   // Apple silicon GPUs report a non-PCI vendor ID
   if (vendorID == 0x1027f00) vendorID = GPUVendor::VENDOR_APPLE;
   ```
3. `src/cbang/hw/GPUType.h:52`: add `CBANG_ENUM_VALUE(GPU_APPLE, 4)`. FAH has to agree on this number, because it is a gpus.json field.
4. A new free function, for example in `PCIInfo.cpp` or its own `AppleGPU.cpp`, built only under `__APPLE__ && __aarch64__`:
   ```cpp
   // @return Apple SoC ID of the integrated GPU, e.g. 0x6030 for M3 Pro, or 0
   uint16_t cb::getAppleGPUDeviceID() {
     io_service_t gpu = IOServiceGetMatchingService(
       kIOMasterPortDefault, IOServiceMatching("IOAccelerator"));
     if (!gpu) return 0;

     CFTypeRef ref = IORegistryEntryCreateCFProperty(
       gpu, CFSTR("IONameMatched"), kCFAllocatorDefault, 0);
     IOObjectRelease(gpu);
     if (!ref) return 0;

     char name[32] = "";
     bool ok = CFGetTypeID(ref) == CFStringGetTypeID() &&
       CFStringGetCString((CFStringRef)ref, name, sizeof(name),
                          kCFStringEncodingUTF8);
     CFRelease(ref);

     // Expect "gpu,t<4 hex digits>", e.g. "gpu,t6030"
     if (!ok || strncmp(name, "gpu,t", 5) || strlen(name) < 9) return 0;
     return String::parseU16("0x" + string(name + 5, 4));
   }
   ```
   `IONameMatched` is a CFString, unlike the CFData properties that `PCIInfo` reads, so the existing `getIORegistryProperty` helper does not fit. Parse exactly four digits: `t8140a` exists, although only on phones.

fah-client-bastet, one block in `GPUResources::detect()`. Insert it after the PCI loop (`GPUResources.cpp:221`) so that `valid` is in scope:

```cpp
#ifdef __APPLE__
  // Apple silicon GPUs are not PCI devices.  Identify them by SoC ID.
  unsigned socIndex = 0;
  for (auto &cd: openclGPUs) {
    if (cd.isPCIValid() || cd.vendorID != GPUVendor::VENDOR_APPLE) continue;

    uint16_t deviceID = getAppleGPUDeviceID();
    const auto &gpu = gpuIndex.find(GPUVendor::VENDOR_APPLE, deviceID);
    string id = "gpu:soc:" + String(socIndex++);

    auto res = resources[id] = new GPUResource(id);
    res->set("opencl", cd);          // vendor 0x106b, type "apple", description
    res->insert("device", deviceID);
    res->insertBoolean("supported", gpu.getSpecies());
    if (gpu.getSpecies()) valid.insert(id);
  }
#endif // __APPLE__
```

Nothing else in the client needs to change. `isSupported`, `Config::getGPUs`, the group scheduler, `waitOnGPU` and `writeRequest` work unchanged once `supported`, `vendor`, `device` and an `opencl` entry exist. `Unit::run` then emits `-gpu-platform opencl -gpu-vendor apple -opencl-platform 0 -opencl-device 0 -gpu 0`. The web UI shows the checkbox because `supported` is true (`GroupSettings.vue:135`). Its "PCI Device ID" label is cosmetic.

Why this shape: it reuses the OpenCL enumeration the client already does. The reason Apple GPUs are invisible today is that the client throws that result away, a point Artoria2e5 made on #303 on 2026-01-26. It adds no Objective-C and no Metal dependency to cbang. It keeps the u16 gpus.json schema, and the ID maps one-to-one onto jcoffland's proposed `<bus>:<vendor ID>:<device ID>` form as `soc:106b:6030`.

Alternatives I rejected:
- Dropping line 157 alone: it breaks on `supported` and `getU16`, as described in section 1.
- Adding a Metal compute library to cbang: this needs Objective-C++ and `MTLCopyAllDevices`. More code, and nothing in the client needs Metal to pick a GPU. If the core wants to cross-check the device, `MTLDevice.registryID` is the IORegistry entry ID ([Apple docs](https://developer.apple.com/documentation/Metal/MTLDevice/registryID)), so an IOKit-found device can be matched to a Metal device later.
- Relying on OpenCL long-term: Apple deprecated OpenCL in 10.14 ([developer.apple.com/opencl](https://developer.apple.com/opencl/)). It still loads on macOS 27.0, but if Apple removes it, detection dies with it. A follow-up could enumerate from IOKit `IOAccelerator` directly and use OpenCL only for the platform and device index.

Optional follow-up for a Metal core: add a `metal` compute entry (`{platform: 0, device: 0}`) to Apple resources. `addGPUArgs(args, gpu, "metal")` then emits `-metal-platform 0 -metal-device 0` with no new code, and PR #442's `getGPUPlatform()` would return `metal` first for Apple. The web UI's compute list is hardcoded to OpenCL/CUDA/HIP (`GPUFieldset.vue:38`) and would need `Metal` added. Keep this out of the first PR.

### Getting a species and project gate

1. gpus.json rows, for example `{vendor: 4203, device: 24624 (0x6030), type: 4, species: N, description: "Apple M3 Pro"}`. SoC IDs from Asahi: T8103 M1, T6000/T6001/T6002 M1 Pro/Max/Ultra, T8112 M2, T6020/T6021/T6022 M2 Pro/Max/Ultra, T8122 M3, T6030 M3 Pro, T6031/T6034 M3 Max, T8132 M4, T6040/T6041 M4 Pro/Max, T8142 M5, T6050 M5 Pro/Max ([asahilinux.org](https://asahilinux.org/docs/hw/soc/soc-codenames/)). M3 Ultra is not in that table. The SoC ID also ignores GPU core binning: M3 Pro ships with 14 or 18 cores and both map to 0x6030.
2. The AS has to accept vendor 0x106b and apply a per-project constraint. FAH's own species repo describes constraints in the form `NVIDIAGPUSpecies >= 3` ([fah-gpu-species README](https://github.com/FoldingAtHome/fah-gpu-species)), so Apple presumably needs its own key. That is reported, and the server is closed. The AS also has to serve a macOS arm64 GPU core.
3. Internal-only testing: the client already sends `project.key` from the group `key` config (`Unit.cpp:1099-1100`, `resources/group.json`) and `project.beta`. A keyed project restricted to Apple species is the natural closed gate. This is inference about how FAH would use it.
4. Collision risk: old clients on Intel Macs look up real PCI devices with vendor 0x106b. If one of those device IDs equals a SoC ID, an old client would treat it as a GPU with `type != 0`. It still would not be `supported`, because no OpenCL device matches its PCI address (`GPUResources.cpp:217`). The risk is low, and I checked it only by reading the code.

### Maintainer and contributor statements

- jcoffland (member), 2025-11-18, [#303](https://github.com/FoldingAtHome/fah-client-bastet/issues/303#issuecomment-3548101121): "Another problem with utilizing Apple's integrated GPUs is that they apparently are not on a PCI bus. We use the PCI bus data to identify the GPU and differentiate it from other GPUs. We'd need a completely different strategy for these chips."
- jcoffland, 2026-01-28, [#303](https://github.com/FoldingAtHome/fah-client-bastet/issues/303#issuecomment-3811848006): "I have a plan for implementing this. The main problem is not how to do it but finding the time. It will require changes to the main DB, Assignment Servers and client software as well as some back-end tools we use for managing the GPUs whitelist. This is a priority though." The plan: (1) gpus.json allows non-PCI GPU ID strings, (2) update AS, DB and backend, (3) enumerate non-PCI GPUs in the client with OS-specific code. Type ID `<bus>:<vendor ID>:<device ID>`, plus a separate instance ID like today's `gpu:<bus>:<slot>:<function>`. He also raised multi-SoC systems with more than one integrated GPU.
- Artoria2e5, 2026-01-26, [#303](https://github.com/FoldingAtHome/fah-client-bastet/issues/303#issuecomment-3797914537): the client "already make[s] that OpenCL get devices call, we just discard the result because it has no PCI". Proposed OpenCL vendor ID + model string for the gpuIndex.
- kbernhagen (contributor), 2024-11-06, [#303](https://github.com/FoldingAtHome/fah-client-bastet/issues/303#issuecomment-2458490975): "for Apple silicon, it seems like it could be safe to always enable for OpenCL the GPU found using the OpenCL api." On 2025-11-14 he added: "In other words, no. Not anytime soon. It is currently unknown if openmm for apple silicon OpenCL is even capable of doing what is needed for a FahCore."
- muziqaz (contributor, not staff), 2024-11-05 and 2025-11-14, #303: "There are no plans to support Apple GPUs", and "Even if fahclient support is implemented, there will not going to be a new fahcore supporting Apple GPUs."
- Folding Forum thread "Apple M1, M2, M3, M4", December 2025 ([forum.foldingathome.org t=43406](https://forum.foldingathome.org/viewtopic.php?t=43406), fetched through a summarizer, so treat these quotes as reported): Joe_H (site admin) listed three blockers: no PCI identity, no fp64 ("all GPU folding cores for F@H enable that and use it for critical calculations"), and client code. calxalot (moderator): "All Apple silicon has a decent iGPU. There is no need to detect presence, only to classify by M-series generation."
- No commit in either repo since 2026-01-28 touches non-PCI GPUs. I checked `git log` for GPU/PCI/Apple/OpenCL through cbang 2026-09-19 and client 2026-09-11. The only nearby change is cbang e23de8b8 (2026-08-12, PCI domain for VMs).

## 4. Native macOS arm64 build

- It runs natively today. The official 8.5.6 macOS release is `macos-12-universal` ([meta.json](https://download.foldingathome.org/releases/public/fah-client/meta.json)). `file` on the release tarball's `fah-client` shows a Mach-O universal binary for x86_64 and arm64, linking only system dylibs and frameworks (IOKit, CoreFoundation, Security, SystemConfiguration), so OpenSSL is linked statically. Joe_H wrote on 2023-12-26 that the client and CPU cores are native on Apple silicon and that "GPU folding is not supported on any macOS system" ([forum t=40941](https://forum.foldingathome.org/viewtopic.php?t=40941), reported).
- Build system: scons. The client's `SConstruct` needs `CBANG_HOME` and loads cbang's config tools. cbang defaults to clang on darwin (commit 3e9f92bf, 2025-12-09) and adds `-arch` only when `osx_archs` is set (`cbang/config/compiler/__init__.py:365-369`). A plain build is native arm64. OpenSSL is found through `OPENSSL_HOME` (`cbang/config/__init__.py:251`, `config/openssl/__init__.py`), version 1.1.0 or later. zlib, bzip2, lz4, sqlite3, expat, boost, libevent, re2 and libyaml are bundled and built locally when not found (`cbang/SConstruct:97-101`).
- PR #442's author reported building both repos with SCons against Homebrew OpenSSL on 2026-05-04 (reported).

Steps for the Mac mini. I have not run these.

```sh
xcode-select --install            # CLT, if missing
brew install scons openssl@3 git
mkdir -p ~/src/fah && cd ~/src/fah
git clone https://github.com/cauldrondevelopmentllc/cbang
git clone https://github.com/foldingathome/fah-client-bastet
# Pin to the last release, or stay on master for a PR branch:
git -C cbang checkout bastet-v8.5.6
git -C fah-client-bastet checkout v8.5.6
export CBANG_HOME=$PWD/cbang
export OPENSSL_HOME=$(brew --prefix openssl@3)
scons -C cbang -j8 debug=1        # debug=1 enables LOG_DEBUG, which prints each OpenCL device
scons -C fah-client-bastet -j8 debug=1
file fah-client-bastet/fah-client # expect arm64
```

Local test of the patch without FAH servers:
1. Run from an empty scratch directory, not an installed client's data dir. For example `mkdir ~/fahtest && cd ~/fahtest && ~/src/fah/fah-client-bastet/fah-client --verbosity 5`. The client writes its DB and logs to the working directory when run by hand (README).
2. After the first run, add an Apple row to the `./gpus.json` it downloaded. The client keeps a local copy for 5 days (`GPUResources.cpp:125-139`). The file warns that editing it "will lead to a FAH error". That error would come at assignment, so this checks only detection.
3. Check the log line `gpus = {... "gpu:soc:0": {... "type":"apple","vendor":4203,"device":24624,"supported":true,"opencl":{...}}}`, printed at INFO level 3 (`GPUResources.cpp:244`). Then check that the web UI at https://app.foldingathome.org shows an enable checkbox.
4. End-to-end assignment is impossible without FAH: the AS must know the species, and the core must be FAH-signed.

## Caveats

- AS, DB and core code are closed. Everything about species constraints on the server and about how Core22 reads its arguments is inference or second-hand.
- I did not check how Ultra parts show up. I expect one OpenCL device and one IOAccelerator, so the patch's `IOServiceGetMatchingService` (first match) would be fine, but I have not seen it. If a future Mac has two, the helper must iterate and pair entries with OpenCL devices, and `gpu:soc:<n>` ordering becomes a real design question, which is the one jcoffland raised.
- M5 Pro and M5 Max share T6050 in Asahi's table, and binned parts share an ID. SoC ID is a coarse species key. `gpu-core-count` is available from the same IOKit node if FAH wants finer classes.
- Ncard00123 posted "Device ID: 0x018880" for an M4 Mac mini on #303 (2026-01-28). I saw no Device ID on the M3 Pro in system_profiler or IOKit and cannot reproduce that value. Don't build on it.
- Apple GPUs report no `cl_khr_fp64`. That is a core and precision problem (Joe_H's second blocker), not a client one, and df64 work covers it on our side.
- I queried OpenCL device metadata on this laptop through ctypes (clGetPlatformIDs/clGetDeviceInfo only, no context, no kernels). No builds were run.

## Pointers

- `fah-client-bastet/src/fah/client/GPUResources.cpp:151-247`: the whole detection path and the one place to patch.
- `cbang/src/cbang/hw/OpenCLLibrary.cpp:212-419`: device probing, vendor fixups, PCI extraction.
- `fah-client-bastet/src/fah/client/Unit.cpp:610-684` and `:1080-1130`: core arguments and the assignment request body.
- https://github.com/FoldingAtHome/fah-client-bastet/issues/303: where to propose the patch, next to jcoffland's 2026-01-28 plan.
- https://github.com/FoldingAtHome/fah-client-bastet/pull/442: open draft that rewrites `-gpu-platform` selection. Any `metal` flag should build on it.
