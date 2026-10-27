// ================================================================
//  FX — the effects' surfaces (owned by WP5 «Эффекты»; the particles
//  are Particles.metal):
//    decals     stains on the deck. High: forward WET decals — lit by
//               the full light model (WP2 shadeLit: flashlights, grid
//               lights, probe), fresh roughness 0.08 drying to 0.62 over
//               45 s, relief from the atlas's thickness, pink-white
//               flecks of the pores that fade in seconds; acid (glossy,
//               a faint green glow), scorch (dry black, embers fading),
//               frost (pale rime with glints) and gore variants; alpha
//               blended. Efficient: the multiply stains of the web.
//    floor fx   additive light on the deck: soft glow pools, shock rings
//               of blasts, ground fire, acid glow, frost bursts.
//    telegraphs MAX-blended thin rims (overlaps never sum to white):
//               warning rings, acid targets (a soft pool, a rim and the
//               shrinking countdown ring), brute charge lanes, shock
//               rings of abilities.
//    beams      camera-facing ribbons: tracers (short HDR bolts with a
//               white-hot head), muzzle glints, the cryo beam, beacon
//               columns.
//    heat       the ¼-res heat distortion (High): offsets around 0.5 in
//               RG8, alpha blended (signed), read by the composite.
//  Struct layouts mirror FX/Decals.swift, FX/MetalEffects.swift and
//  FX/Ribbons.swift.
// ================================================================
#include "Lighting.h"

// ---------------------------------------------------------------- decals
struct DecalInstance {
    float4 center;   // xyz on the deck, w = size (m, edge of the quad)
    float4 axis;     // x cos, y sin of the roll, z deck slope along z (dy / dz), w atlas cell (0…7)
    float4 color;    // rgb stain tint (the multiply factor; the wet albedo follows from it), w = birth time (s, effects clock)
    float4 params;   // x kind (0 ichor, 1 acid, 2 scorch, 3 frost, 4 gore), y opacity, z flecks 0…1, w unused
};

struct DecalOut {
    float4 position [[position]];
    float3 world;
    float2 uv;
    float2 local;    // -0.5 … 0.5 in the decal's own axes
    float4 color;
    float4 params;
    float4 axis;
    float depth;
};

vertex DecalOut vs_decal(uint vid [[vertex_id]], uint iid [[instance_id]],
                         constant Frame& F [[buffer(1)]],
                         const device DecalInstance* I [[buffer(2)]]) {
    DecalInstance d = I[iid];
    float2 q = quadCorner(vid) * 0.5;
    float s = d.center.w, c = d.axis.x, sn = d.axis.y;
    float dx = (c * q.x + sn * q.y) * s, dz = (-sn * q.x + c * q.y) * s;
    float3 w = float3(d.center.x + dx, d.center.y + d.axis.z * dz, d.center.z + dz);
    float cell = d.axis.w;
    float2 origin = float2(fmod(cell, 4.0) * 0.25, floor(cell / 4.0) * 0.5);
    DecalOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.world = w;
    o.uv = origin + clamp(q + 0.5, 0.01, 0.99) * float2(0.25, 0.5);
    o.local = q;
    o.color = d.color;
    o.params = d.params;
    o.axis = d.axis;
    o.depth = -(F.view * float4(w, 1.0)).z;
    return o;
}

/// Efficient: the stain multiplies the lit deck (coverage in r, variation in a).
fragment float4 fs_decal(DecalOut in [[stage_in]],
                         texture2d<float> atlas [[texture(0)]]) {
    float4 t = atlas.sample(clampSampler, in.uv);
    float cov = t.r * in.params.y;
    float3 tint = in.color.rgb * (0.8 + 0.4 * t.a);
    int kind = int(in.params.x + 0.5);
    if (kind == 0 || kind == 4 || kind == 1) {
        // ichor / gore / acid: a dark wet stain of the hue (a saturated multiply read as red paint / green lily pads)
        float l = dot(tint, float3(0.3, 0.55, 0.15));
        tint = mix(float3(l), tint, kind == 1 ? 0.55 : 0.7) * 0.6;
    }
    float3 c = mix(float3(1.0), tint, saturate(cov));
    return float4(encodeMultiply(c), 1.0);
}

