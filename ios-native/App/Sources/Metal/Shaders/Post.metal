// ================================================================
//  POST — the HDR / post slot and the composite (owned by WP1 «Кадр»).
//  The composite is the first draw of the final pass on the drawable:
//  one full-screen triangle samples the world image (rendered at the
//  world scale, 2x by default) into the drawable at the screen's
//  native scale, bilinear like the compositor scaled the old 2x
//  MTKView layer; the HUD (SKRenderer) is drawn on top in the same
//  pass.
// ================================================================
#include "Common.h"

struct CompositeOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeOut vs_composite(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    CompositeOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 fs_composite(CompositeOut in [[stage_in]],
                             texture2d<float> world [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return float4(world.sample(s, in.uv).rgb, 1.0);
}
