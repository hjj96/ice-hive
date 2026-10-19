// ================================================================
//  LEVEL — station materials (owned by WP6 «Станция и конвейер»):
//  three.js MeshStandardMaterial for the merged level props (vertex
//  colours + aGlow, snow caps), the floors (grating / slab texture +
//  the world-space snow drift mask), textured hazard strips and the
//  landing-pad mark, and the unlit additive floor light pools.
//  vs_static places world-space geometry (material.floor.z lifts the
//  lift deck during the extraction).
// ================================================================
#include "Common.h"
#include "Lighting.h"

// world-placed geometry; material.floor.z lifts the lift deck during the extraction
vertex MeshOut vs_static(MeshIn v [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant Material& M [[buffer(3)]]) {
    float3 w = v.position + float3(0.0, M.floor.z, 0.0);
    return meshOut(F, w, v.normal, v.color, v.glow, v.leg.xy, float3(0.0));
}

/// makeGlowMaterial: vertex colours, aGlow emissive, optional snow caps (props, lift props, marines, turret, medkit)
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

/// makeFloorMaterial: grating / slab texture + the world-space snow drift mask
fragment float4 fs_floor(MeshOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant Material& M [[buffer(3)]],
                         texture2d<float> map [[texture(0)]],
                         texture2d<float> snow [[texture(1)]],
                         depth2d<float> shadowMap [[texture(3)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 albedo = map.sample(repeatSampler, in.uv).rgb * in.color;
    float sm = snow.sample(dataSampler, (in.world.xz + 64.0) / 128.0).r + M.floor.x;
    float bar = smoothstep(0.08, 0.32, dot(albedo, float3(0.3333)));
    float fill = smoothstep(0.28, 0.72, sm) * step(0.5, N.y) * mix(0.55, 1.0, bar);
    albedo = mix(albedo, float3(0.68, 0.74, 0.82), fill);
    float rough = mix(M.pbr.x, 0.92, fill);
    float metal = mix(M.pbr.y, 0.0, fill);
    float sh = M.floor.w > 0.5 ? spotShadow(F, shadowMap, in.world) : 1.0;
    float3 c = standardLight(F, in.world, N, V, albedo, rough, metal, sh);
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

/// textured standard material (hazard strips; the landing pad mark with its alpha)
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