/// High: a wet stain lit like the deck, alpha blended over it.
fragment float4 fs_decal_wet(DecalOut in [[stage_in]],
                             constant Frame& F [[buffer(1)]],
                             constant float& now [[buffer(7)]],
                             texture2d<float> atlas [[texture(0)]],
                             LIGHTING_PARAMS) {
    float4 t = atlas.sample(clampSampler, in.uv);
    float cov = saturate(t.r * in.params.y);
    int kind = int(in.params.x + 0.5);
    float age = max(0.0, now - in.color.w);   // the effects' clock (Decals.clock)
    // relief: the thickness gradient in the decal's own axes, turned into world xz
    float2 du = float2(1.0 / 1024.0, 0.0), dv = float2(0.0, 1.0 / 512.0);
    float hx = atlas.sample(clampSampler, in.uv + du).g - atlas.sample(clampSampler, in.uv - du).g;
    float hz = atlas.sample(clampSampler, in.uv + dv).g - atlas.sample(clampSampler, in.uv - dv).g;
    float c = in.axis.x, sn = in.axis.y;
    float2 gl = float2(hx, hz) * 6.0;
    float2 gw = float2(c * gl.x - sn * gl.y, sn * gl.x + c * gl.y);
    float3 N = normalize(float3(-gw.x, 1.0, -gw.y));
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 tint = in.color.rgb;
    float3 albedo;
    float rough;
    float3 emit = float3(0.0);
    float alpha = cov;
    if (kind == 1) {
        // acid: glossy, stays wet longer, a faint sickly glow from the thick middle
        float wet = 1.0 - smoothstep(0.0, 70.0, age);
        albedo = mix(float3(dot(tint, float3(0.3, 0.55, 0.15))), tint, 0.6) * 0.1;
        rough = mix(0.5, 0.08, wet);
        emit = float3(0.08, 0.35, 0.02) * (t.g * t.g) * (0.2 + 0.8 * exp(-age / 5.0)) * 0.14;
    } else if (kind == 2) {
        // scorch: dry soot, embers in it cool over a few seconds
        albedo = float3(0.018, 0.016, 0.015);
        rough = 0.9;
        alpha = cov * 0.92;
        emit = float3(1.0, 0.32, 0.06) * t.b * exp(-age / 1.6) * 2.5;
    } else if (kind == 3) {
        // frost: pale rime, glints where the crystals face the light
        albedo = float3(0.42, 0.52, 0.62);
        rough = t.b > 0.6 ? 0.12 : 0.55;
        alpha = cov * (1.0 - smoothstep(25.0, 45.0, age) * 0.6);
    } else {
        // ichor / gore: dark and wet, dries over 45 s (roughness 0.08 → 0.62), the pores' flecks fade in seconds
        float wet = 1.0 - smoothstep(0.0, 45.0, age);
        albedo = tint * mix(0.38, 0.22, wet);
        rough = mix(0.62, 0.08, wet);
        alpha = cov * (0.8 + 0.2 * wet);
        emit = float3(1.0, 0.36, 0.62) * t.b * in.params.z * exp(-age / 2.5) * 1.6;
    }
    LitSurface s;
    s.P = in.world;
    s.N = N;
    s.V = V;
    s.albedo = albedo;
    s.rough = rough;
    s.metal = 0.0;
    s.coat = 0.0;
    s.coatRough = 0.0;
    s.ao = 1.0;
    s.shadow = 1.0;
    float3 lit = shadeLit(LIGHTING_ARGS, s, true) + emit;
    return float4(heightFog(F, LB, lit, in.world, in.depth), alpha);
}

// ---------------------------------------------------------------- floor fx and telegraphs
struct FloorFx {
    float4 center;   // xyz on the deck, w = radius (m; lanes: half width)
    float4 color;    // rgb HDR, w = opacity
    float4 params;   // x mode, y progress 0…1, z thickness (fraction of the radius), w seed / blink
    float4 axis;     // xy unit direction in xz (lanes), z half length (lanes), w slope along the direction (dy / m)
};

struct FloorOut {
    float4 position [[position]];
    float4 color;
    float4 params;
    float2 q;        // -1 … 1 over the disc / lane (x across a lane, y along it)
    float aspect;    // lane: half length / half width
    float depth;
};

#define FM_GLOW 0
#define FM_SHOCK 1
#define FM_FIRE 2
#define FM_ACID 3
#define FM_FROST 4
#define FM_RING 10
#define FM_FILL 11
#define FM_LANE 12
#define FM_WAVE 13

