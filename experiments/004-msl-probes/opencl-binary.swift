// What does Apple's OpenCL hand back from CL_PROGRAM_BINARIES on Apple silicon? Writes the blob to /tmp/opencl-binary.bin.
import OpenCL
import Foundation

let source = "__kernel void saxpy(__global float* x, __global const float* y, float a, int n) { int i = get_global_id(0); if (i < n) x[i] = a * x[i] + y[i]; }"
var device: cl_device_id? = nil
clGetDeviceIDs(nil, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &device, nil)
var err: cl_int = 0
let context = clCreateContext(nil, 1, &device, nil, nil, &err)
var cString: UnsafePointer<CChar>? = (source as NSString).utf8String
let program = clCreateProgramWithSource(context, 1, &cString, nil, &err)
let options = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
err = clBuildProgram(program, 1, &device, options, nil, nil)
var size = 0
clGetProgramInfo(program, cl_program_info(CL_PROGRAM_BINARY_SIZES), MemoryLayout<Int>.size, &size, nil)
var blob = [UInt8](repeating: 0, count: size)
blob.withUnsafeMutableBufferPointer { pointer in
    var address: UnsafeMutablePointer<UInt8>? = pointer.baseAddress
    clGetProgramInfo(program, cl_program_info(CL_PROGRAM_BINARIES), MemoryLayout<UnsafeMutablePointer<UInt8>?>.size, &address, nil)
}
try! Data(blob).write(to: URL(fileURLWithPath: "/tmp/opencl-binary.bin"))
let head = blob.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
print("build status \(err), binary \(size) bytes, first bytes: \(head)")
