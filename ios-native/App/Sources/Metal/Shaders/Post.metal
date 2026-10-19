// ================================================================
//  POST — the HDR / post slot and the composite (owned by WP1 «Кадр»).
//  Input: sceneHDR, the multisample-resolved world image (RG11B10Float,
//  linear radiance, allocated once at the maximum world scale; this
//  frame's dynamic-resolution viewport is its top-left `scene.xy` of
//  the uv range).
//    bloom      dual-Kawase: prefilter (13-tap down with a Karis
//               average against fireflies + soft-knee threshold) into
//               the first level (High: ½ of the allocation, Efficient:
//               ¼), 4-tap downs, then 8-tap tent ups added onto each
//               level on the way back (additive blend)
//    composite  the first draw of the final pass on the drawable (the
//               HUD follows in the same encoder): sharpened upscale of
//               the viewport, heat distortion (High), + bloom,
//               × scripted exposure, ACES (three.js fit), sRGB, 32³ LUT
//               grade, brightness (gamma), vignette, grain,
//               interleaved-gradient-noise dither
//  PostParams mirrors PostUniforms in Frame/PostChain.swift.
// ================================================================
#include "Common.h"

// tier variant of the composite (MTLFunctionConstantValues, index 0): High adds heat distortion
constant bool kPostHigh [[function_constant(0)]];

struct PostParams {
    float4 scene;    // xy = uv extent of the viewport in sceneHDR, zw = 1 / allocation size (texel)
    float4 bloom;    // x threshold, y knee, z intensity, w firefly clamp (max luminance into the bloom)
    float4 grade;    // x exposure (linear multiplier), y vignette, z grain, w brightness gamma (1 = off)
    float4 misc;     // x time, y frame index, z sharpen, w distortion strength
    float4 pass;     // bloom passes: xy = texel of the source level (uv); prefilter: zw = texel of the destination level;
                     // up: z = weight of the coarser level added (< 1: a tight bloom, the wide halos fall off)
};

struct PostOut {
    float4 position [[position]];
    float2 uv;
};

