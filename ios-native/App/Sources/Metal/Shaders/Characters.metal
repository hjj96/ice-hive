// ================================================================
//  CHARACTERS (owned by WP4 «Отряд»):
//   • the skinned marines — vs_marine (32-byte IHV1 skinned vertices
//     read by vertex id, up to 4 bones from the rig's palette: 3 float4
//     rows per bone, world space, MarineRig.swift) → fs_marine on WP2's
//     full light model: baked tangent-space normals + AO / roughness /
//     metal / paint mask from the class texture arrays, worn steel on
//     painted chamfers, the class hue on painted markings, the visor
//     and trim strips glowing in the class hue (HDR, they bloom), a
//     faint class-hue rim so the squad reads in the dark, hurt /
//     invulnerable flashes, the downed dimming; the shooter lit by
//     his own muzzle flash (a short-range point light at the muzzle
//     socket) and barrels / nozzles glowing with heat under sustained
//     fire (vertex flag bit3);
//     vs_marine_shadow draws them into the flashlight shadow atlas;
//   • the weapon flashes — vs_muzzle_flash / fs_muzzle_flash, one
//     additive instanced draw for the squad: per firing weapon two
//     flame planes along the barrel (rolled per shot), a camera-facing
//     star and a disc across the bore, at the rig's muzzle socket, in
//     the class's flash colour (rifle: a red-orange X star; rotary: a
//     big yellow six-ray flicker; flamer: the blue pilot flame, a hot
//     orange nozzle cone while it fires; cryo: a six-pointed ice star);
//   • the batch service's instanced meshes (turret, medkits, corpses):
//     vs_mesh with a per-instance model matrix + tint + emissive;
//     corpses are Lambert with the instance colour, globs / grenades /
//     beacon tips unlit; vs_shadow_mesh is their shadow caster. Props
//     shade with fs_props (Level.metal).
// ================================================================
#include "Common.h"
#include "Lighting.h"

vertex MeshOut vs_mesh(MeshIn v [[stage_in]],
                       uint iid [[instance_id]],
                       constant Frame& F [[buffer(1)]],
                       const device MeshInstance* I [[buffer(2)]]) {
    MeshInstance m = I[iid];
    float3 w = (m.model * float4(v.position, 1.0)).xyz;
    float3 n = normalize((m.model * float4(v.normal, 0.0)).xyz);
    float3 col = mix(v.color * m.tint.rgb, m.tint.rgb, m.emissive.w);
    return meshOut(F, w, n, col, v.glow, v.leg.xy, m.emissive.rgb);
}

/// corpses: Lambert with the instance colour
fragment float4 fs_lambert(MeshOut in [[stage_in]],
                           constant Frame& F [[buffer(1)]],
                           constant Material& M [[buffer(3)]],
                           depth2d<float> shadowMap [[texture(3)]]) {
    float3 N = normalize(in.normal);
    float sh = M.floor.w > 0.5 ? spotShadow(F, shadowMap, in.world) : 1.0;
    float3 c = lambertLight(F, in.world, N, sh) * in.color;
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

/// MeshBasicMaterial (glob, grenade, beacon tip): tone mapped, no fog
fragment float4 fs_unlit(MeshOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]]) {
    return float4(encodeColor(F, in.color, in.depth, false), 1.0);
}

// ================================================================ flashlight shadow map (depth only)
// casters like the web: the squad and, per bug inside the player's flashlight cone, the 20-triangle proxy blob
// (Swarm.metal vs_shadow_proxy); the level itself casts nothing
vertex ShadowOut vs_shadow_mesh(MeshIn v [[stage_in]],
                                uint iid [[instance_id]],
                                constant Frame& F [[buffer(1)]],
                                const device MeshInstance* I [[buffer(2)]]) {
    ShadowOut o;
    o.position = F.shadowMatrix * (I[iid].model * float4(v.position, 1.0));
    return o;
}

// ================================================================ skinned marines
// Swift: MarineRig.swift / WorldSquad.swift. Vertex layout: tools/blender/ihv.py SKINNED_DTYPE (32 bytes).
struct SkinVertex {
    half4 rest;       // xyz bind position (model space)
    char4 nrm;        // snorm xyz, w = flags (bit0 class-hue visor / strip, bit1 emissive, bit2 painted armour,
                      // bit3 heats up with sustained fire: barrels, muzzle, nozzle, emitter)
    char4 tan;        // snorm xyz along +u, w = ±127 bitangent sign
    half2 uv;         // the class's texture layer (top-left origin)
    uchar4 albedo;    // sRGB rgb, a = glow 0…1
    uchar4 bones;
    uchar4 weights;   // sum 255
};

