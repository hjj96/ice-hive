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
//  Lighting: WP2's full model when Lighting.h has it (shadeLit: light
//  grid, atlas shadows, probe, occupancy contact AO; High: the wet
//  trails of the occupancy map; heightFog), else the frame-only API
//  (standardLight + the flashlight shadow, encodeColor's fog).
//  One pipeline for both tiers: LevelParams.misc.x = 1 on High adds
//  the wet trails and the ice rim (and the grid lights' specular in
//  shadeLit) — a uniform branch; a function-constant variant would
//  cost a second ~0.4 s compile behind the loading cover.
//  The beacon heads are part of the station buffer (KF_HEAD vertices):
//  vs_kit spins them about their pivot and paints the lens in the
//  beacon's state colour from a small per-frame table (buffer 2).
//  Also here: vs_static / fs_textured / fs_basic_textured (pad mark,
//  floor light pools) and fs_props (the batch service's lit vertex-
//  colour material: squad, turret, medkits — MetalRenderer).
// ================================================================
#include "Common.h"
#include "Lighting.h"

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
    float4 misc;     // x = 1 on the High tier
    float4 mask;     // world mask: xy world origin, z = 1 / size, w unused
};

/// Beacon heads (WorldLevel.headTable, 8 heads): pivot xyz + yaw, then the lens colour (linear rgb).
#define LEVEL_HEADS 8
struct LevelHeads {
    float4 pivot[LEVEL_HEADS];
    float4 color[LEVEL_HEADS];
};

#define KF_SNOW 1u
#define KF_ICE 2u
#define KF_HAZARD 4u
#define KF_CHAMFER 8u
#define KF_FROST 16u
#define KF_STRIP 32u
#define KF_PAINT 64u
#define KF_HEAD 128u    // a beacon head vertex: extra.w = head index (no AO atlas)

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
    o.aoK = (uint(v.extra.z) & KF_HEAD) != 0u ? 0.0 : float(v.extra.w) / 255.0;
    o.depth = -(F.view * float4(w, 1.0)).z;
    return o;
}

static inline float3 spinY(float3 v, float c, float s) { return float3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z); }

/// The merged station (world-space vertices; LevelParams.lift.x raises the lift deck during the extraction). Beacon
/// head vertices (KF_HEAD) turn about their head's pivot by its yaw and take its state colour on the lens (KF_PAINT).
vertex KitOut vs_kit(uint vid [[vertex_id]],
                     const device KitVertex* V [[buffer(0)]],
                     constant Frame& F [[buffer(1)]],
                     constant LevelHeads& H [[buffer(2)]],
                     constant LevelParams& P [[buffer(3)]]) {
    KitVertex v = V[vid];
    float3 w = float3(v.pos);
    float3 n = float3(v.nrm.xyz) / 127.0;
    float3 t = float3(v.tan.xyz) / 127.0;
    float3 albedo = srgbToLinear(float3(v.tint.rgb) / 255.0);
    uint fl = uint(v.extra.z);
    if ((fl & KF_HEAD) != 0u) {
        uint k = min(uint(v.extra.w), uint(LEVEL_HEADS - 1));
        float4 pv = H.pivot[k];
        float c = cos(pv.w), s = sin(pv.w);
        w = pv.xyz + spinY(w - pv.xyz, c, s);
        n = spinY(n, c, s);
        t = spinY(t, c, s);
        if ((fl & KF_PAINT) != 0u) albedo = H.color[k].rgb;
    }
    w.y += P.lift.x;
    return kitOut(F, v, w, n, t, albedo);
}

/// Station shadow casters (crates, pillars, beacon masts, lamp posts: WorldLevel's caster index list) into the spot
/// tile the shadow pass has bound (F.shadowMatrix).
vertex ShadowOut vs_shadow_kit(uint vid [[vertex_id]],
                               const device KitVertex* V [[buffer(0)]],
                               constant Frame& F [[buffer(1)]]) {
    ShadowOut o;
    o.position = F.shadowMatrix * float4(float3(V[vid].pos), 1.0);
    return o;
}

