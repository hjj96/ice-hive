// ================================================================
//  LIGHTING — the light model every material shader includes (owned by
//  WP2 «Свет и воздух»). Functions return linear radiance /
//  irradiance; the output encoding is Common.h's encodeColor().
//
//  The light discipline of the blend: ambient is faint cold moonlight,
//  the squad's four flashlights are the light (a flattened distance
//  falloff, so the near field does not blow out and the pool keeps a
//  gradient, and a cookie: hot core, faint dark ring, reflector ring),
//  plus short-lived grid lights (muzzles, flames, napalm, blasts,
//  beacons, lamps) and one cool fill light over the squad for
//  readability. Values: Lighting/LightGrid.swift.
//
//  Two entry levels:
//   1. The frame-only API (needs nothing but `constant Frame& F`):
//      lambertLight / standardLight / spotShadow — hemisphere + moon +
//      the 4 flashlights (cookie, flattened falloff) + 3 point lights
//      (LightGrid fills them with the fx light, the squad fill and the
//      strongest grid light) and the player's flashlight shadow out of
//      the atlas. Every shader written before WP2 uses it unchanged.
//   2. The full API (LIGHTING_PARAMS in the fragment signature,
//      LIGHTING_ARGS at the call): shadeLit(F, LB, …, surface, high) —
//      the same lights plus the XZ light grid (≤ 32 lights, a 32-bit
//      mask per 3 m cell), 4-spot shadow atlas with 4-tap PCF, Karis
//      EnvBRDF + the 64² environment probe, a clear-coat lobe (High),
//      contact occlusion from the occupancy map and the height fog of
//      the abyss (heightFog). See the README «Свет» section.
//
//  World-pass bindings (LightGrid binds them once per frame, opaque
//  item 10, fragment and vertex stage):
//    buffer  5  LightBlock (LIGHT_BUFFER)
//    texture 3  shadow atlas (TextureIndex.shadow; ShadowAtlas)
//    texture 4  environment probe cube (TEX_ENV; EnvProbe)
//    texture 5  occupancy RG8 (TEX_OCC; Occupancy)
//  LightBlock mirrors LightBlockHeader + cells + lights in
//  Lighting/LightGrid.swift (sizes asserted there).
// ================================================================
#ifndef ICEHIVE_LIGHTING_H
#define ICEHIVE_LIGHTING_H

#include "Common.h"

// ---------------------------------------------------------------- spot model (frame-only API)
#define SPOT_COLOR float3(1.0, 0.8879, 0.7304)   /* 0xfff2de, linear */
#define SPOT_COS_OUT 0.87758                      /* cos(0.5) */
#define SPOT_COS_IN 0.97479                       /* cos(0.5 * (1 - 0.55)) */
#define SPOT_RANGE 32.0
#define SPOT_DECAY 1.35
#define POINT_DECAY 2.0
/// Flattened flashlight falloff 1 / (1 + (d / SPOT_FLAT_D)²), normalised to the web's d^-1.35 at SPOT_NORM_D metres, so
/// F.spotPos.w keeps its meaning at the pool and the near field (a bug right in front of the barrel) does not blow out.
#define SPOT_FLAT_D 4.0
#define SPOT_NORM_D 5.0
/// Cookie strength of the frame-only API (the full API reads LightBlock.spotCone[k].w).
#define SPOT_COOKIE 1.0

// ---------------------------------------------------------------- full API: slots and the light block
#define LIGHT_BUFFER 5
#define TEX_ENV 4
#define TEX_OCC 5
#define MAX_GRID_LIGHTS 32
#define LIGHT_GRID_N 16

struct GridLight {
    float4 posRange;   // xyz position, w = range (m)
    float4 color;      // rgb = colour × intensity / π, w = 1: also specular (High)
};

