// ================================================================
//  ATMOSPHERE — air, weather and light in the air (owned by WP2 «Свет
//  и воздух»; Swift side: Lighting/VolumeCones.swift, Occupancy.swift).
//    fog decks      2 (Efficient 1) drifting fbm sheets of dark cold
//                   fog between the piers, under the decks (alpha)
//    haze           the old icy haze plane 16 m down, now a faint cold
//                   glow far below (alpha)
//    running lights red / sodium lamps on the piers far below, a few
//                   blinking (additive HDR dots, sunk in the height fog)
//    cones          the four flashlights as analytic volumetric cones:
//                   ray / cone entry-exit, clipped at the deck plane
//                   under the marine and at the beam length, Henyey-
//                   Greenstein phase, drifting dust, a per-beam
//                   saturation cap (a veil, never a white-out); High:
//                   the player's cone is an 8-step march through its
//                   shadow-atlas tile (bugs and marines cut shafts)
//    weather        snow and low mist that exist only in the light:
//                   additive, lit by the flashlights (no ambient term:
//                   in the dark they add nothing); pink motes rising
//                   out of the abyss
//    occupancy      R0 pre-pass: 256² RG8 over the level — R = contact
//                   occlusion of every bug and marine this frame, G = a
//                   trail with an ~8 s half-life (trampled snow, ichor)
// ================================================================
#include "Common.h"
#include "Lighting.h"

// tier variant of the cones (FC_TIER_HIGH): High marches the player's cone through its shadow tile
TIER_CONSTANT(kAtmoHigh);

struct WeatherParams {
    float4 center;   // xyz camera target, w = kind (0 snow, 1 motes, 2 mist)
    float4 extra;    // x = count, y = half extent of the box (m), z = box height (m), w = gain
};

/// Interleaved gradient noise in [0, 1) (Jimenez 2014): per-pixel dither of the cone march start.
static float atmoIGN(float2 px) {
    return fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715))));
}

static float hash11(float n) { return fract(sin(n * 12.9898 + 78.233) * 43758.5453); }

// ================================================================ abyss haze plane (static mesh, alpha)
vertex MeshOut vs_haze(MeshIn v [[stage_in]],
                       constant Frame& F [[buffer(1)]],
                       constant Material& M [[buffer(3)]]) {
    float3 w = v.position + float3(0.0, M.floor.z, 0.0);
    return meshOut(F, w, v.normal, v.color, v.glow, v.leg.xy, float3(0.0));
}

/// The old bright icy radial haze (it read as a pale blue floor under linear blending), now only a soft lift of the
/// abyss colour deep in the shaft: the radial map's alpha shapes it, its icy colour is dropped — crisp's navy over
/// horror's near-black, never brighter than ~2× the height fog.
fragment float4 fs_haze(MeshOut in [[stage_in]],
                        constant Frame& F [[buffer(1)]],
                        constant LightBlock& LB [[buffer(LIGHT_BUFFER)]],
                        texture2d<float> map [[texture(0)]]) {
    float4 t = map.sample(clampSampler, in.uv);
    float3 c = LB.fogColor.rgb * (1.3 + 0.9 * saturate(t.a * 1.8));
    return float4(c, saturate(t.a * 1.4) * 0.75);
}

// ================================================================ fog decks (alpha)
struct FogDeck {
    float4 plane;    // x = height (m), y = opacity, z = noise scale (1/m), w = drift (m/s)
    float4 color;    // rgb linear radiance, w = seed
    float4 center;   // xz = centre (camera target, snapped), y = half size (m), w = fade radius (m)
};

struct FogDeckOut {
    float4 position [[position]];
    float3 world;
    uint deck [[flat]];
};

vertex FogDeckOut vs_fogdeck(uint vid [[vertex_id]], uint iid [[instance_id]],
                             constant Frame& F [[buffer(1)]],
                             constant FogDeck* D [[buffer(2)]]) {
    FogDeck d = D[iid];
    float2 q = quadCorner(vid);
    float3 w = float3(d.center.x + q.x * d.center.y, d.plane.x, d.center.z + q.y * d.center.y);
    FogDeckOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.world = w;
    o.deck = iid;
    return o;
}