vertex FloorOut vs_floorfx(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Frame& F [[buffer(1)]],
                           const device FloorFx* I [[buffer(2)]]) {
    FloorFx f = I[iid];
    float2 q = quadCorner(vid);
    int mode = int(f.params.x + 0.5);
    float3 w;
    float aspect = 1.0;
    if (mode == FM_LANE) {
        float2 d = f.axis.xy;
        float2 n = float2(-d.y, d.x);
        float hl = f.axis.z, hw = f.center.w;
        float2 p = f.center.xz + n * (q.x * hw) + d * (q.y * hl);
        w = float3(p.x, f.center.y + f.axis.w * q.y * hl, p.y);
        aspect = hl / max(hw, 1e-3);
    } else {
        float r = f.center.w;
        w = float3(f.center.x + q.x * r, f.center.y, f.center.z + q.y * r);
    }
    FloorOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.color = f.color;
    o.params = f.params;
    o.q = q;
    o.aspect = aspect;
    o.depth = -(F.view * float4(w, 1.0)).z;
    return o;
}

/// Additive light on the deck.
fragment float4 fs_floorfx(FloorOut in [[stage_in]],
                           constant Frame& F [[buffer(1)]],
                           texture2d<float> noise [[texture(2)]]) {
    int mode = int(in.params.x + 0.5);
    float r = length(in.q);
    float u = in.params.y, th = max(in.params.z, 0.01), seed = in.params.w;
    float time = F.camPos.w;
    float k = 0.0;
    if (mode == FM_SHOCK || mode == FM_FROST) {
        // a thin bright front at the expansion radius, a soft trail inside it, gone at the end
        float front = 0.12 + 0.88 * u;
        float d = (r - front) / th;
        k = exp(-d * d) * 1.4 + (1.0 - smoothstep(0.0, front, front - r)) * step(r, front) * 0.18;
        if (mode == FM_FROST) {
            float n = noise.sample(repeatSampler, in.q * 1.7 + seed * 3.1).r;
            k *= 0.6 + 0.8 * n;
        }
        k *= (1.0 - u) * (1.0 - u) * (1.0 - smoothstep(0.96, 1.0, r));
    } else if (mode == FM_FIRE) {
        float n = noise.sample(repeatSampler, in.q * 0.9 + float2(seed * 5.3, -time * 0.35)).r;
        float m = saturate(1.0 - r);
        k = m * m * (0.55 + 0.9 * n) * (0.85 + 0.15 * sin(time * 23.0 + seed * 40.0));
    } else if (mode == FM_ACID) {
        float n = noise.sample(repeatSampler, in.q * 1.3 + float2(seed * 2.7, time * 0.12)).r;
        float m = saturate(1.0 - r);
        k = m * m * (0.4 + 0.9 * n);
    } else {
        float m = saturate(1.0 - r);
        k = m * m;
    }
    float3 c = in.color.rgb * k * in.color.a;
    float d = F.fog.w * in.depth;
    return float4(c * exp(-d * d), 1.0);
}

