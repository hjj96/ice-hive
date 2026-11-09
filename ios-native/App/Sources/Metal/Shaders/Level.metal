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
    float4 misc;     // x = 1 on the High tier, y = 1: the -deckMask look-dev view
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
    if (P.misc.y > 0.5) {
        // -deckMask (look-dev): the walkable deck tops (WorldLevel tints them pure green) flat green, the snow drifts
        // blue, the icicles red, the rest black (a script checks the deck's luma and that no snow lies past a rail)
        bool deck = all(abs(in.albedo - float3(0.0, 1.0, 0.0)) < float3(0.002));
        float3 c = deck ? float3(0.0, 0.6, 0.0) : float3(0.0);
        if ((in.flags & KF_SNOW) != 0u) c = float3(0.0, 0.0, 0.6);
        if ((in.flags & KF_ICE) != 0u) c = float3(0.6, 0.0, 0.0);
        return float4(c, 1.0);
    }
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
    float3 mk3 = worldMask.sample(dataSampler, (in.world.xz - P.mask.xy) * P.mask.z).rgb;
    float2 mk = mk3.rg;
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
        // wind-packed snow: faint, irregular ripples across the wind (≈ 0.55 m apart, warped by two slow waves, their
        // strength swelling and dying along the drift) tilt the normal a little and shade the albedo by a few percent,
        // so a lamp or a flashlight shows a drift's surface instead of a smooth pillow — never regular stripes, no
        // sparkle (frost's glitter is out). They fade to the plain mound where a ripple would be under ~3 px.
        float2 wp = in.world.xz;
        float warp = 0.55 * sin(dot(wp, float2(-0.55, 0.83)) * 1.1) + 0.3 * sin(dot(wp, float2(0.31, 0.95)) * 2.3 + 1.7);
        float ph = dot(wp, float2(0.83, 0.55)) * 1.8 + warp;
        float amp = 0.5 + 0.5 * sin(dot(wp, float2(0.2, -0.9)) * 0.9 + 0.4);
        float fade = (1.0 - saturate(fwidth(ph) * 3.0 - 0.5)) * amp;
        float s = sin(ph * 6.2832), c = cos(ph * 6.2832);
        float3 wind = float3(0.83, 0.0, 0.55);
        albedo = float3(0.84, 0.9, 1.0) * P.look.w * (1.0 - 0.05 * fade * (0.5 - 0.5 * s));
        // the outline: the snow thins out toward the drift's edge (in.uv0.y = height above its base, KitMesh.place) so
        // the dark painted grating shows through a dusting instead of a hard pill edge; the world mask's frost noise
        // breaks the line up
        float thin = 1.0 - smoothstep(0.0, 0.5, saturate(in.uv0.y) + 0.3 * (mk.r - 0.5));
        albedo = mix(albedo, float3(0.09, 0.11, 0.14), thin * 0.8);
        rough = 0.9;
        metal = 0.0;
        N = normalize(Nv + wind * (0.13 * c * fade * saturate(Nv.y)));
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
        if ((fl & KF_PAINT) != 0u) {
            // a crust of snow on the painted props' tops (crates): the drift's snow, broken up by the world mask's
            // noise so no two lids match; lit only where a beam or a lamp reaches it
            float cap = smoothstep(0.9, 0.985, Nv.y) * saturate(mk.r * 2.4 - 1.0) * P.look.x;
            albedo = mix(albedo, float3(0.84, 0.9, 1.0) * P.look.w, cap);
            rough = mix(rough, 0.9, cap);
            metal = mix(metal, 0.0, cap);
            N = normalize(mix(N, Nv, cap));
        }
    }
    // contact shading near railings, crates and pillars (decks only)
    ao *= mix(1.0, mk.g, saturate(Nv.y) * P.look.y);
    // Stage 1 R3: the overhead's soft moon shadow on the deck (the world mask's B, baked by WorldOverhead along the moon
    // direction under every route; 0 on a station without routes — the classic «Кельвин-9» is unchanged): the sky is
    // partly blocked there, so the ambient and the moonlit albedo dim a little
    if (mk3.b > 0.0) {
        float sh = mk3.b * saturate(Nv.y);
        ao *= 1.0 - 0.5 * sh;
        albedo *= 1.0 - 0.3 * sh;
    }
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
        // the edge strip's cyan carried down the ice (light-piping): a faint fringe of cyan slivers under each lip,
        // so the icicles read against the abyss at phone size without a light of their own
        c += float3(0.012, 0.075, 0.1) * (0.6 + fr);
        if (high) c += float3(0.02, 0.09, 0.12) * fr;
    }
    c += in.albedo * in.emis;