fragment float4 fs_fogdeck(FogDeckOut in [[stage_in]],
                           constant Frame& F [[buffer(1)]],
                           constant FogDeck* D [[buffer(2)]],
                           texture2d<float> noise [[texture(2)]]) {
    FogDeck d = D[in.deck];
    float time = F.camPos.w;
    float2 p = in.world.xz * d.plane.z + d.color.w;
    float2 drift = float2(time, time * 0.37) * d.plane.w * d.plane.z;
    float n = noise.sample(repeatSampler, p + drift).r * 0.62 + noise.sample(repeatSampler, p * 2.03 - drift * 1.7 + 0.37).g * 0.38;
    n = smoothstep(0.3, 0.82, n);
    float r = length(in.world.xz - d.center.xz);
    float fade = 1.0 - smoothstep(d.center.w * 0.5, d.center.w, r);
    return float4(d.color.rgb, n * d.plane.y * fade);
}

// ================================================================ running lights far below (additive)
struct RunLight {
    float4 pos;      // xyz, w = core size (m)
    float4 color;    // rgb HDR radiance, w = blink phase (< 0: steady)
};

vertex QuadOut vs_runlight(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Frame& F [[buffer(1)]],
                           constant LightBlock& LB [[buffer(LIGHT_BUFFER)]],
                           const device RunLight* R [[buffer(2)]]) {
    RunLight l = R[iid];
    float3 p = l.pos.xyz;
    float z = max(0.05, -(F.view * float4(p, 1.0)).z);
    // a halo 4× the core, at least ~5 drawable px across so a distant lamp stays a stable dot
    float px = max(l.pos.w * 4.0 * F.misc.x / z, 5.0);
    float hs = 0.5 * px * z / F.misc.x;
    float2 q = quadCorner(vid);
    float3 w = p + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    float blink = l.color.w < 0.0 ? 1.0 : 0.25 + 0.75 * smoothstep(0.35, 0.65, 0.5 + 0.5 * sin(F.camPos.w * 2.1 + l.color.w * 6.2831853));
    // sunk in the abyss: the height fog and the distance fog eat the deep ones
    float below = max(0.0, LB.fog.x - p.y);
    float k = exp(-below / max(LB.fog.y * 1.6, 0.1)) * exp(-pow(F.fog.w * z * 0.6, 2.0));
    return quadOut(F, w, float4(l.color.rgb * blink * k, 1.0), q, float4(0.0));
}

fragment float4 fs_runlight(QuadOut in [[stage_in]]) {
    float r2 = dot(in.uv, in.uv);
    float a = exp(-r2 * 7.0) * 0.35 + exp(-r2 * 60.0);
    return float4(in.color.rgb * a, 1.0);
}

// ================================================================ volumetric flashlight cones (additive)
#define CONE_SEGMENTS 16

struct ConeOut {
    float4 position [[position]];
    float3 world;
    uint cone [[flat]];
};

/// The hull of cone `iid` (16 sides + the far cap, circumscribed): 96 vertices, CCW from outside (back faces culled).
vertex ConeOut vs_cone(uint vid [[vertex_id]], uint iid [[instance_id]],
                       constant Frame& F [[buffer(1)]],
                       constant LightBlock& LB [[buffer(LIGHT_BUFFER)]]) {
    ConeOut o;
    o.cone = iid;
    float3 A = F.spotPos[iid].xyz, D = F.spotDir[iid].xyz;
    float len = LB.beam[iid].y;
    if (F.spotPos[iid].w <= 0.0 || LB.beam[iid].x <= 0.0 || len <= 0.0) {
        o.position = float4(0.0, 0.0, 2.0, 1.0);
        o.world = A;
        return o;
    }
    float3 up = abs(D.y) < 0.95 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
    float3 u = normalize(cross(D, up));
    float3 v = cross(D, u);
    float c = LB.spotCone[iid].x;
    float radius = len * sqrt(max(1.0 - c * c, 1e-4)) / max(c, 1e-3) / cos(PI_F / float(CONE_SEGMENTS));
    uint tri = vid / 3u, corner = vid % 3u;
    uint seg = tri % uint(CONE_SEGMENTS);
    float a0 = float(seg) * (2.0 * PI_F / float(CONE_SEGMENTS)), a1 = float(seg + 1u) * (2.0 * PI_F / float(CONE_SEGMENTS));
    float3 C = A + D * len;
    float3 r0 = C + (u * cos(a0) + v * sin(a0)) * radius;
    float3 r1 = C + (u * cos(a1) + v * sin(a1)) * radius;
    float3 w;
    if (tri < uint(CONE_SEGMENTS)) {
        w = corner == 0u ? A : (corner == 1u ? r1 : r0);   // side
    } else {
        w = corner == 0u ? C : (corner == 1u ? r0 : r1);   // far cap
    }
    o.position = F.viewProj * float4(w, 1.0);
    o.world = w;
    return o;
}