struct LightBlock {
    float4 grid;           // xy = world xz of the grid's min corner, z = 1 / cell size (m), w = cells per side
    float4 info;           // x = grid light count, y = 1 on the High tier, z = environment intensity, w = probe mip count
    float4 spotRect[4];    // shadow atlas rect of spot k: xy = uv offset, zw = uv scale (zw = 0: no tile this frame)
    float4x4 spotMatrix[4];// spot k's shadow view-projection (Metal depth 0…1)
    float4 spotCone[4];    // x = cos outer, y = cos inner, z = range, w = cookie strength
    float4 beam[4];        // x = in-scatter gain (0 = no beam), y = beam length, z = deck height under the spot, w = 1 shadowed march
    float4 shadow;         // x = depth bias, y = 1 / atlas width, z = 1 / atlas height, w = PCF radius (texels)
    float4 fog;            // height fog: x = reference height (deck), y = metres per 1/e below it, z = max density, w = time
    float4 fogColor;       // rgb = linear radiance of the abyss haze, w = beam saturation cap (radiance)
    float4 occ;            // occupancy: xy = world min corner, z = 1 / world size, w = 1 valid
    float4 fill;           // squad fill: xyz position, w = range (also in F.pointPos[1])
    float4 ambient;        // x = probe diffuse weight, y = probe specular weight, z = contact AO strength, w = unused
    uint4 cells[LIGHT_GRID_N * LIGHT_GRID_N / 4];   // light mask per cell (bit i = lights[i]), 4 cells per uint4
    GridLight lights[MAX_GRID_LIGHTS];
};

/// Fragment parameters a material adds to use the full API (after its own; the slots are bound for the whole world pass).
#define LIGHTING_PARAMS constant LightBlock& LB [[buffer(LIGHT_BUFFER)]], depth2d<float> shadowAtlas [[texture(3)]], \
                        texturecube<half> envProbe [[texture(TEX_ENV)]], texture2d<half> occupancy [[texture(TEX_OCC)]]
/// The matching arguments of shadeLit / heightFog / contactAO.
#define LIGHTING_ARGS F, LB, shadowAtlas, envProbe, occupancy

constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
constexpr sampler probeSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

// ---------------------------------------------------------------- BRDF pieces
static float distanceAtten(float d, float cutoff, float decay) {
    float falloff = 1.0 / max(pow(max(d, 1e-4), decay), 0.01);
    float x = d / cutoff;
    float s = saturate(1.0 - x * x * x * x);
    return falloff * s * s;
}

/// The flashlight's flattened falloff (see SPOT_FLAT_D) with the range window.
static float spotAtten(float d, float range) {
    const float k = (1.0 + (SPOT_NORM_D / SPOT_FLAT_D) * (SPOT_NORM_D / SPOT_FLAT_D)) * 0.11372;   // 5^-1.35
    float q = d / SPOT_FLAT_D;
    float x = d / range;
    float s = saturate(1.0 - x * x * x * x);
    return k / (1.0 + q * q) * s * s;
}

/// Flashlight cookie at the cosine to the axis: 0 outside, a hot core, a faint dark ring at half the radius, the
/// reflector's bright ring near the rim, a soft edge (radial coordinate r = angle / outer angle from 1 − cos).
static float spotCookie(float cosA, float cosOut, float cosIn, float strength) {
    float r = sqrt(saturate((1.0 - cosA) / (1.0 - cosOut)));
    float edge = 1.0 - smoothstep(sqrt((1.0 - cosIn) / (1.0 - cosOut)), 1.0, r);
    float a = (r - 0.55) / 0.09, b = (r - 0.8) / 0.06;
    float c = 1.0 + 0.32 * (1.0 - smoothstep(0.0, 0.38, r)) - 0.16 * exp(-a * a) + 0.12 * exp(-b * b);
    return edge * mix(1.0, c, strength);
}

static float3 fresnelSchlick(float3 f0, float dotVH) {
    float f = exp2((-5.55473 * dotVH - 6.98316) * dotVH);
    return f0 * (1.0 - f) + f;
}

static float3 brdfGGX(float3 L, float3 V, float3 N, float3 f0, float alpha) {
    float3 H = normalize(L + V);
    float dotNL = saturate(dot(N, L));
    float dotNV = saturate(dot(N, V));
    float dotNH = saturate(dot(N, H));
    float dotVH = saturate(dot(V, H));
    float a2 = alpha * alpha;
    float gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
    float gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
    float vis = 0.5 / max(gv + gl, 1e-6);
    float den = dotNH * dotNH * (a2 - 1.0) + 1.0;
    float D = (1.0 / PI_F) * a2 / (den * den);
    return fresnelSchlick(f0, dotVH) * (vis * D);
}

/// Karis' analytic EnvBRDF for mobile (scale, bias of f0) at roughness `rough` and N·V.
static float2 envBRDFApprox(float rough, float NoV) {
    const float4 c0 = float4(-1.0, -0.0275, -0.572, 0.022);
    const float4 c1 = float4(1.0, 0.0425, 1.04, -0.04);
    float4 r = rough * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
    return float2(-1.04, 1.04) * a004 + r.zw;
}

