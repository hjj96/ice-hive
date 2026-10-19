// ================================================================
//  LEVEL — station materials (owned by WP6 «Станция и конвейер»).
//  fs_level shades the whole merged station (Level/WorldLevel.swift):
//  the kit pieces of tools/blender (KitStore.swift) and the runtime-
//  extruded decks, skirts, rails, girders and supports, one draw per
//  culling chunk, one pipeline for everything:
//    trim sheets   4-layer 2D arrays: tangent normal (ASTC, x in rgb,
//                  y in alpha) + ORM (AO, roughness, metal, rime
//                  receptivity in alpha), tiling world-aligned on the
//                  decks, strips along rails / pipes / girders
//    uv1 AO        the pieces' baked ambient occlusion atlas
//    vertex        sRGB tint + metal, HDR emissive (the light strips),
//                  flags: snow drifts, ice, hazard stripes, chamfers
//                  (worn bright edges that catch the flashlight),
//                  frost receptivity, paint
//    world mask    R frost (rime on grating bars / rims near edges,
//                  subtle), G contact AO (railings, crates, pillars)
//    occupancy     (WP2, when bound; High) R contact shadow of the
//                  swarm and squad, G wet ichor → glossy dark decals
//  Lighting: Lighting.h (standardLight + the flashlight shadow); the
//  output is linear radiance through Common.h's encodeColor (fog).
//  Tiered: kLevelHigh adds the occupancy / wet decals and the ice
//  rim; Efficient drops them (RenderQuality).
//  Also here: vs_static / fs_textured / fs_basic_textured (pad mark,
//  floor light pools) and fs_props (the batch service's lit vertex-
//  colour material: squad, turret, medkits — MetalRenderer).
// ================================================================
#include "Common.h"
#include "Lighting.h"

TIER_CONSTANT(kLevelHigh);

// Swift: Level/KitStore.swift KitVertex (40 bytes)
struct KitVertex {
    packed_float3 pos;
    char4 nrm;          // snorm xyz
    char4 tan;          // snorm xyz, w = ±127 bitangent sign
    packed_float2 uv0;  // trim uv (v down)
    ushort2 uv1;        // AO atlas, unorm16
    uchar4 tint;        // sRGB rgb, a = metal
    uchar4 extra;       // x emissive*32, y layer (255 none), z flags, w AO strength
};

// Swift: Level/WorldLevel.swift LevelParams
struct LevelParams {
    float4 lift;     // x = vertical offset of this draw (the lift's rise)
    float4 look;     // x rime strength, y contact-AO strength, z chamfer wear, w snow albedo
    float4 occ;      // occupancy map: xy world origin (x, z), z = 1 / size (m), w = 1 bound
    float4 mask;     // world mask: xy world origin, z = 1 / size, w unused
};

#define KF_SNOW 1u
#define KF_ICE 2u
#define KF_HAZARD 4u
#define KF_CHAMFER 8u
#define KF_FROST 16u
#define KF_STRIP 32u
#define KF_PAINT 64u

struct KitOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float4 tangent;
    float2 uv0;
    float2 uv1;
    float3 albedo;
    float  metal;
    float  emis;
    float  aoK;
    float  depth;
    uint   layer [[flat]];
    uint   flags [[flat]];
};

static inline float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= float3(0.04045));
}

static inline KitOut kitOut(constant Frame& F, KitVertex v, float3 w, float3 n, float3 t, float3 albedo) {
    KitOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.world = w;
    o.normal = n;
    o.tangent = float4(t, v.tan.w < 0 ? -1.0 : 1.0);
    o.uv0 = float2(v.uv0);
    o.uv1 = float2(v.uv1) / 65535.0;
    o.albedo = albedo;
    o.metal = float(v.tint.w) / 255.0;
    o.emis = float(v.extra.x) / 32.0;
    o.layer = uint(v.extra.y);
    o.flags = uint(v.extra.z);
    o.aoK = float(v.extra.w) / 255.0;
    o.depth = -(F.view * float4(w, 1.0)).z;
    return o;
}