#if defined(LIGHTING_PARAMS)
    return float4(heightFog(F, LB, c, in.world, in.depth), 1.0);
#else
    return float4(encodeColor(F, c, in.depth, true), 1.0);
#endif
}

// ---------------------------------------------------------------- the overhead (Stage 1 R3, Level/WorldOverhead.swift)
// The routes above the decks (racks, cables, trays, catwalks, ducts, their supports, the upper truss) are KitVertex
// geometry like the station, drawn by two pipelines: `overhead` (vs_overhead + fs_overhead) for the chunks away from the
// squad — one opaque draw, so the hidden-surface removal keeps the deck pixels it covers from being shaded — and
// `overheadCut` (vs_overhead + fs_overhead_cut) for the chunks near a marine, a drop warning or the eye: the same material
// with the cutaway written as MSAA sample coverage (a 4×4 Bayer-dithered alpha-to-coverage: 25 % of the samples at the
// ghost floor read as a 25 % ghost after the resolve, not a screen door). Drawn last among the opaque items. The look:
// the darker grade (a dark foreground plane: desaturated, cooled toward the void, darker), rime and a snow crust on every
// up-facing top (the layer reads as pale lines from above), the station's light model and fog.

// Swift: WorldOverhead.swift OverheadBlock (85 float4)
struct OverheadParams {
    float4 look;       // x rime strength, y snow-crust strength, z albedo grade (×), w desaturation
    float4 misc;       // x = 1 on the High tier, y unused, z time (s), w unused
    float4 mask;       // world mask: xy world origin, z = 1 / size
    float4 view;       // x = 2 / viewport width (px), y = 2 / viewport height (px), z = aspect, w = ghost floor (0…1)
    float4 cut;        // x near-eye fade start (m: nothing nearer), y its end (m), z cut points in use, w depth margin (m)
    float4 pts[8];     // cut points: xy on screen (half screen heights, x × aspect), z view depth (m), w weight 0…1
    float4 rad[8];     // x radius of the full ghost, y radius where the fade ends (half screen heights)
    float4 sway[64];   // cable k's displacement this frame (m), × the vertex's mid-span weight
};

/// 4×4 Bayer thresholds (× 1/16).
constant float kOverheadBayer[16] = { 0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0 };

/// A cable vertex sways with its cable: runtime faces carry no AO (extra.w = 0), so a cable's uv1 holds its mid-span
/// weight (x, unorm16) and its cable index + 1 (y); kit pieces (AO-baked, extra.w > 0) and every other face never move.
static inline float3 overheadSway(constant OverheadParams& P, KitVertex v) {
    if (v.extra.w != 0 || v.uv1.y == 0) return float3(0.0);
    uint k = min(uint(v.uv1.y) - 1u, 63u);
    return P.sway[k].xyz * (float(v.uv1.x) / 65535.0);
}