/// In-scattered flashlight of cone `in.cone` along the view ray: the segment inside the cone, clipped at the beam
/// length and the deck plane under the marine, integrated in 3 steps (High, the player's cone: 8 steps through its
/// shadow tile); dust from the noise texture, HG phase (g 0.2, normalised to 1 side-on, forward capped at 2×), the
/// saturating per-beam cap. Additive.
fragment float4 fs_cone(ConeOut in [[stage_in]],
                        constant Frame& F [[buffer(1)]],
                        constant LightBlock& LB [[buffer(LIGHT_BUFFER)]],
                        texture2d<float> noise [[texture(2)]],
                        depth2d<float> atlas [[texture(3)]]) {
    uint k = in.cone;
    float3 ro = F.camPos.xyz;
    float3 rd = normalize(in.world - ro);
    float3 A = F.spotPos[k].xyz, D = F.spotDir[k].xyz;
    float4 cone = LB.spotCone[k];
    float4 beam = LB.beam[k];
    float c2 = cone.x * cone.x;
    float3 co = ro - A;
    float dv = dot(rd, D), cv = dot(co, D);
    float a = dv * dv - c2, b = 2.0 * (dv * cv - dot(rd, co) * c2), c = cv * cv - dot(co, co) * c2;
    float disc = b * b - 4.0 * a * c;
    if (disc <= 0.0 || abs(a) < 1e-5) return float4(0.0);
    float sq = sqrt(disc);
    float r0 = (-b - sq) / (2.0 * a), r1 = (-b + sq) / (2.0 * a);
    float t0 = min(r0, r1), t1 = max(r0, r1);
    if (a > 0.0) {
        // inside the double cone outside [t0, t1]: keep the half-line on the forward nappe
        if (dot(co + rd * (t1 + 0.01), D) > 0.0) { t0 = t1; t1 = 1e4; } else { t1 = t0; t0 = 0.0; }
    }
    // the beam between the lens and its length (also drops the backward nappe)
    if (abs(dv) > 1e-4) {
        float th = -cv / dv, tl = (beam.y - cv) / dv;
        if (dv > 0.0) { t0 = max(t0, th); t1 = min(t1, tl); } else { t0 = max(t0, tl); t1 = min(t1, th); }
    }
    // the deck plane under the marine ends the beam (no depth read: MSAA-safe)
    if (rd.y < 0.0) t1 = min(t1, (beam.z - ro.y) / rd.y);
    t0 = max(t0, 0.0);
    if (t1 <= t0) return float4(0.0);
    bool march = kAtmoHigh && k == 0u && beam.w > 0.5 && LB.spotRect[0].z > 0.0;
    int steps = march ? 8 : 3;
    float dt = (t1 - t0) / float(steps);
    float j = atmoIGN(in.position.xy);
    float time = F.camPos.w;
    float sum = 0.0;
    for (int i = 0; i < 8; i++) {
        if (i >= steps) break;
        float3 p = ro + rd * (t0 + (float(i) + j) * dt);
        float3 q = p - A;
        float dist = max(length(q), 1e-3);
        float h = dot(q, D);
        float cosT = h / dist;
        float lit = spotCookie(cosT, cone.x, cone.y, cone.w * 0.6) * spotAtten(dist, cone.z);
        lit *= smoothstep(0.15, 1.1, h) * (1.0 - smoothstep(beam.y * 0.55, beam.y, h));
        if (lit <= 0.0) continue;
        // drifting dust: shafts with structure, not milk
        float n1 = noise.sample(repeatSampler, p.xz * 0.21 + float2(time * 0.031, -time * 0.047) + p.y * 0.09).r;
        float n2 = noise.sample(repeatSampler, float2(p.x - p.z, p.y) * 0.37 + float2(-time * 0.02, time * 0.29)).g;
        float dust = 0.3 + 1.25 * n1 * n1 + 0.45 * n2 * n1;
        float cs = dot(q / dist, -rd);
        float hg = min(0.0943 / pow(1.04 - 0.4 * cs, 1.5) / 0.1, 2.0);
        float sh = 1.0;
        if (march) {
            float4 sc = LB.spotMatrix[0] * float4(p, 1.0);
            if (sc.w > 0.0) {
                float3 s = sc.xyz / sc.w;
                float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
                if (uv.x > 0.0 && uv.y > 0.0 && uv.x < 1.0 && uv.y < 1.0 && s.z < 1.0) {
                    float4 rect = LB.spotRect[0];
                    sh = atlas.sample_compare(shadowSampler, rect.xy + uv * rect.zw, s.z + LB.shadow.x);
                }
            }
        }
        sum += lit * dust * hg * sh;
    }
    float depth = -(F.view * float4(ro + rd * (0.5 * (t0 + t1)), 1.0)).z;
    float fogK = F.fog.w * depth;
    float cap = LB.fogColor.w;
    float x = sum * dt * F.spotPos[k].w * beam.x;
    float3 col = SPOT_COLOR * cap * (1.0 - exp(-x / max(cap, 1e-4))) * exp(-fogK * fogK);
    return float4(col, 1.0);
}