/// The merged station (world-space vertices; LevelParams.lift.x raises the lift deck during the extraction).
vertex KitOut vs_kit(uint vid [[vertex_id]],
                     const device KitVertex* V [[buffer(0)]],
                     constant Frame& F [[buffer(1)]],
                     constant LevelParams& P [[buffer(3)]]) {
    KitVertex v = V[vid];
    float3 w = float3(v.pos) + float3(0.0, P.lift.x, 0.0);
    float3 n = float3(v.nrm.xyz) / 127.0;
    float3 t = float3(v.tan.xyz) / 127.0;
    return kitOut(F, v, w, n, t, srgbToLinear(float3(v.tint.rgb) / 255.0));
}

/// Instanced kit pieces that move (the beacon heads): MeshInstance.model places them, KF_PAINT faces take the
/// instance's linear colour (the beacon state).
vertex KitOut vs_kit_inst(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device KitVertex* V [[buffer(0)]],
                          constant Frame& F [[buffer(1)]],
                          const device MeshInstance* I [[buffer(2)]]) {
    KitVertex v = V[vid];
    MeshInstance inst = I[iid];
    float3 w = (inst.model * float4(float3(v.pos), 1.0)).xyz;
    float3 n = normalize((inst.model * float4(float3(v.nrm.xyz) / 127.0, 0.0)).xyz);
    float3 t = normalize((inst.model * float4(float3(v.tan.xyz) / 127.0, 0.0)).xyz);
    float3 albedo = srgbToLinear(float3(v.tint.rgb) / 255.0);
    if ((uint(v.extra.z) & KF_PAINT) != 0u) albedo = inst.tint.rgb;
    return kitOut(F, v, w, n, t, albedo);
}

/// Diagonal amber / black hazard paint (analytic, anti-aliased).
static inline float3 hazardPaint(float3 world) {
    float s = (world.x + world.z) * 1.25;
    float fw = max(fwidth(s), 1e-4);
    float stripe = smoothstep(0.5 - fw, 0.5 + fw, abs(fract(s) - 0.5) * 2.0);
    return mix(float3(0.012, 0.012, 0.014), float3(1.0, 0.37, 0.01) * 0.42, stripe);
}