/// Full-screen triangle; uv (0, 0) at the top-left.
vertex PostOut vs_post(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    PostOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

constexpr sampler postLinear(filter::linear, address::clamp_to_edge);

static float lumaOf(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

/// The scene viewport at screen uv, bilinear, clamped half a texel inside the viewport.
static float3 sceneTap(texture2d<float> scene, constant PostParams& P, float2 uv) {
    float2 q = clamp(uv * P.scene.xy, P.scene.zw * 0.5, P.scene.xy - P.scene.zw * 0.5);
    return scene.sample(postLinear, q).rgb;
}

/// Prefilter: 13-tap downsample (Jimenez 2014) of the scene viewport into the first bloom level (taps at ±½ and ±1
/// destination texel), Karis-weighted per 2 × 2 group so a lone bright sub-pixel cannot flicker the bloom, × exposure,
/// a firefly clamp, then the soft-knee threshold.
fragment float4 fs_bloom_prefilter(PostOut in [[stage_in]],
                                   constant PostParams& P [[buffer(0)]],
                                   texture2d<float> scene [[texture(0)]]) {
    float2 o = P.pass.zw * 0.5;
    float2 uv = in.uv;
    float3 a = sceneTap(scene, P, uv + float2(-2.0, -2.0) * o), b = sceneTap(scene, P, uv + float2(0.0, -2.0) * o);
    float3 c = sceneTap(scene, P, uv + float2(2.0, -2.0) * o);
    float3 d = sceneTap(scene, P, uv + float2(-1.0, -1.0) * o), e = sceneTap(scene, P, uv + float2(1.0, -1.0) * o);
    float3 f = sceneTap(scene, P, uv + float2(-2.0, 0.0) * o), g = sceneTap(scene, P, uv), h = sceneTap(scene, P, uv + float2(2.0, 0.0) * o);
    float3 i = sceneTap(scene, P, uv + float2(-1.0, 1.0) * o), j = sceneTap(scene, P, uv + float2(1.0, 1.0) * o);
    float3 k = sceneTap(scene, P, uv + float2(-2.0, 2.0) * o), l = sceneTap(scene, P, uv + float2(0.0, 2.0) * o);
    float3 m = sceneTap(scene, P, uv + float2(2.0, 2.0) * o);
    float exposure = P.grade.x;
    // Karis average: each group weighted by 1 / (1 + luma)
    float3 g0 = (d + e + i + j) * 0.25, g1 = (a + b + f + g) * 0.25, g2 = (b + c + g + h) * 0.25;
    float3 g3 = (f + g + k + l) * 0.25, g4 = (g + h + l + m) * 0.25;
    float w0 = 0.5 / (1.0 + lumaOf(g0) * exposure), w1 = 0.125 / (1.0 + lumaOf(g1) * exposure), w2 = 0.125 / (1.0 + lumaOf(g2) * exposure);
    float w3 = 0.125 / (1.0 + lumaOf(g3) * exposure), w4 = 0.125 / (1.0 + lumaOf(g4) * exposure);
    float3 col = (g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3 + g4 * w4) / (w0 + w1 + w2 + w3 + w4) * exposure;
    // firefly clamp, then the soft-knee threshold (Unity / Karis curve)
    col *= min(1.0, P.bloom.w / max(lumaOf(col), 1e-4));
    float br = max(col.r, max(col.g, col.b));
    float th = P.bloom.x, knee = max(P.bloom.y, 1e-4);
    float soft = clamp(br - th + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float contrib = max(soft, br - th) / max(br, 1e-4);
    return float4(col * contrib, 1.0);
}

/// Dual-Kawase down: centre × 4 + four half-texel corners, / 8.
fragment float4 fs_bloom_down(PostOut in [[stage_in]],
                              constant PostParams& P [[buffer(0)]],
                              texture2d<float> src [[texture(0)]]) {
    float2 t = P.pass.xy * 0.5;
    float2 uv = in.uv;
    float3 c = src.sample(postLinear, uv).rgb * 4.0;
    c += src.sample(postLinear, uv + float2(-t.x, -t.y)).rgb;
    c += src.sample(postLinear, uv + float2(t.x, -t.y)).rgb;
    c += src.sample(postLinear, uv + float2(-t.x, t.y)).rgb;
    c += src.sample(postLinear, uv + float2(t.x, t.y)).rgb;
    return float4(c * 0.125, 1.0);
}

/// Dual-Kawase up (tent): four edge taps + four diagonal taps × 2, / 12, × the coarse-level weight; blended
/// additively onto the level below.
fragment float4 fs_bloom_up(PostOut in [[stage_in]],
                            constant PostParams& P [[buffer(0)]],
                            texture2d<float> src [[texture(0)]]) {
    float2 t = P.pass.xy * 0.5;
    float2 uv = in.uv;
    float3 c = src.sample(postLinear, uv + float2(-2.0 * t.x, 0.0)).rgb;
    c += src.sample(postLinear, uv + float2(2.0 * t.x, 0.0)).rgb;
    c += src.sample(postLinear, uv + float2(0.0, -2.0 * t.y)).rgb;
    c += src.sample(postLinear, uv + float2(0.0, 2.0 * t.y)).rgb;
    c += src.sample(postLinear, uv + float2(-t.x, -t.y)).rgb * 2.0;
    c += src.sample(postLinear, uv + float2(t.x, -t.y)).rgb * 2.0;
    c += src.sample(postLinear, uv + float2(-t.x, t.y)).rgb * 2.0;
    c += src.sample(postLinear, uv + float2(t.x, t.y)).rgb * 2.0;
    return float4(c * (P.pass.z / 12.0), 1.0);
}

/// Interleaved gradient noise (Jimenez 2014) in [0, 1): a cheap blue-ish noise per pixel, shifted every frame.
static float ign(float2 px, float frame) {
    float2 p = px + frame * float2(5.588238, 5.588238);
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

fragment float4 fs_composite(PostOut in [[stage_in]],
                             constant PostParams& P [[buffer(0)]],
                             texture2d<float> scene [[texture(0)]],
                             texture2d<float> bloom [[texture(1)]],
                             texture3d<float> lut [[texture(2)]],
                             texture2d<float> distortion [[texture(3)]]) {
    float2 uv = in.uv;
    if (kPostHigh) {
        // heat distortion (RG8, 0.5 = none), ¼ res, drawn by the effects
        float2 dv = distortion.sample(postLinear, uv).rg - 0.5;
        uv += dv * P.misc.w;
    }
    // sharpened upscale: the bilinear tap plus a 4-neighbour unsharp mask in scene texels, clamped to the local range
    float3 c = sceneTap(scene, P, uv);
    float sharpen = P.misc.z;
    if (sharpen > 0.0) {
        float2 t = P.scene.zw / P.scene.xy;   // one scene texel in screen uv
        float3 n = sceneTap(scene, P, uv + float2(0.0, -t.y)), s = sceneTap(scene, P, uv + float2(0.0, t.y));
        float3 e = sceneTap(scene, P, uv + float2(t.x, 0.0)), w = sceneTap(scene, P, uv + float2(-t.x, 0.0));
        float3 lo = min(c, min(min(n, s), min(e, w))), hi = max(c, max(max(n, s), max(e, w)));
        c = clamp(c + (c * 4.0 - n - s - e - w) * (0.25 * sharpen), lo, hi);
    }
    c += bloom.sample(postLinear, uv).rgb * P.bloom.z;
    c *= P.grade.x;
    float3 d = linearToSRGB(acesFilmic(c));
    // 32³ grade LUT on the display-referred value (texel centres)
    d = lut.sample(postLinear, saturate(d) * (31.0 / 32.0) + 0.5 / 32.0).rgb;
    // brightness option (gamma on the graded image: lifts the darks for dim screens / outdoors)
    d = pow(max(d, float3(0.0)), float3(1.0 / P.grade.w));
    // vignette: a light corner fall-off
    float2 v = in.uv * 2.0 - 1.0;
    d *= 1.0 - P.grade.y * smoothstep(0.55, 1.45, dot(v, v));
    // film grain: light, mostly in the mid-tones, then a ±½ LSB triangular dither against 8-bit / RG11B10 banding
    float2 px = in.position.xy;
    float n1 = ign(px, P.misc.y), n2 = ign(px + float2(17.0, 59.0), P.misc.y + 1.0);
    float l = lumaOf(d);
    d += (n1 - 0.5) * P.grade.z * (l * (1.0 - l) * 4.0);
    d += (n1 + n2 - 1.0) * (1.0 / 255.0);
    return float4(saturate(d), 1.0);
}