vertex KitOut vs_overhead(uint vid [[vertex_id]],
                          const device KitVertex* V [[buffer(0)]],
                          constant Frame& F [[buffer(1)]],
                          constant OverheadParams& P [[buffer(3)]]) {
    KitVertex v = V[vid];
    float3 w = float3(v.pos) + overheadSway(P, v);
    float3 n = float3(v.nrm.xyz) / 127.0;
    float3 t = float3(v.tan.xyz) / 127.0;
    float3 albedo = srgbToLinear(float3(v.tint.rgb) / 255.0);
    if (v.extra.x == 0) {
        // the darker grade (tech.md §2.5): the overhead is a dark foreground plane over the lit deck — desaturated, a
        // touch cooler, darker; the self-lit accents (duct-mouth slats, the catwalk strip, gauges) keep their colour
        float l = dot(albedo, float3(0.2126, 0.7152, 0.0722));
        albedo = mix(albedo, float3(l), P.look.w) * float3(0.92, 0.97, 1.08) * P.look.z;
    }
    return kitOut(F, v, w, n, t, albedo);
}

/// Smooth value noise (the snow crust's breakup, ~1.6 m).
static inline float overheadHash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
static inline float overheadNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = overheadHash(i), b = overheadHash(i + float2(1.0, 0.0));
    float c = overheadHash(i + float2(0.0, 1.0)), d = overheadHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// The overhead's material: trims and the kit pieces' AO as on the station, worn chamfers, rime and the snow crust on
