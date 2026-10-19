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
