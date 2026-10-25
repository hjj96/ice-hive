// ================================================================
//  FX — effects (owned by WP5 «Эффекты»): persistent floor stains
//  (multiply), flat floor sprites (light pools, splashes, telegraphs,
//  team rings; the procedural beacon / lift / revive progress rings),
//  camera-facing particles (additive / alpha with a noise edge) and
//  ribbons (sight glints, tracers, cryo beam, beacon beams).
//  Struct layouts mirror FX/MetalEffects.swift.
// ================================================================
#include "Common.h"

struct DecalInstance {
    float4x4 model;
    float4 color;
    float4 uv;       // xy atlas cell offset
};

struct SpriteInstance {
    float4 center;   // xyz, w = mode (0 textured, 1 ring indicator)
    float4 axisU;    // xyz half extent, w = indicator progress
    float4 axisV;    // xyz half extent (v = 0 at center + axisV), w = indicator alpha
    float4 color;    // rgb, w = opacity
};

struct ParticleInstance {
    float4 pos;      // xyz, w = size (m)
    float4 color;    // rgba
    float4 extra;    // x = seed
};

struct RibbonVertex {
    float4 pos;      // xyz, w = mode
    float4 color;    // rgb, w = intensity
    float4 uv;
};

// persistent floor stains: multiply blend over the lit floor (07-fx.js decalMat)
vertex QuadOut vs_decal(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Frame& F [[buffer(1)]],
                        const device DecalInstance* I [[buffer(2)]]) {
    DecalInstance d = I[iid];
    float2 q = quadCorner(vid) * 0.5;
    float3 w = (d.model * float4(q.x, 0.0, q.y, 1.0)).xyz;
    float2 uv = float2(q.x + 0.5, q.y + 0.5) * 0.5 + d.uv.xy;
    return quadOut(F, w, d.color, uv, float4(0.0));
}

fragment float4 fs_decal(QuadOut in [[stage_in]],
                         texture2d<float> atlas [[texture(0)]]) {
    float4 t = atlas.sample(clampSampler, in.uv);
    float3 c = mix(float3(1.0), t.rgb * in.color.rgb, t.a);
    return float4(encodeMultiply(c), 1.0);
}

// flat floor sprites: light pools / splashes / telegraphs / team rings (textured, additive) and the beacon / lift /
// revive progress rings (procedural, ringIndMat)
vertex QuadOut vs_sprite(uint vid [[vertex_id]], uint iid [[instance_id]],
                         constant Frame& F [[buffer(1)]],
                         const device SpriteInstance* I [[buffer(2)]]) {
    SpriteInstance s = I[iid];
    float2 q = quadCorner(vid);
    float3 w = s.center.xyz + s.axisU.xyz * q.x + s.axisV.xyz * q.y;
    return quadOut(F, w, s.color, q, float4(s.center.w, s.axisU.w, s.axisV.w, 0.0));
}

fragment float4 fs_sprite(QuadOut in [[stage_in]],
                          constant Frame& F [[buffer(1)]],
                          texture2d<float> map [[texture(0)]]) {
    float2 p = in.uv;   // -1 … 1 along u, v
    if (in.params.x < 0.5) {
        float4 t = map.sample(clampSampler, float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5));
        return float4(encodeColor(F, t.rgb * in.color.rgb, in.depth, false), t.a * in.color.a);
    }
    float prog = in.params.y, alpha = in.params.z, time = F.camPos.w;
    float r = length(p);
    float ang = fract(atan2(p.x, p.y) / 6.2831853 + 1.0);
    float ring = smoothstep(0.84, 0.865, r) * (1.0 - smoothstep(0.955, 0.98, r));
    float seg = step(0.3, fract(ang * 40.0));
    float pr = step(ang, prog);
    float inner = (1.0 - smoothstep(0.0, 0.86, r)) * 0.05 * (0.6 + 0.4 * sin(time * 3.0 - r * 8.0));
    float sweep = (1.0 - smoothstep(0.0, 0.86, abs(r - fract(time * 0.5) * 0.86))) * 0.12 * step(r, 0.86);
    float3 c = in.color.rgb * (ring * (pr * 1.7 + (1.0 - pr) * 0.35 * seg) + inner + sweep * (1.0 - step(0.999, prog)));
    return float4(encodeColor(F, c * alpha, in.depth, false), 1.0);
}