// ================================================================ weather (GPU animated; additive, lit by the flashlights)
vertex QuadOut vs_weather(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Frame& F [[buffer(1)]],
                          constant WeatherParams& W [[buffer(2)]]) {
    float k = float(iid);
    float seed = hash11(k * 3.17 + 0.5);
    float kind = W.center.w;
    float time = F.camPos.w;
    float3 c = W.center.xyz;
    float ext = W.extra.y, hgt = W.extra.z, gain = W.extra.w;
    float2 q = quadCorner(vid);
    float3 p;
    float size;
    float3 col;
    float alpha;
    if (kind < 0.5) {
        // snow in a box around the camera target; only the flashlights show it (no light: a zero-area quad)
        float span = 2.0 * ext;
        p = float3(hash11(k + 1.1) * span - ext, hash11(k + 2.3) * hgt, hash11(k + 3.7) * span - ext);
        p.y = fmod(fmod(p.y - time * (0.8 + seed * 0.9), hgt) + hgt, hgt) - 0.4 + c.y;
        p.x += sin(time * 1.1 + seed * 40.0) * 0.35 + time * 1.3;
        p.z += cos(time * 0.9 + seed * 30.0) * 0.3 + time * 0.6;
        p.x = fmod(fmod(p.x - c.x + ext, span) + span, span) - ext + c.x;
        p.z = fmod(fmod(p.z - c.z + ext, span) + span, span) - ext + c.z;
        size = 0.022 + seed * 0.035;
        col = spotInScatter(F, p) * (gain * (0.45 + seed * 0.8));
        alpha = 1.0;
        if (max(col.r, max(col.g, col.b)) < 1e-4) return quadOut(F, p, float4(0.0), q, float4(kind, seed, 0.0, 0.0));
    } else if (kind < 1.5) {
        // pink motes rising out of the abyss (the hive's own faint light)
        p = float3(-50.0 + hash11(k + 4.1) * 95.0, -6.0 - hash11(k + 5.3) * 40.0, -58.0 + hash11(k + 6.7) * 100.0);
        p.x += sin(time * 0.3 + seed * 20.0) * 0.8;
        p.z += cos(time * 0.25 + seed * 13.0) * 0.8;
        size = 0.12 + seed * 0.2;
        alpha = max(0.0, (0.4 + 0.6 * sin(time * (1.0 + seed * 2.0) + seed * 50.0)) * smoothstep(-48.0, -8.0, p.y));
        col = float3(1.0, 0.2, 0.45) * gain;
    } else {
        // low mist banks over the decks: lit per corner by the flashlights, invisible in the dark
        p = float3(hash11(k + 7.1) * 60.0 - 30.0, 0.5 + hash11(k + 8.3) * 1.3 + c.y, hash11(k + 9.7) * 60.0 - 30.0);
        p.x += time * (0.35 + seed * 0.3);
        p.z += time * 0.12;
        p.x = fmod(fmod(p.x - c.x + 30.0, 60.0) + 60.0, 60.0) - 30.0 + c.x;
        p.z = fmod(fmod(p.z - c.z + 30.0, 60.0) + 60.0, 60.0) - 30.0 + c.z;
        size = 5.0 + seed * 5.0;
        alpha = 0.06 + 0.04 * sin(time * 0.3 + seed * 20.0);
        col = float3(0.0);
    }
    float z = max(0.05, -(F.view * float4(p, 1.0)).z);
    float lo = kind > 1.5 ? 8.0 : 1.0;
    float hi = kind < 0.5 ? 6.0 : (kind < 1.5 ? 8.0 : 180.0);
    float px = clamp(size * F.misc.x / z, lo, hi);
    float hs = 0.5 * px * z / F.misc.x;
    float3 w = p + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    if (kind > 1.5) {
        col = min(spotInScatter(F, w) * gain, float3(0.5));
    }
    return quadOut(F, w, float4(col, alpha), q * 0.5, float4(kind, seed, 0.0, 0.0));
}

