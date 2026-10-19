// ================================================================
//  SWARM — the bugs (owned by WP3 «Рой»): one instanced draw per bug
//  type, legs animated from aLeg like the web's makeBugMaterial
//  (Lambert + aGlow speckles + rim, hit flash, burn, freeze), the
//  optional anti-aliased glint dots (-glintDots) and the 20-triangle
//  shadow proxy blob each bug inside the player's flashlight casts.
// ================================================================
#include "Common.h"
#include "Lighting.h"
#include "SwarmTypes.h"

// one instanced draw per bug type; legs animated from aLeg like makeBugMaterial
vertex MeshOut vs_bug(MeshIn v [[stage_in]],
                      uint iid [[instance_id]],
                      constant Frame& F [[buffer(1)]],
                      const device BugInstance* I [[buffer(2)]]) {
    BugInstance b = I[iid];
    float3 p = v.position;
    float s = b.pos.w, sy = b.color.w;
    float c = b.rot.x, sn = b.rot.y, sp = b.rot.z, cp = b.rot.w;
    // the contact smudge disappears while the bug climbs the wall
    if (v.leg.z > 0.5) p *= step(0.85, cp);
    float ph = b.anim.x + v.leg.y;
    p.z += sin(ph) * v.leg.x * 0.17;
    p.y += max(0.0, cos(ph)) * v.leg.x * 0.08;
    p.y += (1.0 - step(0.001, v.leg.x)) * abs(sin(b.anim.x)) * 0.03;
    float3 ax = float3(c, 0.0, -sn);
    float3 ay = float3(-sn * sp, cp, -c * sp);
    float3 az = float3(sn * cp, sp, c * cp);
    float3 w = b.pos.xyz + ax * (p.x * s) + ay * (p.y * sy) + az * (p.z * s);
    float3 n = normalize(ax * v.normal.x + ay * v.normal.y + az * v.normal.z);
    return meshOut(F, w, n, v.color * b.color.rgb, v.glow, float2(0.0), b.anim.yzw);
}

fragment float4 fs_bug(MeshOut in [[stage_in]],
                       constant Frame& F [[buffer(1)]],
                       LIGHTING_PARAMS) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float flash = in.extra.x, burn = in.extra.y, frz = in.extra.z;
    float3 albedo = mix(in.color, float3(0.2, 0.38, 0.55), frz * 0.8) * (1.0 - burn * 0.6);
    LitSurface s;
    s.P = in.world; s.N = N; s.V = V; s.albedo = albedo; s.rough = 0.42; s.metal = 0.0;
    s.coat = 0.6 * (1.0 - frz); s.coatRough = 0.12; s.ao = 1.0; s.shadow = 0.0;
    float3 c = shadeLit(LIGHTING_ARGS, s, LB.info.y > 0.5);
    float rim = 1.0 - abs(dot(N, V));
    c += in.color * in.glow * (1.0 - frz);
    c += float3(0.22, 0.14, 0.26) * (rim * rim * rim * 0.3 * (1.0 - in.glow) * (1.0 - frz));
    c += float3(1.0, 0.3, 0.04) * (burn * (0.12 + 0.88 * in.glow) * 0.9);
    c += float3(1.0, 0.92, 0.88) * (flash * 0.8);
    c += float3(0.05, 0.16, 0.3) * (frz * 0.5);
    return float4(heightFog(F, LB, c, in.world, in.depth), 1.0);
}

// ================================================================ flashlight shadow proxy (depth only)
// per bug inside the player's flashlight cone, the 20-triangle proxy blob of 05-sim.js (icosahedron r 0.3 scaled
// 1 / 0.7 / 1.3, lifted 0.35)
vertex ShadowOut vs_shadow_proxy(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device packed_float3* P [[buffer(0)]],
                                 constant Frame& F [[buffer(1)]],
                                 const device BugInstance* I [[buffer(2)]]) {
    BugInstance b = I[iid];
    float3 p = float3(P[vid]) * float3(1.0, 0.7, 1.3) + float3(0.0, 0.35, 0.0);
    float s = b.pos.w, sy = b.color.w;
    float c = b.rot.x, sn = b.rot.y, sp = b.rot.z, cp = b.rot.w;
    float3 ax = float3(c, 0.0, -sn);
    float3 ay = float3(-sn * sp, cp, -c * sp);
    float3 az = float3(sn * cp, sp, c * cp);
    float3 w = b.pos.xyz + ax * (p.x * s) + ay * (p.y * sy) + az * (p.z * s);
    ShadowOut o;
    o.position = F.shadowMatrix * float4(w, 1.0);
    return o;
}