// Swift: WorldSquad.swift MarineDraw (96 bytes)
struct MarineDraw {
    float4 hue;       // rgb class hue (linear), w = visor glow multiplier (the clip's ctrl curve × flicker)
    float4 trim;      // rgb class paint (linear), w = texture layer (class index)
    float4 flash;     // rgb added emissive (hurt / invulnerable), w = downed dimming 0…1
    float4 params;    // x = class rim strength, y = emissive gain, z = lamp gain, w = 1 on the High tier
    float4 muzzle;    // xyz the weapon's muzzle (world), w = its flash as a light on the marine (0 = none)
    float4 fx;        // rgb the flash light's colour (linear), w = barrel / nozzle heat 0…1
};

#define MARINE_PALETTE 2
#define MARINE_DRAW 4
#define MARINE_NORMAL 11
#define MARINE_ORM 12

struct MarineOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float4 tangent;
    float2 uv;
    float3 albedo;
    float  glow;
    float  depth;
    uint   flags [[flat]];
};

static inline float3 skinPoint(const device float4* P, uint b, float4 p) {
    return float3(dot(P[b * 3], p), dot(P[b * 3 + 1], p), dot(P[b * 3 + 2], p));
}

static inline float3 skinDir(const device float4* P, uint b, float3 d) {
    return float3(dot(P[b * 3].xyz, d), dot(P[b * 3 + 1].xyz, d), dot(P[b * 3 + 2].xyz, d));
}

static inline float3 srgbLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= float3(0.04045));
}

vertex MarineOut vs_marine(uint vid [[vertex_id]],
                           const device SkinVertex* V [[buffer(0)]],
                           constant Frame& F [[buffer(1)]],
                           const device float4* P [[buffer(MARINE_PALETTE)]],
                           constant MarineDraw& D [[buffer(MARINE_DRAW)]]) {
    SkinVertex v = V[vid];
    float4 rest = float4(float3(v.rest.xyz), 1.0);
    float3 n0 = float3(v.nrm.xyz) / 127.0;
    float3 t0 = float3(v.tan.xyz) / 127.0;
    float3 p = float3(0.0), n = float3(0.0), t = float3(0.0);
    for (int k = 0; k < 4; k++) {
        float w = float(v.weights[k]) / 255.0;
        if (w <= 0.0) continue;
        uint b = v.bones[k];
        p += skinPoint(P, b, rest) * w;
        n += skinDir(P, b, n0) * w;
        t += skinDir(P, b, t0) * w;
    }
    MarineOut o;
    o.position = F.viewProj * float4(p, 1.0);
    o.world = p;
    o.normal = n;
    o.tangent = float4(t, v.tan.w < 0 ? -1.0 : 1.0);
    o.uv = float2(v.uv);
    o.albedo = srgbLinear(float3(v.albedo.rgb) / 255.0);
    o.glow = float(v.albedo.a) / 255.0;
    o.depth = -(F.view * float4(p, 1.0)).z;
    o.flags = uint(uchar(v.nrm.w));
    return o;
}

