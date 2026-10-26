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
//     invulnerable flashes, the downed dimming;
//     vs_marine_shadow draws them into the flashlight shadow atlas;
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
    char4 nrm;        // snorm xyz, w = flags (bit0 class-hue visor / strip, bit1 emissive, bit2 painted armour)
    char4 tan;        // snorm xyz along +u, w = ±127 bitangent sign
    half2 uv;         // the class's texture layer (top-left origin)
    uchar4 albedo;    // sRGB rgb, a = glow 0…1
    uchar4 bones;
    uchar4 weights;   // sum 255
};

// Swift: WorldSquad.swift MarineDraw (64 bytes)
struct MarineDraw {
    float4 hue;       // rgb class hue (linear), w = visor glow multiplier (the clip's ctrl curve × flicker)
    float4 trim;      // rgb class paint (linear), w = texture layer (class index)
    float4 flash;     // rgb added emissive (hurt / invulnerable), w = downed dimming 0…1
    float4 params;    // x = class rim strength, y = emissive gain, z = lamp gain, w = 1 on the High tier
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