/// Diagonal amber / black hazard paint (analytic, anti-aliased).
static inline float3 hazardPaint(float3 world) {
    float s = (world.x + world.z) * 1.25;
    float fw = max(fwidth(s), 1e-4);
    float stripe = smoothstep(0.5 - fw, 0.5 + fw, abs(fract(s) - 0.5) * 2.0);
    return mix(float3(0.012, 0.012, 0.014), float3(1.0, 0.37, 0.01) * 0.42, stripe);
}

// fs_level lights through WP2's full light model when Lighting.h provides it (LIGHTING_PARAMS: light grid, 4-spot
// atlas shadows, environment probe, occupancy contact AO and trails, height fog), else through the frame-only API.
#if defined(LIGHTING_PARAMS)
#define LEVEL_LIGHT_PARAMS , LIGHTING_PARAMS
#else
#define LEVEL_LIGHT_PARAMS , depth2d<float> shadowMap [[texture(3)]]
#endif

fragment float4 fs_level(KitOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant LevelParams& P [[buffer(3)]],
                         texture2d<float> worldMask [[texture(1)]],
                         texture2d_array<float> trimN [[texture(8)]],
                         texture2d_array<float> trimORM [[texture(9)]],
                         texture2d<float> aoAtlas [[texture(10)]]
                         LEVEL_LIGHT_PARAMS) {
    float3 Nv = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 N = Nv;
    float3 albedo = in.albedo;
    float ao = 1.0, rough = 0.6, metal = in.metal, rimeK = 0.55;
    uint fl = in.flags;
    bool high = P.misc.x > 0.5;
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
        // clear blue ice: light enough to catch the flashlight and the strip above it against the abyss
        albedo = float3(0.22, 0.32, 0.42);
        rough = 0.12;
        metal = 0.0;
    }
    if ((fl & KF_FROST) != 0u) {
        // rime: only where the world mask says frost AND the trim says "top of a bar / rim", on up-facing surfaces
        float rime = saturate(mk.r * 1.7 - 0.35) * saturate(rimeK * 1.6) * smoothstep(0.55, 0.92, N.y) * P.look.x;
        albedo = mix(albedo, float3(0.46, 0.52, 0.6), rime);
        rough = mix(rough, 0.72, rime);
        metal = mix(metal, 0.0, rime);
    }
    // contact shading near railings, crates and pillars (decks only)
    ao *= mix(1.0, mk.g, saturate(Nv.y) * P.look.y);
#if defined(LIGHTING_PARAMS)
    if (high) {
        // fresh ichor / meltwater trails from the occupancy map: glossy, darker deck
        float wet = float(occupancyAt(LB, occupancy, in.world).g) * saturate(Nv.y);
        rough = mix(rough, 0.08, wet);
        albedo *= 1.0 - 0.45 * wet;
    }
    LitSurface s;
    s.P = in.world;
    s.N = N;
    s.V = V;
    s.albedo = albedo;
    s.rough = rough;
    s.metal = metal;
    s.coat = 0.0;
    s.coatRough = 0.1;
    s.ao = ao;
    s.shadow = 1.0;
    float3 c = shadeLit(LIGHTING_ARGS, s, high);
#else
    float sh = spotShadow(F, shadowMap, in.world);
    float3 c = standardLight(F, in.world, N, V, albedo, rough, metal, sh) * ao;
#endif
    if ((fl & KF_ICE) != 0u) {
        // ice: a cold fresnel rim from the sky (both tiers: icicle fringes must read against the abyss) and, on
        // High, a faint cyan glint of the edge strip just above them
        float fr = pow(1.0 - saturate(dot(Nv, V)), 3.0);
        c += float3(0.35, 0.6, 0.85) * fr * (F.hemiSky.rgb * PI_F) * 1.2;
        if (high) c += float3(0.02, 0.09, 0.12) * fr;
    }
    c += in.albedo * in.emis;
#if defined(LIGHTING_PARAMS)
    return float4(heightFog(F, LB, c, in.world, in.depth), 1.0);
#else
    return float4(encodeColor(F, c, in.depth, true), 1.0);
#endif
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