// ---------------------------------------------------------------- frame-only API
/// Flashlight `i` at P: unit direction to the light in xyz, w = intensity / π × cookie × falloff (0 = not lit).
static float4 spotTerm(constant Frame& F, int i, float3 P) {
    float I = F.spotPos[i].w;
    if (I <= 0.0) return float4(0.0);
    float3 Lv = F.spotPos[i].xyz - P;
    float d = length(Lv);
    float3 L = Lv / max(d, 1e-4);
    float cosA = dot(-L, F.spotDir[i].xyz);
    if (cosA <= SPOT_COS_OUT) return float4(L, 0.0);
    return float4(L, I * spotCookie(cosA, SPOT_COS_OUT, SPOT_COS_IN, SPOT_COOKIE) * spotAtten(d, SPOT_RANGE));
}

/// The player's flashlight shadow at P (1 = lit): 4-tap PCF (each tap a bilinear 2 × 2 compare) in the player's tile of
/// the shadow atlas. F.shadowParams: x = on, y = depth bias, z = 1 / tile size, w = u scale of the tile in the atlas.
static float spotShadow(constant Frame& F, depth2d<float> sm, float3 P) {
    if (F.shadowParams.x < 0.5) return 1.0;
    float4 c = F.shadowMatrix * float4(P, 1.0);
    if (c.w <= 0.0) return 1.0;
    float3 s = c.xyz / c.w;
    float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0 || s.z > 1.0) return 1.0;
    float us = F.shadowParams.w > 0.0 ? F.shadowParams.w : 1.0;
    uv.x *= us;
    float z = s.z + F.shadowParams.y;
    float2 t = float2(F.shadowParams.z * us, F.shadowParams.z) * 0.75;
    float sum = sm.sample_compare(shadowSampler, uv + float2(-t.x, -t.y), z) + sm.sample_compare(shadowSampler, uv + float2(t.x, -t.y), z)
              + sm.sample_compare(shadowSampler, uv + float2(-t.x, t.y), z) + sm.sample_compare(shadowSampler, uv + float2(t.x, t.y), z);
    return sum * 0.25;
}

/// Irradiance / PI of every light at P (Lambert; multiply by the albedo). `sh` scales the player's flashlight (shadow).
static float3 lambertLight(constant Frame& F, float3 P, float3 N, float sh = 1.0) {
    float3 irr = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * N.y + 0.5);
    irr += F.moonColor.rgb * saturate(dot(N, F.moonDir.xyz));
    for (int i = 0; i < 4; i++) {
        float4 s = spotTerm(F, i, P);
        if (s.w <= 0.0) continue;
        irr += SPOT_COLOR * (s.w * saturate(dot(N, s.xyz)) * (i == 0 ? sh : 1.0));
    }
    for (int i = 0; i < 3; i++) {
        float range = F.pointPos[i].w;
        if (range <= 0.0) continue;
        float3 Lv = F.pointPos[i].xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        irr += F.pointColor[i].rgb * (distanceAtten(d, range, POINT_DECAY) * saturate(dot(N, L)));
    }
    return irr;
}

/// MeshStandardMaterial without environment map: Lambert diffuse * (1 - metalness) + GGX specular.
static float3 standardLight(constant Frame& F, float3 P, float3 N, float3 V, float3 albedo, float rough, float metal, float sh = 1.0) {
    float3 diffuse = albedo * (1.0 - metal);
    float3 f0 = mix(float3(0.04), albedo, metal);
    float r = max(rough, 0.0525);
    float alpha = r * r;
    float3 outD = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * N.y + 0.5) * diffuse;
    float3 outS = float3(0.0);
    {
        float3 L = F.moonDir.xyz;
        float nl = saturate(dot(N, L));
        float3 c = F.moonColor.rgb * nl;
        outD += c * diffuse;
        outS += c * PI_F * brdfGGX(L, V, N, f0, alpha);
    }
    for (int i = 0; i < 4; i++) {
        float4 s = spotTerm(F, i, P);
        float k = s.w * saturate(dot(N, s.xyz)) * (i == 0 ? sh : 1.0);
        if (k <= 0.0) continue;
        float3 c = SPOT_COLOR * k;
        outD += c * diffuse;
        outS += c * PI_F * brdfGGX(s.xyz, V, N, f0, alpha);
    }
    for (int i = 0; i < 3; i++) {
        float range = F.pointPos[i].w;
        if (range <= 0.0) continue;
        float3 Lv = F.pointPos[i].xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        float k = distanceAtten(d, range, POINT_DECAY) * saturate(dot(N, L));
        if (k <= 0.0) continue;
        float3 c = F.pointColor[i].rgb * k;
        outD += c * diffuse;
        outS += c * PI_F * brdfGGX(L, V, N, f0, alpha);
    }
    return outD + outS;
}

