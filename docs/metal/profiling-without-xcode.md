# Profiling and debugging Metal without Xcode

This reference details the GPU timing, profiling, tracing, and validation tools available on Apple silicon systems equipped only with the macOS Command Line Tools (no Xcode installation).

Primary sources:
- Apple Metal framework headers in macOS 27 SDK: `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Metal.framework/Headers/`
- Metal runtime validation man page: `MetalValidation(1)` (`/usr/share/man/man1/MetalValidation.1`)
- Apple System Utility: `/usr/bin/powermetrics`
- Verification tests on local Apple silicon hardware running macOS 27

## What works with Command Line Tools alone

Machines configured with Apple Command Line Tools alone (such as the lab's base M2 Mac mini) lack the Xcode application bundle and Instruments GUI. The following table identifies what works from code and the command line without Xcode:

| Capability | Tool or Mechanism | Works With Command Line Tools Alone? | Notes / Requirements |
| :--- | :--- | :--- | :--- |
| Command buffer timing | `GPUStartTime` / `GPUEndTime` | Yes | Direct API call in completion handler |
| Metal 4 commit timing | `MTL4CommitFeedback` | Yes | Callback via `MTL4CommitOptions` |
| Hardware timestamp sampling | `MTLCounterSampleBuffer` | Yes (stage boundaries only) | Timestamp counter set only; dispatch boundary unsupported |
| Headless GPU frame trace | `MTLCaptureManager` | Yes | Exports `.gputrace` folder to disk |
| Power and GPU frequency | `powermetrics --samplers gpu_power` | Yes | Requires `sudo` (root privileges) |
| System signposts | `os_signpost` | Yes | Text output viewable via `log stream` |
| Performance overlay | Metal Performance HUD | Yes | Environment variable `MTL_HUD_ENABLED=1` |
| API correctness validation | `MTL_DEBUG_LAYER=1` | Yes | Built into Metal framework runtime |
| Shader memory safety | `MTL_SHADER_VALIDATION=1` | Yes | GPU-side bounds and pointer instrumentation |
| Instruments trace recording | `xctrace` | No | Fails: requires full Xcode installation |
| Offline shader compilation | `metal` CLI tool | No | Fails: `metal` compiler binary requires Xcode |

Running `xctrace` under Command Line Tools yields the explicit error:
`xcode-select: error: tool 'xctrace' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance`.
All shader compilation and GPU profiling must therefore be driven through runtime APIs, system daemons, and environment variables.

## Command buffer timing: GPUStartTime and GPUEndTime

Every committed command buffer records host timestamps for execution start and completion (`MTLCommandBuffer.h`, lines 286-294):
- `commandBuffer.GPUStartTime`: Host time in seconds (`CFTimeInterval`, 64-bit float) when the GPU begins executing the command buffer. Returns 0 if execution has not begun.
- `commandBuffer.GPUEndTime`: Host time in seconds when the GPU completes all encoded commands. Returns 0 until completion.
- Elapsed GPU execution time is computed as:
  ```cpp
  double elapsedSeconds = commandBuffer->GPUEndTime() - commandBuffer->GPUStartTime();
  ```
- Reading timestamps: Read values in a completion handler registered via `addCompletedHandler:`, or after blocking on `waitUntilCompleted()`.
- In Metal 4, the queue feedback mechanism delivers these timestamps via `MTL4CommitFeedback` (`MTL4CommitFeedback.h`, lines 37-40):
  ```cpp
  MTL4CommitOptions* options = MTL4CommitOptions::alloc()->init();
  options->addFeedbackHandler([](MTL4CommitFeedback* feedback) {
      double start = feedback->GPUStartTime();
      double end = feedback->GPUEndTime();
  });
  ```
- Overhead: Zero measurable GPU or CPU overhead. The driver populates these timestamps from hardware completion interrupts.

## Hardware counter sampling: MTLCounterSampleBuffer

Metal allows sampling hardware counters directly into an `MTLCounterSampleBuffer` (`MTLCounters.h`, line 111).

### Counter sets on Apple silicon
Querying `[device counterSets]` on Apple silicon (verified on M2 and M3 hardware) reveals:
- Apple silicon exposes exactly one counter set: `timestamp` (`MTLCommonCounterSetTimestamp`, `MTLCounters.h`, line 69).
- The `timestamp` counter set contains a single counter: `GPUTimestamp` (`MTLCommonCounterTimestamp`).
- Counter sets `MTLCommonCounterSetStageUtilization` and `MTLCommonCounterSetStatistic` are not exposed by the Apple silicon driver to user-space compute pipelines.

### Supported sampling points
Querying `[device supportsCounterSampling:point]` reveals hardware sampling limits:
- `MTLCounterSamplingPointAtStageBoundary`: Supported (`True`). Hardware can record timestamps at the beginning and end of a compute pass.
- `MTLCounterSamplingPointAtDispatchBoundary`: Unsupported (`False`). Apple silicon GPUs cannot record counter samples between individual dispatches inside a compute pass via `sampleCountersInBuffer:atSampleIndex:withBarrier:`.
- `MTLCounterSamplingPointAtDrawBoundary`, `AtTileDispatchBoundary`, `AtBlitBoundary`: Unsupported (`False`).

### How to sample pass timestamps
1. Allocate an `MTLCounterSampleBuffer` with storage for two samples.
2. In classic Metal, assign the sample buffer to `MTLComputePassDescriptor.sampleBufferAttachments` at indices for pass start and pass end.
3. In Metal 4, use `MTL4Counters.h`.
4. Resolve timestamps into a standard `MTLBuffer` using `[encoder resolveCounters:inRange:toBuffer:destinationOffset:]`.
5. Timestamps represent raw GPU clock ticks. Convert ticks to seconds using GPU clock frequency metadata.

## Headless GPU trace capture: MTLCaptureManager

Applications can programmatically record `.gputrace` packages to disk without Xcode or the Metal debugger attached (`MTLCaptureManager.h`, lines 33-95).

### Implementation steps
1. Set the environment variable `METAL_CAPTURE_ENABLED=1` in the launch environment.
2. Query the shared capture manager:
   ```cpp
   MTL::CaptureManager* mgr = MTL::CaptureManager::sharedCaptureManager();
   ```
3. Verify support for document capture:
   ```cpp
   if (!mgr->supportsDestination(MTL::CaptureDestinationGPUTraceDocument)) {
       // Abort or log
   }
   ```
4. Create an `MTLCaptureDescriptor`:
   ```cpp
   MTL::CaptureDescriptor* desc = MTL::CaptureDescriptor::alloc()->init();
   desc->setCaptureObject(device); // Captures all queues on device
   desc->setDestination(MTL::CaptureDestinationGPUTraceDocument);
   NS::String* path = NS::String::string("/path/to/simulation.gputrace", NS::UTF8StringEncoding);
   desc->setOutputURL(NS::URL::fileURLWithPath(path));
   ```
5. Trigger capture around the target simulation step:
   ```cpp
   NS::Error* error = nullptr;
   mgr->startCapture(desc, &error);
   // Execute one or more simulation steps
   mgr->stopCapture();
   desc->release();
   ```
6. The resulting `.gputrace` directory contains full command buffer streams, bound buffers, shader sources, and memory snapshots. Developers can transfer this folder to another machine with Xcode installed to inspect shader execution in the Metal Frame Debugger.

## Hardware telemetry with powermetrics

macOS provides `/usr/bin/powermetrics` to monitor SoC power, active GPU residency, and GPU clock frequencies without graphical tools.

### Usage
Because `powermetrics` reads hardware performance counters directly from system controllers, execution requires root privileges (`sudo`).

```bash
sudo powermetrics --samplers gpu_power -i 500 -n 10
```

### Key metrics reported
1. `GPU Active residency`: Percentage of sample window during which GPU ALUs were active (e.g., 94.2%). If residency drops significantly below 100% during an MD run, the GPU is starving due to CPU dispatch latency.
2. `GPU active frequency`: Current clock frequency in MHz (e.g., 1398 MHz on M2, up to 1750 MHz on M3 Ultra). Identifies whether thermal or power limits throttle GPU clocks.
3. `GPU Power`: Estimated power consumed by the GPU complex in milliwatts (e.g., 8400 mW).

## Unified logging and os_signpost

Developers can insert timeline markers using `<os/signpost.h>`. While Instruments is the standard tool to visualize signposts, command-line environments can stream signposts as text.

### In code
```c
#include <os/log.h>
#include <os/signpost.h>

os_log_t log = os_log_create("org.openmm.metal", "benchmarks");
os_signpost_id_t spid = os_signpost_id_generate(log);

os_signpost_interval_begin(log, spid, "NonbondedForce");
// Dispatch nonbonded compute kernels
os_signpost_interval_end(log, spid, "NonbondedForce");
```

### Viewing on the command line
In a separate terminal on the same machine, stream live events:
```bash
log stream --predicate 'subsystem == "org.openmm.metal"' --info --debug
```

## Metal runtime and shader validation environment variables

The macOS Metal framework includes detailed diagnostic layers controlled entirely by environment variables (`MetalValidation(1)` man page). Setting these variables requires no code modifications or rebuilds.

### API validation
Validates CPU-side API usage (null arguments, binding out-of-range slots, missing pipeline states):
- `MTL_DEBUG_LAYER=1`: Enables the Metal API debug validation layer.
- `MTL_DEBUG_LAYER_ERROR_MODE=assert`: Causes the process to assert and halt immediately on API violations. Alternative values: `nslog` (logs to console), `ignore`.
- `MTL_DEBUG_LAYER_WARNING_MODE=nslog`: Controls reporting of performance and usage warnings.
- `MTL_DEBUG_LAYER_VALIDATE_UNRETAINED_RESOURCES=1`: Detects resources destroyed while still referenced by in-flight command buffers.

### GPU shader validation
Instruments shaders to detect out-of-bounds buffer reads, illegal pointer writes, invalid threadgroup memory access, and non-resident resources:
- `MTL_SHADER_VALIDATION=1`: Enables runtime GPU shader validation.
- `MTL_SHADER_VALIDATION_GLOBAL_MEMORY=1`: Instruments `device` and `constant` memory accesses. Detects out-of-bounds array reads and writes.
- `MTL_SHADER_VALIDATION_THREADGROUP_MEMORY=1`: Instruments `threadgroup` memory accesses.
- `MTL_SHADER_VALIDATION_FAIL_MODE=zerofill`: Determines behavior when out-of-bounds access occurs. `zerofill` returns 0 for reads and drops writes safely. `allow` permits invalid memory accesses.
- `MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1`: Prints validation error descriptions directly to `stderr` instead of routing solely through Unified Logging.
- `MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1`: Halts execution immediately upon detecting an invalid memory access.
- `MTL_SHADER_VALIDATION_ENABLE_PIPELINES="name1,name2"`: Restricts shader validation overhead to specific pipeline labels.

## Metal Performance HUD

The Metal Performance HUD draws an overlay displaying real-time FPS, frame duration, GPU execution time, memory footprint, and thermal status.

### Configuration
Set environment variables before starting the application:
```bash
MTL_HUD_ENABLED=1 ./openmm_benchmark
```

Optional configuration:
- `MTL_HUD_LOG_ENABLED=1`: Writes per-frame metrics to system log.
- `MTL_HUD_LOG_SHADER_ENABLED=1`: Logs shader compile pauses.
- `MTL_HUD_REPORT_URL=/path/to/report.json`: Directs the HUD to output performance summary reports in JSON format.

Note: The HUD requires a windowed presentation surface (`CAMetalLayer`). In headless compute-only CLI processes without a display window, HUD graphics do not render, but file logging via `MTL_HUD_REPORT_URL` can record telemetry.

## Consequences for an OpenMM Metal platform

1. Because `xctrace` requires full Xcode, the headless Mac mini test harness must rely exclusively on programmatic timing (`GPUStartTime` / `GPUEndTime`) and `powermetrics` for performance benchmarking.
2. Per-kernel timing cannot rely on `MTLCounterSampleBuffer` because Apple silicon GPUs explicitly disallow counter sampling at dispatch boundaries (`supportsCounterSampling:AtDispatchBoundary == False`). Profiling individual kernel execution durations within an MD step requires either isolating kernels into separate compute passes (with stage boundary timestamps) or capturing a `.gputrace` for external analysis.
3. Automated test suites on the Mac mini should run with `MTL_DEBUG_LAYER=1` and `MTL_SHADER_VALIDATION=1 MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1` during development. This immediately surfaces buffer overruns, missing synchronization barriers, and race conditions without requiring interactive debugging.
4. Production benchmark runs must strictly unset all validation variables (`MTL_DEBUG_LAYER=0`, `MTL_SHADER_VALIDATION=0`). Shader validation injects heavy memory instrumentation that skews MD step throughput.
5. The platform should expose an optional `--trace` CLI flag that triggers `MTLCaptureManager` to write a single-step `.gputrace` file to disk. When performance anomalies or numerical regressions occur on the headless mini, the trace file can be scp-copied to a workstation with Xcode for full pipeline debugging.
6. The test script can use `sudo powermetrics --samplers gpu_power` during long benchmark runs to confirm whether low step throughput stems from GPU compute saturation (near 100% active residency) or CPU dispatch bottlenecks (low GPU residency).
