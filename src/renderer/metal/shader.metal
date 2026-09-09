#include <metal_stdlib>

using namespace metal;

struct RectInput {
    float4  position    [[attribute(0)]];
    float4  color_0     [[attribute(1)]];
    float4  color_1     [[attribute(2)]];
    float4  color_2     [[attribute(3)]];
    float4  color_3     [[attribute(4)]];
    float4  corner_rads [[attribute(5)]];
    float   border      [[attribute(6)]];
};

struct RectOutput {
    float4  position    [[position]];
    float4  color;
    float2  sdf_pos;
    float2  half_size   [[flat]];
    float   radius      [[flat]];
    float   border      [[flat]];
};

struct Uniforms {
  float2 viewport_size;
};

float rect_sdf(float2 pos, float2 base, float rad)
{
  return length(max(abs(pos) - base + rad, 0.0f)) - rad;
}

vertex RectOutput rectVertexShader(
    uint v_id [[vertex_id]],
    RectInput in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    float4x2 vertices = float4x2(float2(1.0f, 1.0f), float2(1.0f, -1.0f), float2(-1.0f, 1.0f), float2(-1.0f, -1.0f));

    float2 half_size = (in.position.zw - in.position.xy) / 2.0f;
    float2 center    = (in.position.zw + in.position.xy) / 2.0f;
    float2 position  = vertices[v_id] * half_size + center;

    float4x4 colors = float4x4(in.color_0, in.color_1, in.color_2, in.color_3);

    RectOutput out;
    out.position = float4(
        2.0f * position.x / uniforms.viewport_size.x - 1.0f,
        2.0f * (1.0f - position.y / uniforms.viewport_size.y) - 1.0f,
        0.0f,
        1.0f
    );
    out.border = in.border;
    out.radius = in.corner_rads[v_id];
    out.color = colors[v_id];
    out.half_size = half_size;
    out.sdf_pos = vertices[v_id] * half_size;
    return out;
}

fragment float4 rectFragmentShader(RectOutput in [[stage_in]]) {
    float border_sdf_t = 1.0f;
    if(in.border > 0.0f) {
        float border_sdf_s = rect_sdf(in.sdf_pos, in.half_size - float2(2.0f, 2.0f) - in.border, max(in.radius - in.border, 0.0f));
        border_sdf_t = smoothstep(0, 2.0f, in.border);
    }

    if(border_sdf_t < 0.001f) {
        discard_fragment();
    }

    float corner_sdf_t = 1.0f;

    if(in.radius > 0.0f) {
        float corner_sdf = rect_sdf(in.sdf_pos, in.half_size - float2(2.0f, 2.0f) , in.radius);
        corner_sdf_t = 1.0f - smoothstep(0.0f, 2.0f, corner_sdf);
    }

    float4 color = in.color;
    color.a *= border_sdf_t;
    color.a *=  corner_sdf_t;
    color.rgb *= color.a;

    return color;
}