/// Flashlight in-scatter at a point in the air (snow, mist, smoke, sparks): Σ spots × cookie × falloff, no N·L, no
/// shadow. × SPOT_COLOR by the caller's choice (returned already tinted).
static float3 spotInScatter(constant Frame& F, float3 P) {
    float3 s = float3(0.0);
    for (int i = 0; i < 4; i++) s += SPOT_COLOR * spotTerm(F, i, P).w;
    return s;
}

// ---------------------------------------------------------------- full API
/// Shadow of spot k at P (1 = lit) from its atlas tile: 4-tap PCF (bilinear compares), slope-scaled by N·L.
static float atlasShadow(constant LightBlock& LB, depth2d<float> atlas, int k, float3 P, float nl) {
    float4 rect = LB.spotRect[k];
    if (rect.z <= 0.0) return 1.0;
    float4 c = LB.spotMatrix[k] * float4(P, 1.0);
    if (c.w <= 0.0) return 1.0;
    float3 s = c.xyz / c.w;
    float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0 || s.z > 1.0) return 1.0;
    uv = rect.xy + uv * rect.zw;
    float z = s.z + LB.shadow.x * (1.0 + 2.0 * (1.0 - saturate(nl)));
    float2 t = LB.shadow.yz * LB.shadow.w;
    float sum = atlas.sample_compare(shadowSampler, uv + float2(-t.x, -t.y), z) + atlas.sample_compare(shadowSampler, uv + float2(t.x, -t.y), z)
              + atlas.sample_compare(shadowSampler, uv + float2(-t.x, t.y), z) + atlas.sample_compare(shadowSampler, uv + float2(t.x, t.y), z);
    return sum * 0.25;
}

/// Spot k at P from the light block: unit direction to the light, w = intensity / π × cookie × falloff.
static float4 spotTermLB(constant Frame& F, constant LightBlock& LB, int k, float3 P) {
    float I = F.spotPos[k].w;
    if (I <= 0.0) return float4(0.0);
    float4 cone = LB.spotCone[k];
    float3 Lv = F.spotPos[k].xyz - P;
    float d = length(Lv);
    float3 L = Lv / max(d, 1e-4);
    float cosA = dot(-L, F.spotDir[k].xyz);
    if (cosA <= cone.x) return float4(L, 0.0);
    return float4(L, I * spotCookie(cosA, cone.x, cone.y, cone.w) * spotAtten(d, cone.z));
}

/// Mask of the grid lights that may reach P (its 3 m cell).
static uint gridMask(constant LightBlock& LB, float3 P) {
    float n = LB.grid.w;
    float2 c = (P.xz - LB.grid.xy) * LB.grid.z;
    if (c.x < 0.0 || c.y < 0.0 || c.x >= n || c.y >= n) return 0u;
    uint idx = uint(c.y) * uint(n) + uint(c.x);
    uint4 q = LB.cells[idx >> 2];
    uint s = idx & 3u;
    return s == 0u ? q.x : (s == 1u ? q.y : (s == 2u ? q.z : q.w));
}

/// Contact occlusion (R) and trail (G) of the swarm / squad at P from the occupancy map (0 = none).
static half2 occupancyAt(constant LightBlock& LB, texture2d<half> occ, float3 P) {
    if (LB.occ.w < 0.5) return half2(0.0);
    float2 uv = (P.xz - LB.occ.xy) * LB.occ.z;
    return occ.sample(dataSampler, uv).rg;
}

/// Contact occlusion factor (1 = open) for a surface at P.
static float contactAO(constant Frame& F, constant LightBlock& LB, depth2d<float> shadowAtlas, texturecube<half> envProbe,
                       texture2d<half> occupancy, float3 P) {
    return 1.0 - LB.ambient.z * float(occupancyAt(LB, occupancy, P).r);
}

/// A surface for shadeLit.
struct LitSurface {
    float3 P;        // world position
    float3 N;        // unit normal
    float3 V;        // unit direction to the camera
    float3 albedo;   // linear base colour
    float rough;     // perceptual roughness
    float metal;     // metalness
    float coat;      // clear-coat weight (0 = none; High only)
    float coatRough; // clear-coat roughness
    float ao;        // baked occlusion (1 = none); contact AO from the occupancy map is applied on top
    float shadow;    // 1 = receives the flashlights' atlas shadows (three.js receiveShadow), 0 = not
};