fragment float4 fs_level(KitOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant LevelParams& P [[buffer(3)]],
                         texture2d<float> worldMask [[texture(1)]],
                         depth2d<float> shadowMap [[texture(3)]],
                         texture2d_array<float> trimN [[texture(8)]],
                         texture2d_array<float> trimORM [[texture(9)]],
                         texture2d<float> aoAtlas [[texture(10)]],
                         texture2d<float> occupancy [[texture(11)]]) {
    float3 Nv = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 N = Nv;
    float3 albedo = in.albedo;
    float ao = 1.0, rough = 0.6, metal = in.metal, rimeK = 0.55;
    uint fl = in.flags;
    if (in.layer < 4u) {
        float4 tn = trimN.sample(repeatSampler, in.uv0, in.layer);
        float4 om = trimORM.sample(repeatSampler, in.uv0, in.layer);
        float2 xy = float2(tn.r, tn.a) * 2.0 - 1.0;
        float3 tsn = float3(xy, sqrt(saturate(1.0 - dot(xy, xy))));
        float3 T = in.tangent.xyz - Nv * dot(in.tangent.xyz, Nv);
        T = length_squared(T) > 1e-8 ? normalize(T) : float3(1.0, 0.0, 0.0);
        float3 B = cross(Nv, T) * in.tangent.w;
        N = normalize(T * tsn.x + B * tsn.y + Nv * tsn.z);
        ao = om.r;
        rough = om.g;
        metal *= om.b;
        rimeK = om.a;
    }
    if (in.aoK > 0.0) ao *= mix(1.0, aoAtlas.sample(clampSampler, in.uv1).r, in.aoK);
    float2 mk = worldMask.sample(dataSampler, (in.world.xz - P.mask.xy) * P.mask.z).rg;
    if ((fl & KF_CHAMFER) != 0u) {
        // worn bright paint / bare steel on every bevel: the flashlight draws a crisp line along each edge
        albedo = mix(albedo, max(albedo * 1.6, float3(0.16, 0.18, 0.2)), P.look.z);
        rough *= 0.7;
    }
    if ((fl & KF_HAZARD) != 0u) {
        albedo = hazardPaint(in.world);
        metal = 0.1;
        rough = max(rough, 0.55);
    }
    if ((fl & KF_SNOW) != 0u) {
        albedo = float3(0.84, 0.9, 1.0) * P.look.w;
        rough = 0.9;
        metal = 0.0;
        N = Nv;
    }
    if ((fl & KF_ICE) != 0u) {
        albedo = float3(0.05, 0.08, 0.11);
        rough = 0.1;
        metal = 0.0;
    }
    if ((fl & KF_FROST) != 0u) {
        // rime: only where the world mask says frost AND the trim says "top of a bar / rim", on up-facing surfaces
        float rime = saturate(mk.r * 1.5 - 0.35) * rimeK * smoothstep(0.55, 0.92, N.y) * P.look.x;
        albedo = mix(albedo, float3(0.42, 0.48, 0.56), rime);
        rough = mix(rough, 0.72, rime);
        metal = mix(metal, 0.0, rime);
    }
    // contact shading near railings, crates and pillars (decks only)
    ao *= mix(1.0, mk.g, saturate(Nv.y) * P.look.y);
    if (kLevelHigh && P.occ.w > 0.5) {
        float2 o = occupancy.sample(dataSampler, (in.world.xz - P.occ.xy) * P.occ.z).rg;
        float up = saturate(Nv.y);
        ao *= 1.0 - 0.55 * o.r * up;
        float wet = o.g * up;
        rough = mix(rough, 0.08, wet);
        albedo *= 1.0 - 0.45 * wet;
    }
    float sh = spotShadow(F, shadowMap, in.world);
    float3 c = standardLight(F, in.world, N, V, albedo, rough, metal, sh) * ao;
    if (kLevelHigh && (fl & KF_ICE) != 0u) {
        // ice: a cold fresnel rim from the sky so icicle fringes read against the abyss
        float fr = pow(1.0 - saturate(dot(Nv, V)), 4.0);
        c += float3(0.35, 0.6, 0.85) * fr * (F.hemiSky.rgb * PI_F) * 0.8;
    }
    c += in.albedo * in.emis;
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

// ---------------------------------------------------------------- legacy IHM1 helpers (pad mark, light pools, batches)
// world-placed geometry; material.floor.z lifts the lift deck during the extraction
vertex MeshOut vs_static(MeshIn v [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant Material& M [[buffer(3)]]) {
    float3 w = v.position + float3(0.0, M.floor.z, 0.0);
    return meshOut(F, w, v.normal, v.color, v.glow, v.leg.xy, float3(0.0));
}

/// makeGlowMaterial: vertex colours, aGlow emissive, optional snow caps (the batch service: marines, turret, medkit)
fragment float4 fs_props(MeshOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant Material& M [[buffer(3)]],
                         depth2d<float> shadowMap [[texture(3)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 albedo = in.color;
    if (M.pbr.z > 0.5) {
        albedo = mix(albedo, float3(0.80, 0.86, 0.93), smoothstep(0.72, 0.97, N.y) * (1.0 - in.glow) * 0.8);
    }
    float sh = M.floor.w > 0.5 ? spotShadow(F, shadowMap, in.world) : 1.0;
    float3 c = standardLight(F, in.world, N, V, albedo, M.pbr.x, M.pbr.y, sh);
    c += in.color * in.glow * M.pbr.w + in.extra;
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

/// textured standard material (the landing-pad mark with its alpha)
fragment float4 fs_textured(MeshOut in [[stage_in]],
                            constant Frame& F [[buffer(1)]],
                            constant Material& M [[buffer(3)]],
                            texture2d<float> map [[texture(0)]],
                            depth2d<float> shadowMap [[texture(3)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float4 t = map.sample(repeatSampler, in.uv);
    float sh = M.floor.w > 0.5 ? spotShadow(F, shadowMap, in.world) : 1.0;
    float3 c = standardLight(F, in.world, N, V, t.rgb * in.color, M.pbr.x, M.pbr.y, sh);
    return float4(encodeColor(F, c, in.depth, true), t.a);
}

/// floor light pools (additive, unlit, no fog)
fragment float4 fs_basic_textured(MeshOut in [[stage_in]],
                                  constant Frame& F [[buffer(1)]],
                                  texture2d<float> map [[texture(0)]]) {
    float4 t = map.sample(clampSampler, in.uv);
    return float4(encodeColor(F, t.rgb * in.color, in.depth, false), t.a);
}
