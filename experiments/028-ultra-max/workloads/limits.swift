import Metal
let d = MTLCreateSystemDefaultDevice()!
print("Metal \(d.name) maxBufferLength \(d.maxBufferLength) (\(Double(d.maxBufferLength)/1073741824) GiB) recommendedMaxWorkingSetSize \(d.recommendedMaxWorkingSetSize) (\(Double(d.recommendedMaxWorkingSetSize)/1073741824) GiB)")
