// ================================================================
//  SWARM — the hive's creatures (owned by WP3 «Рой»):
//   vs_creature      IHV1 rigid path: every vertex follows its bone's
//                    3×4 matrix from the creature's bone texture; two
//                    clips (A: two rows lerped, B: two rows lerped, weight
//                    wB) blended by matrix lerp — speed-synced gait,
//                    attack lunge, hit recoil, deaths held as corpses —
//                    plus the per-instance lean (recoil away from the
//                    impact) and the glow table (pores, eyes)
//   fs_chitin        wet chitin on WP2's full light model (shadeLit:
//                    flashlights, grid lights, probe, clear coat on High,
//                    contact AO) + the type's cold Fresnel rim, HDR pores,
//                    eyes, translucent sacs, value bands live / corpse,
//                    frost (albedo ≤ 0.6, no white ghosts), char + embers,
//                    hit flash; height fog
//   vs_swarm_glint   the dorsal pores of every live bug once more as
//                    tiny HDR dots at their socket points (one draw, all
//                    four types): steady sparkle at phone size
//   vs_creature_proxy  the 20-triangle shadow blob of a bug inside a
//                    flashlight cone (shadow atlas casters)
//  Bindings: vertex buffer 0 the LOD's vertices (the IHV file buffer),
//  1 Frame, 2 instances, 3 SwarmParams (both stages), 4 the glow table;
//  vertex texture 6 the bone texture (glints: 6–9 one per type, glow
//  tables 11–14, sockets 10). LIGHTING_PARAMS (buffer 5, textures 3–5)
//  are bound for the whole world pass by LightGrid.
// ================================================================
#include "Common.h"
#include "Lighting.h"
#include "SwarmTypes.h"

struct CreatureOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    half3 albedo;
    half ao;
    half glow;
    half rough;
    half4 state;                 // hit flash, burn, frost, dead
    half rimK;                   // the type rim's scale at this LOD (fx.w)
    float depth;
    uint flags [[flat]];         // vertex flags | type << 8 | instance flags << 16
};

/// Row r (0…2) of bone `bone`'s 3×4 matrix at frame `row` (3 RGBA16F texels per bone).
static float3x4 boneRows(texture2d<half, access::read> T, uint bone, uint row) {
    return float3x4(float4(T.read(uint2(bone * 3u, row))), float4(T.read(uint2(bone * 3u + 1u, row))),
                    float4(T.read(uint2(bone * 3u + 2u, row))));
}

struct Pose {
    float3x4 M;
    float4 g;                    // glow table: gland, pulse, wave, eye
};

/// The bone's blended matrix and glow row of an instance: clip A (rows r0 | r1 << 16, frac) and clip B with weight wB.
static Pose poseOf(texture2d<half, access::read> T, const device float4* G, uint bone, uint4 anim) {
    float2 fr = unpack_unorm2x16_to_float(anim.z);
    float wB = float(anim.w & 0xffffu) * (1.0 / 65535.0);
    uint a0 = anim.x & 0xffffu, a1 = anim.x >> 16;
    float3x4 A0 = boneRows(T, bone, a0), A1 = boneRows(T, bone, a1);
    Pose p;
    p.M[0] = mix(A0[0], A1[0], fr.x);
    p.M[1] = mix(A0[1], A1[1], fr.x);
    p.M[2] = mix(A0[2], A1[2], fr.x);
    p.g = mix(G[a0], G[a1], fr.x);
    if (wB > 0.0) {
        uint b0 = anim.y & 0xffffu, b1 = anim.y >> 16;
        float3x4 B0 = boneRows(T, bone, b0), B1 = boneRows(T, bone, b1);
        p.M[0] = mix(p.M[0], mix(B0[0], B1[0], fr.y), wB);
        p.M[1] = mix(p.M[1], mix(B0[1], B1[1], fr.y), wB);
        p.M[2] = mix(p.M[2], mix(B0[2], B1[2], fr.y), wB);
        p.g = mix(p.g, mix(G[b0], G[b1], fr.y), wB);
    }
    return p;
}

static float3 xform(float3x4 M, float3 p) {
    float4 q = float4(p, 1.0);
    return float3(dot(M[0], q), dot(M[1], q), dot(M[2], q));
}

static float3 xformDir(float3x4 M, float3 n) {
    return float3(dot(M[0].xyz, n), dot(M[1].xyz, n), dot(M[2].xyz, n));
}