/// the up-facing tops, the full light model (flashlights, grid lights from the lamps below, moon, probe), fog.
static float3 overheadShade(KitOut in, constant Frame& F, constant OverheadParams& P, texture2d<float> worldMask,
                            texture2d_array<float> trimN, texture2d_array<float> trimORM, texture2d<float> aoAtlas,
                            constant LightBlock& LB, depth2d<float> shadowAtlas, texturecube<half> envProbe,
                            texture2d<half> occupancy) {
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
    float frost = worldMask.sample(dataSampler, (in.world.xz - P.mask.xy) * P.mask.z).r;
    if ((fl & KF_CHAMFER) != 0u) {
        // worn edges catch the beams: a thin bright line along each bevel (subtler than the deck's)
        albedo = mix(albedo, max(albedo * 1.6, float3(0.08, 0.09, 0.1)), 0.45);
        rough *= 0.75;
    }
    if ((fl & KF_FROST) != 0u) {
        // rime on the bars and rims (the trim's receptivity), then the snow crust on every up-facing top: pale lines
        // from above that read over the dark deck and against the void (concept-station README, «what makes the layer
        // readable»), broken up by a slow noise so a run is not one flat white line
        float up = smoothstep(0.55, 0.92, N.y);
        float rime = saturate(frost * 1.4 - 0.2) * saturate(rimeK * 1.6) * up * P.look.x;
        albedo = mix(albedo, float3(0.32, 0.37, 0.44), rime);
        rough = mix(rough, 0.72, rime);
        metal = mix(metal, 0.0, rime);
        float crust = smoothstep(0.66, 0.96, Nv.y) * (0.55 + 0.45 * overheadNoise(in.world.xz * 0.62 + in.world.y)) * P.look.y;
        albedo = mix(albedo, float3(0.46, 0.5, 0.56), crust);
        rough = mix(rough, 0.88, crust);
        metal = mix(metal, 0.0, crust);
        N = normalize(mix(N, Nv, crust));
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
    float3 c = shadeLit(F, LB, shadowAtlas, envProbe, occupancy, s, high);
    c += in.albedo * in.emis;
    return heightFog(F, LB, c, in.world, in.depth);
}

/// The cutaway's alpha (1 = solid) of an overhead fragment at window position `px` (pixels), view depth `depth` (m): it
/// fades to the ghost floor within rad.x of every cut point it stands in front of (marines' chests, drop-warning rings),
/// back to solid at rad.y; and to nothing near the eye (cinematic cameras).
static float overheadCutAlpha(constant OverheadParams& P, float2 px, float depth) {
    float2 sp = float2((px.x * P.view.x - 1.0) * P.view.z, 1.0 - px.y * P.view.y);
    float cut = 0.0;
    int n = int(P.cut.z);
    for (int k = 0; k < 8; k++) {
        if (k >= n) break;
        float4 q = P.pts[k];
        float2 r = P.rad[k].xy;
        float c = 1.0 - smoothstep(r.x, r.y, distance(sp, q.xy));
        // only what stands between the camera and the point hides it
        c *= q.w * saturate((q.z - depth - P.cut.w) * 1.5);
        cut = max(cut, c);
    }
    float a = 1.0 - (1.0 - P.view.w) * cut;
    return a * smoothstep(P.cut.x, P.cut.y, depth);
}

// ↓ the fragment parameters of both overhead pipelines (as fs_level's)
#define OVERHEAD_FS_PARAMS KitOut in [[stage_in]], constant Frame& F [[buffer(1)]], \
    constant OverheadParams& P [[buffer(3)]], texture2d<float> worldMask [[texture(1)]], \
    texture2d_array<float> trimN [[texture(8)]], texture2d_array<float> trimORM [[texture(9)]], \
    texture2d<float> aoAtlas [[texture(10)]], LIGHTING_PARAMS
#define OVERHEAD_FS_ARGS in, F, P, worldMask, trimN, trimORM, aoAtlas, LB, shadowAtlas, envProbe, occupancy

/// Overhead chunks away from the squad: opaque (the far, dark-graded draw).
fragment float4 fs_overhead(OVERHEAD_FS_PARAMS) {
    return float4(overheadShade(OVERHEAD_FS_ARGS), 1.0);
}

struct OverheadCutOut {
    float4 color [[color(0)]];
    uint mask [[sample_mask]];
};

/// Overhead chunks near a marine / a drop warning / the eye: the cutaway as sample coverage (alpha-to-coverage with a 4×4
/// Bayer dither of the rounding and a per-pixel rotation of the sample set; 0 samples are discarded).
fragment OverheadCutOut fs_overhead_cut(OVERHEAD_FS_PARAMS) {
    OverheadCutOut o;
    o.color = float4(0.0);
    o.mask = 0u;
    float a = overheadCutAlpha(P, in.position.xy, in.depth);
    uint2 q = uint2(in.position.xy) & 3u;
    float b = (kOverheadBayer[q.y * 4u + q.x] + 0.5) / 16.0;
    int n = int(floor(a * 4.0 + b));
    if (n <= 0) {
        discard_fragment();
        return o;
    }
    uint rot = (q.x + q.y * 2u + 1u) & 3u;
    uint m = (1u << uint(min(n, 4))) - 1u;
    o.mask = ((m << rot) | (m >> (4u - rot))) & 15u;
    o.color = float4(overheadShade(OVERHEAD_FS_ARGS), 1.0);
    return o;
}

// ---------------------------------------------------------------- the overhead visibility mask (CI, `-ohVis`)
// An offscreen RGBA8 frame of the game camera (WorldOverhead, a pre-pass): R = 1 on the walkable deck, G = (k + 1) / 5
// on marine k's silhouette proxy, B = the overhead's coverage in front of them (its cutaway alpha; max of the layers).
// The app reads it back and logs how much of the deck the overhead covers and whether any marine is hidden.

/// The deck cells and the marine proxies: world xyz + a code in w (1 deck, 2…5 marine 0…3).
vertex QuadOut vs_overhead_vis_flat(uint vid [[vertex_id]],
                                    const device float4* V [[buffer(0)]],
                                    constant Frame& F [[buffer(1)]]) {
    float4 v = V[vid];
    QuadOut o;
    o.position = F.viewProj * float4(v.xyz, 1.0);
    o.color = v.w < 1.5 ? float4(1.0, 0.0, 0.0, 1.0) : float4(0.0, (v.w - 1.0) * 0.2, 0.0, 1.0);
    o.uv = float2(0.0);
    o.params = float4(0.0);
    o.depth = 0.0;
    return o;
}

fragment float4 fs_overhead_vis_flat(QuadOut in [[stage_in]]) {
    return in.color;
}

/// The overhead in the visibility mask: B = its cutaway alpha (the far chunks come out solid: no cut point near them).
fragment float4 fs_overhead_vis(KitOut in [[stage_in]], constant OverheadParams& P [[buffer(3)]]) {
    return float4(0.0, 0.0, overheadCutAlpha(P, in.position.xy, in.depth), 0.0);
}

// ---------------------------------------------------------------- legacy IHM1 helpers (pad mark, light pools, batches)
// world-placed geometry; material.floor.z lifts the lift deck during the extraction
vertex MeshOut vs_static(MeshIn v [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant Material& M [[buffer(3)]]) {
    float3 w = v.position + float3(0.0, M.floor.z, 0.0);
    return meshOut(F, w, v.normal, v.color, v.glow, v.leg.xy, float3(0.0));
}

/// makeGlowMaterial: vertex colours, aGlow emissive, optional snow caps (the batch service: marines, turret, medkit) —
/// on WP2's full light model (grid lights, the four spots' atlas shadows, probe, contact AO, height fog) when present.
fragment float4 fs_props(MeshOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant Material& M [[buffer(3)]]
                         LEVEL_LIGHT_PARAMS) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 albedo = in.color;
    if (M.pbr.z > 0.5) {
        albedo = mix(albedo, float3(0.80, 0.86, 0.93), smoothstep(0.72, 0.97, N.y) * (1.0 - in.glow) * 0.8);
    }
#if defined(LIGHTING_PARAMS)
    LitSurface s;
    s.P = in.world; s.N = N; s.V = V; s.albedo = albedo; s.rough = M.pbr.x; s.metal = M.pbr.y;
    s.coat = 0.0; s.coatRough = 0.3; s.ao = 1.0; s.shadow = M.floor.w;
    float3 c = shadeLit(LIGHTING_ARGS, s, LB.info.y > 0.5);
    c += in.color * in.glow * M.pbr.w + in.extra;
    return float4(heightFog(F, LB, c, in.world, in.depth), 1.0);
#else
    float sh = M.floor.w > 0.5 ? spotShadow(F, shadowMap, in.world) : 1.0;
    float3 c = standardLight(F, in.world, N, V, albedo, M.pbr.x, M.pbr.y, sh);
    c += in.color * in.glow * M.pbr.w + in.extra;
    return float4(encodeColor(F, c, in.depth, true), 1.0);
#endif
}

/// textured standard material (the landing-pad mark with its alpha), lit like the deck under it
fragment float4 fs_textured(MeshOut in [[stage_in]],
                            constant Frame& F [[buffer(1)]],
                            constant Material& M [[buffer(3)]],
                            texture2d<float> map [[texture(0)]]
                            LEVEL_LIGHT_PARAMS) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float4 t = map.sample(repeatSampler, in.uv);
#if defined(LIGHTING_PARAMS)
    LitSurface s;
    s.P = in.world; s.N = N; s.V = V; s.albedo = t.rgb * in.color; s.rough = M.pbr.x; s.metal = M.pbr.y;
    s.coat = 0.0; s.coatRough = 0.3; s.ao = 1.0; s.shadow = 1.0;
    float3 c = shadeLit(LIGHTING_ARGS, s, LB.info.y > 0.5);
    return float4(heightFog(F, LB, c, in.world, in.depth), t.a);
#else
    float sh = M.floor.w > 0.5 ? spotShadow(F, shadowMap, in.world) : 1.0;
    float3 c = standardLight(F, in.world, N, V, t.rgb * in.color, M.pbr.x, M.pbr.y, sh);
    return float4(encodeColor(F, c, in.depth, true), t.a);
#endif
}

/// floor light pools (additive, unlit, no fog)
fragment float4 fs_basic_textured(MeshOut in [[stage_in]],
                                  constant Frame& F [[buffer(1)]],
                                  texture2d<float> map [[texture(0)]]) {
    float4 t = map.sample(clampSampler, in.uv);
    return float4(encodeColor(F, t.rgb * in.color, in.depth, false), t.a);
}