fragment float4 fs_marine(MarineOut in [[stage_in]],
                          constant Frame& F [[buffer(1)]],
                          constant MarineDraw& D [[buffer(MARINE_DRAW)]],
                          texture2d_array<half> nrmTex [[texture(MARINE_NORMAL)]],
                          texture2d_array<half> ormTex [[texture(MARINE_ORM)]],
                          LIGHTING_PARAMS) {
    uint layer = uint(D.trim.w + 0.5);
    half4 nt = nrmTex.sample(repeatSampler, in.uv, layer);
    half4 om = ormTex.sample(repeatSampler, in.uv, layer);
    // baked tangent-space normal (ASTC normal mode: x in rgb, y in alpha)
    float2 xy = float2(nt.r, nt.a) * 2.0 - 1.0;
    float3 tn = float3(xy, sqrt(saturate(1.0 - dot(xy, xy))));
    float3 N0 = normalize(in.normal);
    float3 T = in.tangent.xyz - N0 * dot(in.tangent.xyz, N0);
    T = dot(T, T) > 1e-8 ? normalize(T) : float3(1, 0, 0);
    float3 B = cross(N0, T) * in.tangent.w;
    float3 N = normalize(T * tn.x + B * tn.y + N0 * tn.z);
    float3 V = normalize(F.camPos.xyz - in.world);
    float ao = float(om.r), rough = float(om.g), metal = float(om.b), paint = float(om.a);
    // paint mask: 0.5 = light marking, 1 = the class hue; worn chamfers of painted armour show steel
    float3 albedo = in.albedo;
    albedo = mix(albedo, float3(0.48, 0.48, 0.46), smoothstep(0.3, 0.45, paint) * (1.0 - smoothstep(0.62, 0.8, paint)));
    albedo = mix(albedo, D.trim.rgb, smoothstep(0.62, 0.8, paint));
    bool painted = (in.flags & 4u) != 0u;
    float wear = painted ? smoothstep(0.3, 0.8, metal) : 0.0;
    albedo = mix(albedo, float3(0.42, 0.43, 0.45), wear);
    // the downed: dimmed, a little desaturated
    float dim = D.flash.w;
    albedo = mix(albedo, float3(dot(albedo, float3(0.3, 0.5, 0.2))), dim * 0.4) * (1.0 - 0.3 * dim);
    LitSurface s;
    s.P = in.world; s.N = N; s.V = V; s.albedo = albedo; s.rough = rough; s.metal = metal;
    s.coat = painted ? 0.35 : 0.0; s.coatRough = 0.18; s.ao = ao; s.shadow = 1.0;
    float3 c = shadeLit(LIGHTING_ARGS, s, D.params.w > 0.5);
    // the class hue as a rim and a faint suit fill (the squad reads against the dark deck and the swarm even
    // outside the beams: the armour never sinks into the fog colour)
    float fr = pow(1.0 - saturate(dot(N0, V)), 3.0);
    c += D.hue.rgb * fr * D.params.x;
    c += albedo * ao * 0.035;
    // emission: visors / strips in the class hue (× the visor curve), lamps white
    if ((in.flags & 2u) != 0u) {
        float e = in.glow * ((in.flags & 1u) != 0u ? D.params.y * D.hue.w : D.params.z);
        c += in.albedo * e;
    }
    // the shooter lit by his own muzzle flash: a short-range point light at the muzzle (arms, chest, the gun)
    if (D.muzzle.w > 0.0) {
        float3 L = D.muzzle.xyz - in.world;
        float d2 = dot(L, L);
        float nl = saturate(dot(N, L * rsqrt(max(d2, 1e-6))) * 0.8 + 0.2);
        c += albedo * D.fx.rgb * (D.muzzle.w * nl / (1.0 + d2 * 9.0));
    }
    // barrels / nozzles heat up under sustained fire: dull red → orange at the tips
    if ((in.flags & 8u) != 0u && D.fx.w > 0.0) {
        float h = D.fx.w;
        c += float3(1.0, 0.32, 0.08) * (h * h * 2.2) + float3(1.0, 0.6, 0.25) * max(0.0, h - 0.6) * 2.0;
    }
    c += D.flash.rgb;
    return float4(heightFog(F, LB, c, in.world, in.depth), 1.0);
}

vertex ShadowOut vs_marine_shadow(uint vid [[vertex_id]],
                                  const device SkinVertex* V [[buffer(0)]],
                                  constant Frame& F [[buffer(1)]],
                                  const device float4* P [[buffer(MARINE_PALETTE)]]) {
    SkinVertex v = V[vid];
    float4 rest = float4(float3(v.rest.xyz), 1.0);
    float3 p = float3(0.0);
    for (int k = 0; k < 4; k++) {
        float w = float(v.weights[k]) / 255.0;
        if (w <= 0.0) continue;
        p += skinPoint(P, v.bones[k], rest) * w;
    }
    ShadowOut o;
    o.position = F.shadowMatrix * float4(p, 1.0);
    return o;
}

// ================================================================ weapon flashes (additive)
// Swift: WorldSquad.swift FlashInstance (64 bytes)
struct FlashInstance {
    float4 pos;       // xyz the muzzle (world), w = flame length (m)
    float4 dir;       // xyz the bore direction (unit, world), w = half width (m)
    float4 color;     // rgb linear HDR flash colour (the core runs white-hot over it), w = kind
    float4 params;    // x = roll about the bore (rad), y = intensity 0…1, z = seed, w = rays of the star
};

#define FLASH_RIFLE 0.0
#define FLASH_ROTARY 1.0
#define FLASH_FLAMER 2.0
#define FLASH_CRYO 3.0

struct FlashOut {
    float4 position [[position]];
    float2 uv;            // flame planes: u along the bore 0…1, v across −1…1; star / disc: −1…1
    float4 color;
    float4 params;
    uint   part [[flat]]; // 0, 1 flame planes, 2 camera-facing star, 3 disc across the bore
};

