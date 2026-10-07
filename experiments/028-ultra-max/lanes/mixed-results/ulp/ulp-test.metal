#include <metal_stdlib>
using namespace metal;

inline float erfc_oc(float x) {
    float t = fabs(x);
    float u = 1.0f/(1.0f+0.47f*t);
    float poly = ((((((0.0966678f*u-0.4607003f)*u+0.6896449f)*u-0.21611532f)*u+0.3931878f)*u+0.22740916f)*u+0.2701903f)*u-0.00028434425f;
    float result = (t > 9.0f ? 0.0f : poly*exp(-t*t));
    return (x < 0.0f ? 2.0f-result : result);
}

// The Abramowitz and Stegun erfc that coulombLennardJones.cc uses for PME direct space, with the Metal RECIP and EXP.
inline float erfc_as(float r) {
    float t = fast::divide(1.0f, 1.0f+0.3275911f*r);
    return (0.254829592f+(-0.284496736f+(1.421413741f+(-1.453152027f+1.061405429f*t)*t)*t)*t)*t*fast::exp(-r*r);
}

inline float two_sum_err_safe(float a, float b) {
#pragma METAL fp math_mode(safe)
    float s = a+b;
    float bb = s-a;
    return (a-(s-bb))+(b-bb);
}

inline float two_sum_err(float a, float b) {
    float s = a+b;
    float bb = s-a;
    return (a-(s-bb))+(b-bb);
}

kernel void ops(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]], device float* out [[buffer(2)]],
                constant uint& n [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= n)
        return;
    float x = a[i], y = b[i];
    out[0*n+i] = x/y;
    out[1*n+i] = 1.0f/precise::sqrt(x);
    out[2*n+i] = precise::sqrt(x);
    out[3*n+i] = exp(y);
    out[4*n+i] = erfc_oc(y);
    out[5*n+i] = two_sum_err_safe(x, y);
    out[6*n+i] = two_sum_err(x, y);
    out[7*n+i] = fast::divide(1.0f, x);
    out[8*n+i] = precise::divide(x, y);
    out[9*n+i] = 1.0f/x;
    out[10*n+i] = erfc_as(fabs(y)*0.35f);
}
