// df64_convert.metal: in-place bulk conversion between IEEE-754 binary64 and df64 (needs df64.metal).
// A buffer of n doubles is a buffer of n df64 pairs: both are 8 bytes, so arrays keep their size
// and every component keeps its byte offset. A host that stores df64 in device memory runs
// df64FromIEEE after writing doubles and df64ToIEEE before reading them back.

kernel void df64FromIEEE(device uint2* data [[buffer(0)]], constant uint& count [[buffer(1)]],
        uint index [[thread_position_in_grid]]) {
    if (index >= count)
        return;
    df64 v = df64_from_ieee(data[index]);
    data[index] = as_type<uint2>(float2(v.hi, v.lo));
}

kernel void df64ToIEEE(device uint2* data [[buffer(0)]], constant uint& count [[buffer(1)]],
        uint index [[thread_position_in_grid]]) {
    if (index >= count)
        return;
    float2 v = as_type<float2>(data[index]);
    data[index] = df64_to_ieee(df64(v.x, v.y));
}