/// Model → world offset from the feet (heading, climb pitch, scale) with the instance's lean: a first-order rotation
/// about the feet that tips the top toward L (world x, z; radians).
static float3 placeOffset(CreatureInstance b, float3 p) {
    float s = b.pos.w, sy = b.tint.w;
    float c = b.rot.x, sn = b.rot.y, sp = b.rot.z, cp = b.rot.w;
    float3 ax = float3(c, 0.0, -sn);
    float3 ay = float3(-sn * sp, cp, -c * sp);
    float3 az = float3(sn * cp, sp, c * cp);
    float3 v = ax * (p.x * s) + ay * (p.y * sy) + az * (p.z * s);
    float2 L = unpack_snorm2x16_to_float(b.fx.y);
    return v + float3(L.x * v.y, -(L.x * v.x + L.y * v.z), L.y * v.y);
}

static float3 placeNormal(CreatureInstance b, float3 n) {
    float c = b.rot.x, sn = b.rot.y, sp = b.rot.z, cp = b.rot.w;
    float3 ax = float3(c, 0.0, -sn);
    float3 ay = float3(-sn * sp, cp, -c * sp);
    float3 az = float3(sn * cp, sp, c * cp);
    float3 v = ax * n.x + ay * n.y + az * n.z;
    float2 L = unpack_snorm2x16_to_float(b.fx.y);
    return normalize(v + float3(L.x * v.y, -(L.x * v.x + L.y * v.z), L.y * v.y));
}

static inline float3 srgbDecode(float3 c) { return c * (c * (c * 0.305306011 + 0.682171111) + 0.012522878); }

// ================================================================ the creature body
vertex CreatureOut vs_creature(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device IhvVertex* V [[buffer(0)]],
                               constant Frame& F [[buffer(1)]],
                               const device CreatureInstance* I [[buffer(2)]],
                               const device float4* glowTab [[buffer(4)]],
                               texture2d<half, access::read> boneTex [[texture(6)]]) {
    IhvVertex v = V[vid];
    CreatureInstance b = I[iid];
    uint bone = uint(v.material.z);
    uint vflags = uint(v.material.w);
    Pose P = poseOf(boneTex, glowTab, bone, b.anim);
    half4 rest = half4(v.rest);
    char4 nr = char4(v.nrm);
    float3 p = xform(P.M, float3(rest.xyz));
    float3 n = xformDir(P.M, float3(nr.xyz) * (1.0 / 127.0));
    float3 w = b.pos.xyz + placeOffset(b, p);
    CreatureOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.world = w;
    o.normal = placeNormal(b, n);
    float3 base = srgbDecode(float3(v.albedoAO.rgb) * (1.0 / 255.0));
    bool pore = (vflags & (IHV_GLAND | IHV_EYE)) != 0u;
    o.albedo = half3(pore ? base : base * b.tint.rgb);
    o.ao = half(float(v.albedoAO.a) * (1.0 / 255.0));
    float glow = float(v.material.x) * (1.0 / 255.0);
    if (vflags & IHV_GLAND) glow *= P.g.x + P.g.y * sin(6.2831853 * (P.g.z + float(rest.w)));
    else if (vflags & IHV_EYE) glow *= P.g.w;
    float boost = float(b.fx.z >> 16) * (1.0 / 65535.0);
    o.glow = half(glow * (1.0 + 1.5 * boost));
    o.rough = half(float(v.material.y) * (1.0 / 255.0));
    o.state = half4(unpack_unorm4x8_to_float(b.fx.x));
    o.rimK = half(1.0 - float(b.fx.w & 0xffu) * (1.0 / 255.0));
    o.depth = -(F.view * float4(w, 1.0)).z;
    o.flags = vflags | (((b.anim.w >> 16) & 0xffu) << 8) | ((b.anim.w >> 24) << 16);
    return o;
}

