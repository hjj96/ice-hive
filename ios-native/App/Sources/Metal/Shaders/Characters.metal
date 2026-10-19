// ================================================================
//  CHARACTERS — instanced meshes (owned by WP4 «Отряд»): the squad,
//  turret, medkits and corpses go through vs_mesh with a per-instance
//  model matrix + tint + emissive (MetalRenderer's mesh batches);
//  corpses are Lambert with the instance colour, globs / grenades /
//  beacon tips unlit. vs_shadow_mesh draws the squad into the
//  flashlight shadow map. The squad and props shade with fs_props
//  (Level.metal).
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
                           LIGHTING_PARAMS) {
    LitSurface s;
    s.P = in.world; s.N = normalize(in.normal); s.V = normalize(F.camPos.xyz - in.world); s.albedo = in.color;
    s.rough = 0.85; s.metal = 0.0; s.coat = 0.0; s.coatRough = 0.3; s.ao = 1.0; s.shadow = M.floor.w;
    float3 c = shadeLit(LIGHTING_ARGS, s, false);
    return float4(heightFog(F, LB, c, in.world, in.depth), 1.0);
}

/// MeshBasicMaterial (glob, grenade, beacon tip): tone mapped, no fog
fragment float4 fs_unlit(MeshOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]]) {
    return float4(encodeColor(F, in.color, in.depth, false), 1.0);
}

// ================================================================ flashlight shadow map (depth only)
// casters like the web: the squad (castShadow) and, per bug inside the player's flashlight cone, the 20-triangle
// proxy blob (Swarm.metal vs_shadow_proxy); the level itself casts nothing
vertex ShadowOut vs_shadow_mesh(MeshIn v [[stage_in]],
                                uint iid [[instance_id]],
                                constant Frame& F [[buffer(1)]],
                                const device MeshInstance* I [[buffer(2)]]) {
    ShadowOut o;
    o.position = F.shadowMatrix * (I[iid].model * float4(v.position, 1.0));
    return o;
}
