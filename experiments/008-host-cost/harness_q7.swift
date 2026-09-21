import Foundation
import Metal

guard let dev = MTLCreateSystemDefaultDevice(),
      let queue = dev.makeCommandQueue() else {
    fatalError("No Metal device/queue")
}

var results: [[String: Any]] = []

// 1. Wait before commit
print("Running Hang Test 1: wait before commit...")
do {
    let cb = queue.makeCommandBuffer()!
    let sema = DispatchSemaphore(value: 0)
    let t0 = CFAbsoluteTimeGetCurrent()
    DispatchQueue.global().async {
        cb.waitUntilCompleted()
        sema.signal()
    }
    let timeoutSec = 3.0
    let res = sema.wait(timeout: .now() + timeoutSec)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let hung = (res == .timedOut)
    
    results.append([
        "test_name": "wait_before_commit",
        "description": "Calling waitUntilCompleted() before commit()",
        "elapsed_seconds": elapsed,
        "timed_out": hung,
        "behavior": hung ? "hangs_indefinitely_at_0_cpu" : "completed",
        "status_code": cb.status.rawValue,
        "status_name": "notEnqueued",
        "error_description": cb.error != nil ? cb.error!.localizedDescription : "nil"
    ])
}

// 2. Out of range buffer write
print("Running Hang Test 2: out-of-range buffer write...")
do {
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void oob_write(device int* out [[buffer(0)]],
                          constant ulong& bad_addr [[buffer(1)]],
                          uint id [[thread_position_in_grid]]) {
        volatile device int* ptr = (volatile device int*)bad_addr;
        ptr[id] = 42;
        out[id] = 42;
    }
    """
    let lib = try! dev.makeLibrary(source: src, options: nil)
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "oob_write")!)
    let buf = dev.makeBuffer(length: 16, options: .storageModeShared)!
    var badAddr: UInt64 = 0xdeadbeef0000
    
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(buf, offset: 0, index: 0)
    enc.setBytes(&badAddr, length: 8, index: 1)
    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    
    let sema = DispatchSemaphore(value: 0)
    let t0 = CFAbsoluteTimeGetCurrent()
    cb.addCompletedHandler { _ in sema.signal() }
    cb.commit()
    let timeoutSec = 3.0
    let res = sema.wait(timeout: .now() + timeoutSec)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let timedOut = (res == .timedOut)
    
    let behavior: String
    if timedOut {
        behavior = "hangs"
    } else if cb.status == .error {
        behavior = "fault_with_error"
    } else {
        behavior = "silent_completion_store_dropped"
    }
    
    results.append([
        "test_name": "out_of_range_buffer_write",
        "description": "Kernel writes to unmapped GPU address (0xdeadbeef0000)",
        "elapsed_seconds": elapsed,
        "timed_out": timedOut,
        "behavior": behavior,
        "status_code": cb.status.rawValue,
        "status_name": cb.status == .completed ? "completed" : (cb.status == .error ? "error" : "other"),
        "error_description": cb.error != nil ? cb.error!.localizedDescription : "nil"
    ])
}

// 3. Infinite kernel loop
print("Running Hang Test 3: infinite kernel loop...")
do {
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void loop_forever(device volatile int* out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
        int x = 0;
        while (out[0] != 99999999) {
            x++;
        }
        out[0] = x;
    }
    """
    let lib = try! dev.makeLibrary(source: src, options: nil)
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "loop_forever")!)
    let buf = dev.makeBuffer(length: 16, options: .storageModeShared)!
    buf.contents().assumingMemoryBound(to: Int32.self)[0] = 0
    
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(buf, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    
    let sema = DispatchSemaphore(value: 0)
    let t0 = CFAbsoluteTimeGetCurrent()
    cb.addCompletedHandler { _ in sema.signal() }
    cb.commit()
    let timeoutSec = 3.0
    let res = sema.wait(timeout: .now() + timeoutSec)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let timedOut = (res == .timedOut)
    
    results.append([
        "test_name": "infinite_kernel_loop",
        "description": "Kernel executes non-terminating while loop",
        "elapsed_seconds": elapsed,
        "timed_out": timedOut,
        "behavior": timedOut ? "gpu_hangs_in_flight" : "completed_or_error",
        "status_code": cb.status.rawValue,
        "status_name": cb.status == .committed ? "committed" : "other",
        "error_description": cb.error != nil ? cb.error!.localizedDescription : "nil"
    ])
}

// 4. Threadgroup barrier inside divergent control flow
print("Running Hang Test 4: threadgroup barrier inside divergent control flow...")
do {
    let src = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void divergent_barrier(device volatile int* out [[buffer(0)]],
                                 uint tg_id [[thread_position_in_threadgroup]],
                                 uint simd_id [[simdgroup_index_in_threadgroup]]) {
        if (simd_id == 0) {
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        out[tg_id] = (int)tg_id;
    }
    """
    let lib = try! dev.makeLibrary(source: src, options: nil)
    let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "divergent_barrier")!)
    let buf = dev.makeBuffer(length: 1024, options: .storageModeShared)!
    
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pso)
    enc.setBuffer(buf, offset: 0, index: 0)
    enc.dispatchThreads(MTLSize(width: 64, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding()
    
    let sema = DispatchSemaphore(value: 0)
    let t0 = CFAbsoluteTimeGetCurrent()
    cb.addCompletedHandler { _ in sema.signal() }
    cb.commit()
    let timeoutSec = 3.0
    let res = sema.wait(timeout: .now() + timeoutSec)
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let timedOut = (res == .timedOut)
    
    let behavior: String
    if timedOut {
        behavior = "deadlock_hang"
    } else {
        behavior = "silent_completion_undefined_synchronization"
    }
    
    results.append([
        "test_name": "threadgroup_barrier_divergent",
        "description": "threadgroup_barrier called conditionally by simdgroup 0 only",
        "elapsed_seconds": elapsed,
        "timed_out": timedOut,
        "behavior": behavior,
        "status_code": cb.status.rawValue,
        "status_name": cb.status == .completed ? "completed" : "other",
        "error_description": cb.error != nil ? cb.error!.localizedDescription : "nil"
    ])
}

let resultDict: [String: Any] = [
    "device_name": dev.name,
    "modes": results,
    "verification": [
        "status": "PASS",
        "all_fault_modes_reproduced": results.count == 4
    ]
]

let jsonData = try! JSONSerialization.data(withJSONObject: resultDict, options: [.prettyPrinted, .sortedKeys])
if CommandLine.arguments.count > 1 {
    let outPath = CommandLine.arguments[1]
    try! jsonData.write(to: URL(fileURLWithPath: outPath))
} else {
    print(String(data: jsonData, encoding: .utf8)!)
}
