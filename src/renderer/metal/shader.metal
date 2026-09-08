#include <metal_stdlib>

using namespace metal;

struct RectInput {
    float4 position [[attribute(0)]];
    float4 color_0  [[attribute(1)]];
    float4 color_1  [[attribute(2)]];
    float4 color_2  [[attribute(3)]];
    float4 color_3  [[attribute(4)]];
};

struct RectOutput {
    float4 position [[position]];
    float4 color;
    float2 sdf_pos;
    float2 half_size;
};

struct Uniforms {
  float2 viewport_size;
};

float rect_sdf(float2 pos, float2 base, float rad)
{
  return length(max(abs(pos) - base + rad, 0.0)) - rad;
}

float linear_from_srgb(float x)
{
  return x < 0.0404482362771082 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}

float4 linear_from_srgba(float4 v)
{
 float4 result = float4(linear_from_srgb(v.x),
                     linear_from_srgb(v.y),
                     linear_from_srgb(v.z),
                     v.w);
  return result;
}


vertex RectOutput rectVertexShader(
    uint v_id [[vertex_id]],
    RectInput in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    float4x2 vertices = float4x2(float2(-1.0f, -1.0f), float2(-1.0f, 1.0f), float2(1.0f, -1.0f), float2(1.0f, 1.0f));

    float2 half_size = (in.position.zw - in.position.xy) / 2.0;
    float2 center    = (in.position.zw + in.position.xy) / 2.0;
    float2 position  = vertices[v_id] * half_size + center;

    float4x4 colors = float4x4(in.color_0, in.color_1, in.color_2, in.color_3);

    float4x2 corner_vertices = float4x2(float2(1.0f, 1.0f), float2(1.0f, -1.0f), float2(-1.0f, 1.0f), float2(-1.0f, -1.0f));

    RectOutput out;
    out.position = float4(
        2.0f * position.x / uniforms.viewport_size.x - 1.0f,
        2.0f * (1.0f - position.y / uniforms.viewport_size.y) - 1.0f,
        0.0f,
        1.0f
    );
    out.color = colors[v_id];
    out.half_size = half_size;
    out.sdf_pos = corner_vertices[v_id] * half_size;
    return out;
}

fragment float4 rectFragmentShader(RectOutput in [[stage_in]]) {
    float corner_sdf_t = 1;
    float corner_sdf = rect_sdf(in.sdf_pos, in.half_size - float2(2, 2), 26);
    corner_sdf_t = 1-smoothstep(0, 2, corner_sdf);

    float4 color = linear_from_srgba(in.color);
    color.a *=  corner_sdf_t;
    color.rgb *= color.a;

    return color;
}