fragment float4 fs_chitin(CreatureOut in [[stage_in]],
                          constant Frame& F [[buffer(1)]],
                          constant SwarmParams& SP [[buffer(3)]],
                          LIGHTING_PARAMS) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float NoV = saturate(dot(N, V));
    float hit = in.state.x, burn = in.state.y, frz = in.state.z, dead = in.state.w;
    uint vf = in.flags & 0xffu, type = (in.flags >> 8) & 3u, inst = in.flags >> 16;
    SwarmType T = SP.types[type];
    bool gland = (vf & IHV_GLAND) != 0u, eyeF = (vf & IHV_EYE) != 0u, sac = (vf & IHV_SAC) != 0u, edge = (vf & IHV_EDGE) != 0u;
    float3 albedo = float3(in.albedo);
    // value band of the dead: darker and desaturated, so the living swarm reads on top of its own corpses
    float lum = dot(albedo, float3(0.2126, 0.7152, 0.0722));
    albedo = mix(albedo, float3(lum * 0.8, lum * 0.72, lum * 0.7), dead * 0.7) * (1.0 - 0.38 * dead);
    // frost crust (cryo): pale blue, capped well below white
    albedo = mix(albedo, float3(0.26, 0.38, 0.50), frz * 0.72);
    albedo *= 1.0 - burn * 0.55;
    float rough = float(in.rough);
    rough = mix(rough, 0.22, frz * 0.6);
    rough = mix(rough, 0.62, dead * 0.6);
    LitSurface s;
    s.P = in.world; s.N = N; s.V = V; s.albedo = albedo; s.rough = rough; s.metal = 0.0;
    s.coat = (edge ? 0.7 : 0.5) * (1.0 - 0.6 * dead) * (1.0 - 0.4 * frz) * (1.0 - burn);
    s.coatRough = 0.12; s.ao = float(in.ao); s.shadow = 0.0;
    float3 c = shadeLit(LIGHTING_ARGS, s, LB.info.y > 0.5);
    // light reaching the surface (for the sac's scattering), before the emissive terms
    float lightIn = min(dot(c / max(albedo, float3(0.004)), float3(0.333)), 4.0);
    // the bug sheet's studio light (look-dev only): a cool key from the upper left and a warm back light
    if (SP.info.y > 0.5) {
        float3 K = normalize(float3(-0.45, 0.8, 0.35));
        c += albedo * (0.05 + 0.55 * saturate(dot(N, K)));
        float3 H = normalize(K + V);
        c += float3(0.6, 0.7, 0.85) * 0.35 * pow(saturate(dot(N, H)), 40.0) * (1.0 - dead * 0.7);
    }
    // the type's cold Fresnel rim: outlines the silhouette against the dark deck (crisp's readability), dimmed on the dead
    float rim = pow(1.0 - NoV, 3.0);
    float3 rimC = (inst & CI_QUEEN) != 0u ? SP.queen.rgb : T.rim.rgb;
    if (!gland && !eyeF) c += rimC * (T.rim.w * float(in.rimK) * rim * (1.0 - 0.8 * dead) * (1.0 - 0.6 * frz) * (1.0 - 0.5 * burn));
    c += float3(0.08, 0.22, 0.38) * (frz * (0.05 + 0.6 * rim));
    // pores: HDR from the glow table (they pulse, flare on the attack, fade through the death clip)
    float glow = float(in.glow);
    float live = (1.0 - frz) * (1.0 - 0.85 * dead);
    if (gland) c += float3(in.albedo) * (T.gland.w * glow * live);
    if (eyeF) c += T.eye.rgb * (T.eye.w * glow * live);
    // translucent sac: the thick middle glows from inside, the thin rim stays dark; light that hits it scatters through.
    // The painted veins / keel / belly (dark vertex albedo) block the inner light, so every LOD's sac keeps its value.
    if (sac) {
        float thick = 0.25 + 0.75 * NoV * NoV;
        float pulse = 0.8 + 0.2 * sin(SP.info.x * 3.1 + in.world.x * 1.7 + in.world.z * 2.3);
        float trans = lightIn * 0.12;
        float3 a0 = float3(in.albedo);
        float veil = saturate(max(max(a0.r, a0.g), a0.b) * 4.0);
        c += T.sac.rgb * ((T.sac.w * thick * pulse + trans) * veil * (1.0 - 0.9 * dead) * (1.0 - frz) * (1.0 + 2.0 * glow));
    }
    // fire: char + embers in the seams
    c += float3(1.0, 0.32, 0.05) * (burn * (0.06 + 0.8 * glow + 0.3 * rim));
    // hit flash: a warm edge flare plus a small lift (a brute under sustained fire must not turn into a white ghost)
    c += float3(1.0, 0.62, 0.48) * (hit * (0.05 + 0.4 * rim));
    return float4(heightFog(F, LB, c, in.world, in.depth), 1.0);
}

// ================================================================ glints
struct GlintOut {
    float4 position [[position]];
    half4 color;
    float2 uv;
    float radius;
};