/// The full light model: ambient (hemisphere + moon + probe), the four flashlights with their atlas shadows, the grid
/// lights (High: diffuse + specular; Efficient: diffuse only, ≤ 12 nearest by the CPU's ordering), the clear-coat lobe
/// (High) and contact occlusion. Linear radiance (no fog: heightFog / encodeColor afterwards).
static float3 shadeLit(constant Frame& F, constant LightBlock& LB, depth2d<float> shadowAtlas, texturecube<half> envProbe,
                       texture2d<half> occupancy, LitSurface s, bool high) {
    float3 N = s.N, V = s.V, P = s.P;
    float3 diffuse = s.albedo * (1.0 - s.metal);
    float3 f0 = mix(float3(0.04), s.albedo, s.metal);
    float r = max(s.rough, 0.0525);
    float alpha = r * r;
    float NoV = saturate(dot(N, V)) + 1e-4;
    float occ = s.ao * (1.0 - LB.ambient.z * float(occupancyAt(LB, occupancy, P).r));
    float coat = high ? s.coat : 0.0;
    float cr = max(s.coatRough, 0.03);
    float coatA = cr * cr;
    float coatF = coat * (0.04 + 0.96 * pow(1.0 - NoV, 5.0));
    // ambient: hemisphere + moon (frame), the probe's diffuse and specular (Karis EnvBRDF)
    float3 amb = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * N.y + 0.5);
    float lodTop = max(LB.info.w - 1.0, 0.0);
    float3 envD = float3(envProbe.sample(probeSampler, N, level(lodTop)).rgb) * LB.ambient.x;
    float3 R = reflect(-V, N);
    float3 envS = float3(envProbe.sample(probeSampler, R, level(r * lodTop)).rgb) * LB.ambient.y;
    float2 ab = envBRDFApprox(r, NoV);
    float3 outD = (amb + envD) * diffuse * occ;
    float3 outS = envS * (f0 * ab.x + ab.y) * occ;
    if (coat > 0.0) {
        float3 envC = float3(envProbe.sample(probeSampler, R, level(cr * lodTop)).rgb) * LB.ambient.y;
        outS = outS * (1.0 - coatF) + envC * coatF * occ;
    }
    // moon
    {
        float3 L = F.moonDir.xyz;
        float nl = saturate(dot(N, L));
        float3 c = F.moonColor.rgb * nl;
        outD += c * diffuse;
        outS += c * PI_F * brdfGGX(L, V, N, f0, alpha);
    }
    // the flashlights, shadowed from the atlas (Efficient: only the player's tile exists)
    for (int i = 0; i < 4; i++) {
        float4 st = spotTermLB(F, LB, i, P);
        float nl = saturate(dot(N, st.xyz));
        float k = st.w * nl;
        if (k <= 0.0) continue;
        if (s.shadow > 0.5) k *= atlasShadow(LB, shadowAtlas, i, P, nl);
        float3 c = SPOT_COLOR * k;
        outD += c * diffuse;
        float3 sp = c * PI_F * brdfGGX(st.xyz, V, N, f0, alpha);
        if (coat > 0.0) sp = sp * (1.0 - coatF) + c * PI_F * brdfGGX(st.xyz, V, N, float3(0.04), coatA) * coat;
        outS += sp;
    }
    // the grid lights of P's cell (bit i = lights[i])
    uint mask = gridMask(LB, P);
    while (mask != 0u) {
        uint i = ctz(mask);
        mask &= mask - 1u;
        GridLight gl = LB.lights[i];
        float3 Lv = gl.posRange.xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        float k = distanceAtten(d, gl.posRange.w, POINT_DECAY) * saturate(dot(N, L));
        if (k <= 0.0) continue;
        float3 c = gl.color.rgb * k;
        outD += c * diffuse;
        if (high && gl.color.w > 0.5) outS += c * PI_F * brdfGGX(L, V, N, f0, alpha);
    }
    return outD + outS;
}

/// Linear-space fog of a surface at P, `depth` m from the camera: the frame's exp² distance fog toward F.fog, then the
/// height fog of the abyss (exponential below the deck toward LB.fogColor) — pillars and props sink into the dark.
static float3 heightFog(constant Frame& F, constant LightBlock& LB, float3 lin, float3 P, float depth) {
    float d = F.fog.w * depth;
    lin = mix(lin, F.fog.rgb, 1.0 - exp(-d * d));
    float below = max(0.0, LB.fog.x - P.y);
    float h = (1.0 - exp(-below / max(LB.fog.y, 0.1))) * LB.fog.z;
    return mix(lin, LB.fogColor.rgb, h);
}

#endif