/// MAX-blended telegraphs: thin rims, soft pools, never summing to white where they overlap.
fragment float4 fs_telegraph(FloorOut in [[stage_in]],
                             constant Frame& F [[buffer(1)]]) {
    int mode = int(in.params.x + 0.5);
    float2 q = in.q;
    float r = length(q);
    float u = in.params.y, blink = in.params.w;
    float k = 0.0;
    float px = max(fwidth(r), 1e-4);
    if (mode == FM_RING) {
        // warning ring: a thin rim with 24 faint ticks and a whisper of glow inside
        float rim = 1.0 - smoothstep(0.0, 1.5 * px + 0.006, abs(r - 0.94));
        float ang = atan2(q.y, q.x) / 6.2831853 + 0.5;
        float ticks = step(0.5, fract(ang * 24.0)) * (1.0 - smoothstep(0.0, 1.5 * px + 0.012, abs(r - 0.88)));
        float inner = (1.0 - smoothstep(0.0, 0.94, r)) * 0.05;
        k = (rim * 0.75 + ticks * 0.3 + inner) * blink * (1.0 - smoothstep(0.96, 1.0, r));
    } else if (mode == FM_WAVE) {
        // expanding shock ring of an ability: a crisp front
        float rim = 1.0 - smoothstep(0.0, 2.5 * px + 0.02, abs(r - 0.94));
        k = rim * (1.0 - smoothstep(0.97, 1.0, r));
    } else if (mode == FM_FILL) {
        // acid target: a faint pool deepening toward impact, a thin dim rim, and a countdown ring closing in from the rim
        // that brightens as the glob comes down (several spitters at once read as a few faint rings, not a lime target
        // board; the one about to land stands out)
        // (early in the flight both rings are faint — rim 0.14, count 0.1 — and they reach full strength only as u² grows:
        // CI combat / swarmshot showed 6–8 lime rings stacked over the squad while most globs were still far off)
        float pool = (1.0 - smoothstep(0.35, 0.97, r)) * (0.025 + 0.13 * u * u);
        float rim = 1.0 - smoothstep(0.0, 1.4 * px + 0.006, abs(r - 0.95));
        float cr = 0.95 * (1.0 - u);
        float count = (1.0 - smoothstep(0.0, 1.4 * px + 0.006, abs(r - cr))) * step(0.03, cr);
        k = (pool + rim * (0.14 + 0.3 * u * u) + count * (0.1 + 0.5 * u * u) * blink) * (1.0 - smoothstep(0.97, 1.0, r));
    } else {
        // brute lane: two DASHED border lines whose dashes run with the chevrons toward +y (the charge direction), over a
        // faint continuous edge — a hazard marking on the deck; two solid HDR lines across the platform read as laser
        // sights (CI combat), which the game no longer has
        float ax = abs(q.x);
        float pxx = max(fwidth(q.x), 1e-4);
        float along = q.y * in.aspect;
        float run = F.camPos.w * 1.2;
        float dash = fract(along * 0.45 - run);
        float dw = max(fwidth(dash), 1e-3);
        float dashOn = smoothstep(0.0, dw + 0.04, dash) * (1.0 - smoothstep(0.52, 0.52 + dw + 0.04, dash));
        float border = (1.0 - smoothstep(0.0, 2.0 * pxx + 0.02, abs(ax - 0.9))) * (0.18 + 0.62 * dashOn);
        float chev = fract((along + ax * 0.6) * 0.45 - run);   // tips toward +y, running along the charge
        float ch = (1.0 - smoothstep(0.0, 0.08, abs(chev - 0.5))) * step(ax, 0.7) * 0.5;
        float fill = 0.1;
        k = (border + ch + fill) * blink * (1.0 - smoothstep(0.92, 1.0, abs(q.y)));
    }
    float3 c = in.color.rgb * k * in.color.a;
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- beams
struct BeamInstance {
    float4 a;        // xyz start, w = half width (m)
    float4 b;        // xyz end, w = mode
    float4 color;    // rgb HDR, w = intensity
    float4 params;   // x u at a, y u at b, z seed, w mode extra (tracer: head size)
};

struct BeamOut {
    float4 position [[position]];
    float4 color;
    float4 params;
    float2 uv;       // x along 0 (a) … 1 (b), y across -1 … 1
    float mode;
    float depth;
};

#define BM_TRACER 0
#define BM_GLINT 1
#define BM_CRYO 2
#define BM_COLUMN 3
#define BM_HALO 4

vertex BeamOut vs_beam(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant Frame& F [[buffer(1)]],
                       const device BeamInstance* I [[buffer(2)]]) {
    BeamInstance s = I[iid];
    float2 q = quadCorner(vid);
    float along = q.x * 0.5 + 0.5;
    float3 a = s.a.xyz, b = s.b.xyz;
    float3 p = mix(a, b, along);
    float3 axis = b - a;
    float3 view = F.camPos.xyz - p;
    float3 side = cross(axis, view);
    float sl = length(side);
    side = sl > 1e-5 ? side / sl : F.camRight.xyz;
    float depth = max(0.05, -(F.view * float4(p, 1.0)).z);
    // never thinner than ~1.2 px: a thinner beam widens and dims instead of shimmering
    float minW = 0.6 / (F.misc.x / depth);
    float w = s.a.w;
    float4 col = s.color;
    if (w < minW) { col.w *= w / minW; w = minW; }
    float3 pos = p + side * (q.y * w);
    BeamOut o;
    o.position = F.viewProj * float4(pos, 1.0);
    o.color = col;
    o.params = float4(s.params.x, s.params.y, s.params.z, s.params.w);
    o.uv = float2(along, q.y);
    o.mode = s.b.w;
    o.depth = depth;
    return o;
}

fragment float4 fs_beam(BeamOut in [[stage_in]],
                        constant Frame& F [[buffer(1)]],
                        texture2d<float> noise [[texture(2)]]) {
    int mode = int(in.mode + 0.5);
    float x = in.uv.x, y = in.uv.y;
    float across = 1.0 - y * y;
    float time = F.camPos.w;
    float3 c;
    if (mode == BM_TRACER) {
        // a short bolt: a white-hot head at b, the class colour along a tapering tail
        float tail = pow(x, 1.6);
        float core = pow(saturate(across), 5.0);
        float glow = pow(saturate(across), 1.5) * 0.35;
        float head = smoothstep(0.7, 1.0, x);
        float3 hot = float3(1.0, 0.93, 0.82) * in.params.w;
        c = (in.color.rgb * (core + glow) * tail) + hot * core * head * head;
    } else if (mode == BM_GLINT) {
        float k = 1.0 - x;
        c = in.color.rgb * k * k * (0.35 + 0.65 * across);
    } else if (mode == BM_CRYO) {
        // the cryo beam: a cold white-cyan core, a thick turbulent frost sheath with crackle, a soft start and end
        float u = mix(in.params.x, in.params.y, x);
        float n = noise.sample(repeatSampler, float2(u * 2.3 - time * 3.1, y * 0.35 + in.params.z)).r;
        float n2 = noise.sample(repeatSampler, float2(u * 5.1 - time * 6.3, y * 0.6 - in.params.z)).r;
        float core = pow(saturate(across), 14.0) * 1.15;
        float inner = pow(saturate(across), 4.0) * 0.5;
        float sheath = saturate(across) * (0.2 + 0.8 * n) * 0.32;
        float crackle = smoothstep(0.66, 0.82, n2) * pow(saturate(across), 2.0) * 0.9;
        float fade = smoothstep(0.0, 0.06, u) * (1.0 - smoothstep(0.85, 1.0, u));
        c = (float3(0.72, 0.93, 1.0) * core + float3(0.35, 0.78, 1.0) * inner + float3(0.16, 0.5, 1.0) * (sheath + crackle)) * fade;
        c *= in.color.rgb;
    } else if (mode == BM_COLUMN) {
        float k = 1.0 - x;
        c = in.color.rgb * k * k * (0.35 + 0.65 * across);
    } else {
        // soft halo
        c = in.color.rgb * pow(saturate(across), 2.0) * (1.0 - abs(x * 2.0 - 1.0) * 0.6);
    }
    float d = F.fog.w * in.depth;
    return float4(c * in.color.w * exp(-d * d), 1.0);
}

// ---------------------------------------------------------------- heat distortion (¼ res, High)
struct HeatInstance {
    float4 pos;      // xyz centre, w = radius (m)
    float4 params;   // x strength 0…1, y mode (0 blob, 1 expanding wave, 2 rising column), z progress 0…1, w seed
};

struct HeatOut {
    float4 position [[position]];
    float2 q;
    float4 params;
};

vertex HeatOut vs_heat(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant Frame& F [[buffer(1)]],
                       const device HeatInstance* I [[buffer(2)]]) {
    HeatInstance h = I[iid];
    float2 q = quadCorner(vid);
    float r = h.pos.w;
    float up = h.params.y > 1.5 ? 1.8 : 1.0;
    float3 w = h.pos.xyz + F.camRight.xyz * (q.x * r) + F.camUp.xyz * ((q.y * up + (up - 1.0)) * r);
    HeatOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.q = q;
    o.params = h.params;
    return o;
}

/// Offsets around 0.5 (signed through the alpha blend): shimmering noise, masked by the shape.
fragment float4 fs_heat(HeatOut in [[stage_in]],
                        constant Frame& F [[buffer(1)]],
                        texture2d<float> noise [[texture(2)]]) {
    float2 q = in.q;
    float r = length(q);
    int mode = int(in.params.y + 0.5);
    float u = in.params.z;
    float t = F.camPos.w;
    float mask;
    if (mode == 1) {
        float front = 0.15 + 0.85 * u;
        float d = (r - front) / 0.12;
        mask = exp(-d * d) * (1.0 - u);
    } else {
        mask = saturate(1.0 - r);
        mask *= mask;
    }
    float2 n = float2(noise.sample(repeatSampler, q * 0.9 + float2(in.params.w * 3.7, -t * 1.7)).r,
                      noise.sample(repeatSampler, q * 0.9 + float2(-t * 1.3, in.params.w * 5.1)).r) - 0.5;
    if (mode == 1) n = normalize(q + 1e-4) * 0.35 + n * 0.3;
    float2 off = n * in.params.x * 0.9;
    return float4(0.5 + off, 0.0, saturate(mask * 1.4));
}