// ================================================================ glints (-glintDots)
// every glow speckle of a visible bug again as an anti-aliased dot of at least ~1.6 drawable pixels, shaded exactly
// like the speckle itself (makeBugMaterial: lit vertex colour + aGlow emissive, tone mapped, fogged) and
// alpha-blended over it — a 3–5 cm tetrahedron covers about a pixel at the game camera, so without MSAA it flickers in
// and out; the dot keeps the swarm's sparkle steady at the web's look (pink in the dark, white-hot under a flashlight)
struct Glint { float4 pos; float4 color; };   // local centre xyz + size, colour

/// Irradiance / PI at a speckle facing every light half-way (the visible faces of a tetrahedron average N·L ≈ 0.5–0.6).
static float3 glintLight(constant Frame& F, float3 P) {
    const float NL = 0.6;
    float3 irr = F.hemiSky.rgb * 0.8 + F.hemiGround.rgb * 0.2 + F.moonColor.rgb * NL;
    for (int i = 0; i < 4; i++) {
        float I = F.spotPos[i].w;
        if (I <= 0.0) continue;
        irr += SPOT_COLOR * (spotTerm(F, i, P).w * NL);
    }
    for (int i = 0; i < 3; i++) {
        float range = F.pointPos[i].w;
        if (range <= 0.0) continue;
        irr += F.pointColor[i].rgb * (distanceAtten(length(F.pointPos[i].xyz - P), range, POINT_DECAY) * NL);
    }
    return irr;
}

vertex QuadOut vs_glint(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Frame& F [[buffer(1)]],
                        const device BugInstance* I [[buffer(2)]],
                        constant Glint* G [[buffer(3)]],
                        constant uint& count [[buffer(4)]]) {
    BugInstance b = I[iid / count];
    Glint g = G[iid % count];
    float3 p = g.pos.xyz;
    p.y += abs(sin(b.anim.x)) * 0.03;
    float s = b.pos.w, sy = b.color.w;
    float c = b.rot.x, sn = b.rot.y, sp = b.rot.z, cp = b.rot.w;
    float3 ax = float3(c, 0.0, -sn);
    float3 ay = float3(-sn * sp, cp, -c * sp);
    float3 az = float3(sn * cp, sp, c * cp);
    float3 w = b.pos.xyz + ax * (p.x * s) + ay * (p.y * sy) + az * (p.z * s);
    // the speckle's own colour (fs_bug for a full-glow vertex)
    float flash = b.anim.y, burn = b.anim.z, frz = b.anim.w;
    float3 vcol = g.color.rgb * b.color.rgb;
    float3 albedo = mix(vcol, float3(0.2, 0.38, 0.55), frz * 0.8) * (1.0 - burn * 0.6);
    float3 lin = glintLight(F, w) * albedo + vcol * (1.0 - frz) + float3(1.0, 0.3, 0.04) * (burn * 0.9)
               + float3(1.0, 0.92, 0.88) * (flash * 0.8) + float3(0.05, 0.16, 0.3) * (frz * 0.5);
    float depth = max(0.05, -(F.view * float4(w, 1.0)).z);
    float3 col = encodeColor(F, lin, depth, true);
    // pulled a little toward the camera so the dot is not buried in the body it sits on
    w += normalize(F.camPos.xyz - w) * 0.06;
    float z = max(0.05, -(F.view * float4(w, 1.0)).z);
    float diam = max(g.pos.w * s * F.misc.x / z, 1.6);   // drawable px
    float hp = 0.5 * diam + 0.75;                        // + an anti-aliasing rim
    float hs = hp * z / F.misc.x;
    float2 q = quadCorner(vid);
    float3 v = w + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    QuadOut o = quadOut(F, v, float4(col, 1.0), q * hp, float4(0.5 * diam, 0.0, 0.0, 0.0));
    return o;
}

fragment float4 fs_glint(QuadOut in [[stage_in]]) {
    // uv in drawable px from the centre; params.x = radius (px)
    float a = saturate(in.params.x + 0.5 - length(in.uv));
    return float4(in.color.rgb, a);
}
