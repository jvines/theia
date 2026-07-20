#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float    vmin;
    float    vmax;
    int      stretchType;  // 0=linear, 1=log, 2=sqrt, 3=asinh, 4=histogramEq, 5=power
    int      cdfLength;
    float    stretchParam; // exponent for power stretch
    float    _pad;
};

struct VertexIn {
    float2 position;
    float2 uv;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertexMain(
    uint vid [[vertex_id]],
    constant VertexIn* vertices [[buffer(0)]],
    constant Uniforms& u       [[buffer(1)]]
) {
    VertexIn v = vertices[vid];
    VertexOut o;
    o.position = u.mvp * float4(v.position, 0.0, 1.0);
    o.uv = v.uv;
    return o;
}

fragment float4 fragmentMain(
    VertexOut in           [[stage_in]],
    texture2d<float> tex   [[texture(0)]],
    texture2d<float> lut   [[texture(1)]],
    sampler s              [[sampler(0)]],
    sampler lutS           [[sampler(1)]],
    constant Uniforms& u  [[buffer(1)]],
    constant float* cdf   [[buffer(2)]]
) {
    float v = tex.sample(s, in.uv).r;
    if (isnan(v)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float range = max(u.vmax - u.vmin, 1e-6);
    float x = clamp((v - u.vmin) / range, 0.0, 1.0);

    float n;
    if (u.stretchType == 0) {
        n = x;
    } else if (u.stretchType == 1) {
        n = log10(1.0 + 9.0 * x);
    } else if (u.stretchType == 2) {
        n = sqrt(x);
    } else if (u.stretchType == 3) {
        n = asinh(10.0 * x) / asinh(10.0);
    } else if (u.stretchType == 4 && u.cdfLength > 0) {
        int idx = clamp(int(x * float(u.cdfLength - 1)), 0, u.cdfLength - 1);
        n = cdf[idx];
    } else if (u.stretchType == 5) {
        float p = max(u.stretchParam, 1e-6);
        n = pow(x, p);
    } else {
        n = x;
    }

    float3 colour = lut.sample(lutS, float2(n, 0.5)).rgb;
    return float4(colour, 1.0);
}