// particles: camera-facing quads with the web point-sprite size rule (size * pxScale / depth, 1…300 px)
vertex QuadOut vs_particle(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Frame& F [[buffer(1)]],
                           const device ParticleInstance* I [[buffer(2)]]) {
    ParticleInstance p = I[iid];
    float2 q = quadCorner(vid);
    float z = max(0.05, -(F.view * float4(p.pos.xyz, 1.0)).z);
    float px = clamp(p.pos.w * F.misc.x / z, 1.0, 300.0);
    float hs = 0.5 * px * z / F.misc.x;
    float3 w = p.pos.xyz + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    // the colour is constant over the quad: tone-map + encode it once here instead of per fragment (exact)
    float4 c = float4(encodeColor(F, p.color.rgb, 0.0, false), p.color.a);
    return quadOut(F, w, c, q * 0.5, float4(p.extra.x, 0.0, 0.0, 0.0));
}

static float particleMask(float2 q, float seed, texture2d<float> noise, float taps) {
    float n = noise.sample(repeatSampler, q * 0.31 + seed * float2(7.31, 3.17)).r;
    if (taps > 1.5) {
        n = n * 0.6 + noise.sample(repeatSampler, q * 0.69 - seed * float2(2.93, 5.71)).r * 0.4;
    }
    float d = length(q) * 2.0 * (0.75 + 0.5 * n);
    return 1.0 - smoothstep(0.0, 1.0, d);
}

fragment float4 fs_particle_add(QuadOut in [[stage_in]],
                                constant Frame& F [[buffer(1)]],
                                texture2d<float> noise [[texture(2)]]) {
    float a = particleMask(in.uv, in.params.x, noise, F.fx.x);
    a *= a;
    return float4(in.color.rgb, in.color.a * a);
}

fragment float4 fs_particle_alpha(QuadOut in [[stage_in]],
                                  constant Frame& F [[buffer(1)]],
                                  texture2d<float> noise [[texture(2)]]) {
    float a = particleMask(in.uv, in.params.x, noise, F.fx.x);
    a = smoothstep(0.0, 0.6, a);
    return float4(in.color.rgb, in.color.a * a);
}

// ribbons: dashed line (mode 0, unused since the laser sights went), tracers (flat), cryo beam (streak noise), fade along u (sight glints, beacon beams)
vertex QuadOut vs_ribbon(uint vid [[vertex_id]],
                         constant Frame& F [[buffer(1)]],
                         const device RibbonVertex* V [[buffer(2)]]) {
    RibbonVertex r = V[vid];
    return quadOut(F, r.pos.xyz, r.color, r.uv.xy, float4(r.pos.w, 0.0, 0.0, 0.0));
}

fragment float4 fs_ribbon(QuadOut in [[stage_in]],
                          constant Frame& F [[buffer(1)]],
                          texture2d<float> dash [[texture(0)]],
                          texture2d<float> streak [[texture(1)]]) {
    float mode = in.params.x;
    float time = F.camPos.w;
    float2 uv = in.uv;
    float3 c;
    if (mode < 0.5) {
        float across = 1.0 - abs(uv.y * 2.0 - 1.0);
        across *= across;
        float d = dash.sample(repeatSampler, float2(uv.x * 1.6 - time * 2.5, 0.5)).r;
        c = in.color.rgb * across * (0.45 + 0.55 * d);
    } else if (mode < 1.5) {
        c = in.color.rgb;
    } else if (mode < 2.5) {
        float across = 1.0 - abs(uv.y * 2.0 - 1.0);
        float n = streak.sample(repeatSampler, float2(uv.x * 0.9 - time * 3.2, uv.y)).r
                + streak.sample(repeatSampler, float2(uv.x * 0.5 - time * 1.7, uv.y * 0.7 + 0.2)).r;
        float core = pow(across, 3.0) * 1.4;
        float fade = smoothstep(0.0, 0.08, uv.x) * (1.0 - smoothstep(0.75, 1.0, uv.x));
        c = float3(0.45, 0.85, 1.25) * (across * n * 0.9 + core) * fade * in.color.w;
    } else {
        float k = 1.0 - uv.x;
        float across = 1.0 - abs(uv.y * 2.0 - 1.0);
        c = in.color.rgb * in.color.w * k * k * (0.35 + 0.65 * across);
    }
    return float4(encodeColor(F, c, in.depth, false), 1.0);
}