vertex FlashOut vs_muzzle_flash(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant Frame& F [[buffer(1)]],
                                const device FlashInstance* I [[buffer(2)]]) {
    FlashInstance f = I[iid];
    uint part = vid / 6u;
    float2 c = quadCorner(vid % 6u);
    float3 d = normalize(f.dir.xyz);
    float3 up = abs(d.y) < 0.95 ? float3(0, 1, 0) : float3(1, 0, 0);
    float3 a = normalize(cross(d, up));
    float3 b = cross(a, d);
    float r = f.params.x;
    float3 e0 = a * cos(r) + b * sin(r);
    float3 e1 = -a * sin(r) + b * cos(r);
    float L = f.pos.w, W = f.dir.w;
    float3 w;
    float2 uv;
    if (part < 2u) {
        float u = c.x * 0.5 + 0.5;
        float3 e = part == 0u ? e0 : e1;
        w = f.pos.xyz + d * (mix(-0.06, 1.0, u) * L) + e * (c.y * W);
        uv = float2(u, c.y);
    } else if (part == 2u) {
        w = f.pos.xyz + d * (0.04 * L) + (F.camRight.xyz * c.x + F.camUp.xyz * c.y) * (W * 1.9);
        uv = c;
    } else {
        w = f.pos.xyz + d * 0.015 + (e0 * c.x + e1 * c.y) * (W * 1.35);
        uv = c;
    }
    FlashOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.uv = uv;
    o.color = f.color;
    o.params = f.params;
    o.part = part;
    return o;
}

static inline float flashHash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

static inline float flashNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(flashHash(i), flashHash(i + float2(1, 0)), u.x), mix(flashHash(i + float2(0, 1)), flashHash(i + float2(1, 1)), u.x), u.y);
}

fragment float4 fs_muzzle_flash(FlashOut in [[stage_in]]) {
    float kind = in.color.w;
    float inten = in.params.y;
    float seed = in.params.z;
    float3 hue = in.color.rgb;
    float3 hot = float3(1.0, 0.93, 0.82);
    float3 c = float3(0.0);
    if (in.part < 2u) {
        // flame tongue along the bore: widest a third of the way out, torn into streaks, white-hot at the muzzle
        float u = saturate(in.uv.x), v = in.uv.y;
        float width = 1.55 * pow(u + 0.02, 0.38) * pow(1.0 - u, 0.85);
        float n = flashNoise(float2(u * 7.0 + seed * 13.0, v * 2.5 + seed * 5.0));
        float body = 1.0 - smoothstep(width * 0.45, width, abs(v) * (0.8 + 0.5 * n));
        float core = exp(-u * 8.0) * exp(-v * v * 10.0);
        float fall = pow(1.0 - u, 1.3);
        if (kind == FLASH_FLAMER) {
            // a hot cone: blue at the root, orange-yellow out
            float3 col = mix(float3(0.35, 0.55, 1.6), hue, smoothstep(0.0, 0.35, u));
            c = col * body * fall * (0.6 + 0.6 * n) + hot * core * 1.5;
        } else if (kind == FLASH_CRYO) {
            float shimmer = 0.6 + 0.4 * flashNoise(float2(u * 11.0 - seed * 7.0, v * 4.0));
            c = hue * body * fall * shimmer + float3(0.85, 0.97, 1.0) * core * 1.6;
        } else {
            c = mix(hue, hot, saturate(core + 0.35 * fall * body)) * (body * fall * (0.6 + 0.7 * n) + core * 3.2);
        }
    } else {
        float2 p = in.uv;
        float r = length(p);
        float a = atan2(p.y, p.x) + in.params.x;
        float rays = max(2.0, in.params.w);
        float edge = 1.0 - smoothstep(0.8, 1.0, r);
        if (in.part == 2u) {
            // camera-facing star: thin rays + a white-hot core + a soft halo
            float ray = pow(abs(cos(a * rays * 0.5)), kind == FLASH_CRYO ? 60.0 : 22.0) * exp(-r * (kind == FLASH_ROTARY ? 2.6 : 3.4));
            float core = exp(-r * r * 26.0);
            float halo = exp(-r * r * 5.0) * 0.3;
            float3 col = mix(hue, hot, core);
            c = col * (ray * 1.4 + core * 3.4 + halo) * edge;
            if (kind == FLASH_FLAMER) c = hue * (core * 1.4 + halo * 0.8) * edge;
        } else {
            // disc across the bore: a ring of petals (the muzzle brake's blast), dim
            float petals = 0.5 + 0.5 * cos(a * (rays + 1.0) + seed * 6.0);
            float ring = exp(-pow((r - 0.35) * 4.0, 2.0));
            c = hue * ring * (0.35 + 0.65 * petals) * 0.9 * edge;
            if (kind == FLASH_FLAMER) c = float3(0.0);
        }
    }
    return float4(c * inten, 1.0);
}
