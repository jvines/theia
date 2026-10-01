#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float vmin;
    float vmax;
    int stretchType;   // 0=linear, 1=log, 2=sqrt, 3=asinh, 4=histogramEq, 5=power, 6=sinh
    int cdfLength;
    float stretchParam;
    float imageX0;
    float imageY0;
    float deviceStep;
    int imageWidth;
    int imageHeight;
    int lutLength;
    int usesViewportRaster;
};

struct VertexIn {
    float2 position;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertexMain(
    uint vid [[vertex_id]],
    constant VertexIn* vertices [[buffer(0)]]
) {
    VertexIn v = vertices[vid];
    VertexOut o;
    o.position = float4(v.position * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 fragmentMain(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant Uniforms& u [[buffer(1)]],
    constant float* cdf [[buffer(2)]],
    constant uchar4* lut [[buffer(3)]]
) {
    if (u.usesViewportRaster != 0) {
        return tex.read(uint2(in.position.xy));
    }

    // Position is the exact device-pixel centre; the CPU uses the integer
    // column/row with the same fused multiply-add and starting coordinates.
    float imageX = fma(in.position.x - 0.5, u.deviceStep, u.imageX0);
    float imageY = fma(-(in.position.y - 0.5), u.deviceStep, u.imageY0);
    if (!isfinite(imageX) || !isfinite(imageY) ||
        imageX < -0.5 || imageY < -0.5 ||
        imageX >= float(u.imageWidth) - 0.5 ||
        imageY >= float(u.imageHeight) - 0.5) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    uint2 pixel = uint2(floor(float2(imageX, imageY) + 0.5));
    float v = tex.read(pixel).r;
    if (isnan(v)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    // Keep this Float32 stretch in the same order as RasterStretch.apply.
    float clamped = clamp(v, u.vmin, u.vmax);
    float range = max(u.vmax - u.vmin, 1e-6);
    float x = (clamped - u.vmin) / range;
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
        int idx = int(floor(x * float(u.cdfLength - 1)));
        n = cdf[clamp(idx, 0, u.cdfLength - 1)];
    } else if (u.stretchType == 5) {
        n = pow(x, max(u.stretchParam, 1e-6));
    } else if (u.stretchType == 6) {
        n = sinh(3.0 * x) / sinh(3.0);
    } else {
        n = x;
    }
    int index = int(floor(clamp(n * float(u.lutLength - 1) + 0.5,
                                0.0, float(u.lutLength - 1))));
    return float4(lut[index]) / 255.0;
}