fragment float4 fs_weather(QuadOut in [[stage_in]]) {
    float d = length(in.uv) * 2.0;
    float kind = in.params.x;
    float a;
    if (kind < 0.5) {
        a = in.color.a * (1.0 - smoothstep(0.15, 1.0, d));
    } else if (kind < 1.5) {
        a = in.color.a * (1.0 - smoothstep(0.0, 1.0, d));
    } else {
        float s = in.params.y;
        float2 q = in.uv;
        float n = 0.75 + 0.25 * sin(q.x * 9.0 + s * 30.0) * sin(q.y * 7.0 - s * 17.0);
        a = in.color.a * n * (1.0 - smoothstep(0.1, 1.0, d));
    }
    return float4(in.color.rgb, a);
}

// ================================================================ occupancy map (R0 pre-pass, RG8 256²)
struct OccOut {
    float4 position [[position]];
    float2 q;
    float2 k;
};

/// One soft blob per bug / marine: B[i] = (x, z, radius m, strength); M = (world min x, min z, 1 / world size, trail gain).
vertex OccOut vs_occ_blob(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device float4* B [[buffer(2)]],
                          constant float4& M [[buffer(3)]]) {
    float4 b = B[iid];
    float2 q = quadCorner(vid);
    float2 xz = b.xy + q * b.z;
    float2 uv = (xz - M.xy) * M.z;
    OccOut o;
    o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.q = q;
    o.k = float2(b.w, b.w * M.w);
    return o;
}

fragment float4 fs_occ_blob(OccOut in [[stage_in]]) {
    float a = saturate(1.0 - dot(in.q, in.q));
    a *= a;
    return float4(a * in.k.x, a * in.k.y, 0.0, 1.0);
}

struct OccFadeOut { float4 position [[position]]; };

vertex OccFadeOut vs_occ_fade(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2u), float(vid & 2u));
    OccFadeOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

/// Last frame's map → R (this frame's contact) 0, G (trails) × the decay with stochastic rounding (interleaved gradient
/// noise shifted per frame), so 8-bit trails keep fading to 0. P = (decay, frame seed, 0, 0). No blending.
fragment float4 fs_occ_fade(OccFadeOut in [[stage_in]],
                            constant float4& P [[buffer(0)]],
                            texture2d<float> prev [[texture(0)]]) {
    float g = prev.read(uint2(in.position.xy)).g;
    float n = atmoIGN(in.position.xy + P.y * float2(5.588238, 3.1415));
    return float4(0.0, floor(g * 255.0 * P.x + n) / 255.0, 0.0, 1.0);
}
