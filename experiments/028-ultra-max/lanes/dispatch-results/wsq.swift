import Metal; let d = MTLCreateSystemDefaultDevice()!; print(d.name, d.recommendedMaxWorkingSetSize, d.maxBufferLength)