vertex GlintOut vs_swarm_glint(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant Frame& F [[buffer(1)]],
                               const device CreatureInstance* I [[buffer(2)]],
                               constant SwarmParams& SP [[buffer(3)]],
                               constant GlintSocket* S [[buffer(10)]],
                               const device float4* G0 [[buffer(11)]],
                               const device float4* G1 [[buffer(12)]],
                               const device float4* G2 [[buffer(13)]],
                               const device float4* G3 [[buffer(14)]],
                               texture2d<half, access::read> T0 [[texture(6)]],
                               texture2d<half, access::read> T1 [[texture(7)]],
                               texture2d<half, access::read> T2 [[texture(8)]],
                               texture2d<half, access::read> T3 [[texture(9)]]) {
    // the type whose glint range holds this instance (ranges are cumulative; an empty range is skipped)
    uint t = uint(iid >= SP.types[1].glint.z) + uint(iid >= SP.types[2].glint.z) + uint(iid >= SP.types[3].glint.z);
    uint4 gi = SP.types[t].glint;
    uint per = max(gi.y, 1u);
    uint local = iid - gi.z;
    CreatureInstance b = I[gi.w + local / per];
    GlintSocket gs = S[gi.x + local % per];
    uint bone = uint(gs.pos.w);
    Pose P;
    switch (t) {
        case 0: P = poseOf(T0, G0, bone, b.anim); break;
        case 1: P = poseOf(T1, G1, bone, b.anim); break;
        case 2: P = poseOf(T2, G2, bone, b.anim); break;
        default: P = poseOf(T3, G3, bone, b.anim); break;
    }
    float3 w = b.pos.xyz + placeOffset(b, xform(P.M, gs.pos.xyz));
    float4 st = unpack_unorm4x8_to_float(b.fx.x);
    float mult = max(0.0, P.g.x + P.g.y * sin(6.2831853 * (P.g.z + gs.info.w)));
    float boost = float(b.fx.z >> 16) * (1.0 / 65535.0);
    float k = gs.info.y * mult * (1.0 + 1.5 * boost) * (1.0 - st.z) * (1.0 - st.w);
    float3 hot = SP.types[t].gland.rgb, dim = float3(0.9, 0.08, 0.18);
    float3 col = (gs.info.z > 0.5 ? hot : dim) * (SP.types[t].gland.w * k);
    // under a flashlight the pores go white-hot (the beam is the light)
    col += float3(1.0, 0.55, 0.75) * (min(dot(spotInScatter(F, w), float3(0.333)), 3.0) * 0.08 * k);
    w += normalize(F.camPos.xyz - w) * (0.05 * b.pos.w);
    float z = max(0.05, -(F.view * float4(w, 1.0)).z);
    float diam = max(gs.info.x * 2.0 * SP.info.w * b.pos.w * F.misc.x / z, SP.info.z);   // drawable px
    float hp = 0.5 * diam + 0.75;
    float hs = hp * z / F.misc.x;
    float2 q = quadCorner(vid);
    float3 vtx = w + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    GlintOut o;
    o.position = F.viewProj * float4(vtx, 1.0);
    o.color = half4(half3(encodeColor(F, col, z, true)), half(k > 0.002 ? 1.0 : 0.0));
    o.uv = q * hp;
    o.radius = 0.5 * diam;
    return o;
}

fragment float4 fs_swarm_glint(GlintOut in [[stage_in]]) {
    float d = length(in.uv);
    float a = saturate(in.radius + 0.5 - d) * float(in.color.a);
    float core = 0.65 + 0.35 * saturate(1.0 - d / max(in.radius, 0.5));
    return float4(float3(in.color.rgb) * core, a);
}

// ================================================================ flashlight shadow proxy (depth only)
// per bug inside a flashlight cone: an icosahedron scaled to the type's body (SwarmType.proxy), following the instance's
// heading, pitch and lean
vertex ShadowOut vs_creature_proxy(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device packed_float3* Pv [[buffer(0)]],
                                   constant Frame& F [[buffer(1)]],
                                   const device CreatureInstance* I [[buffer(2)]],
                                   constant SwarmParams& SP [[buffer(3)]]) {
    CreatureInstance b = I[iid];
    float4 pr = SP.types[(b.anim.w >> 16) & 3u].proxy;
    float3 p = float3(Pv[vid]) * pr.xyz + float3(0.0, pr.w, 0.0);
    ShadowOut o;
    o.position = F.shadowMatrix * float4(b.pos.xyz + placeOffset(b, p), 1.0);
    return o;
}
