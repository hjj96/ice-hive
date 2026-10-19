// ================================================================
//  LIGHTING — the light model every material shader includes (owned by
//  WP2 «Свет и воздух»): three.js MeshStandardMaterial / Lambert with
//  hemisphere + moon + 4 flashlights (three.js spot attenuation) + 3
//  point lights, and the player's flashlight shadow (PCF 3×3).
//  Functions return linear radiance / irradiance; the output encoding
//  is Common.h's encodeColor().
// ================================================================
#ifndef ICEHIVE_LIGHTING_H
#define ICEHIVE_LIGHTING_H

#include "Common.h"

#define SPOT_COLOR float3(1.0, 0.8879, 0.7304)   /* 0xfff2de, linear */
#define SPOT_COS_OUT 0.87758                      /* cos(0.5) */
#define SPOT_COS_IN 0.97479                       /* cos(0.5 * (1 - 0.55)) */
#define SPOT_RANGE 32.0
#define SPOT_DECAY 1.35
#define POINT_DECAY 2.0

constexpr sampler shadowSampler(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);

static float distanceAtten(float d, float cutoff, float decay) {
    float falloff = 1.0 / max(pow(max(d, 1e-4), decay), 0.01);
    float x = d / cutoff;
    float s = saturate(1.0 - x * x * x * x);
    return falloff * s * s;
}

static float3 fresnelSchlick(float3 f0, float dotVH) {
    float f = exp2((-5.55473 * dotVH - 6.98316) * dotVH);
    return f0 * (1.0 - f) + f;
}

static float3 brdfGGX(float3 L, float3 V, float3 N, float3 f0, float alpha) {
    float3 H = normalize(L + V);
    float dotNL = saturate(dot(N, L));
    float dotNV = saturate(dot(N, V));
    float dotNH = saturate(dot(N, H));
    float dotVH = saturate(dot(V, H));
    float a2 = alpha * alpha;
    float gv = dotNL * sqrt(a2 + (1.0 - a2) * dotNV * dotNV);
    float gl = dotNV * sqrt(a2 + (1.0 - a2) * dotNL * dotNL);
    float vis = 0.5 / max(gv + gl, 1e-6);
    float den = dotNH * dotNH * (a2 - 1.0) + 1.0;
    float D = (1.0 / PI_F) * a2 / (den * den);
    return fresnelSchlick(f0, dotVH) * (vis * D);
}

/// The player's flashlight shadow at P (1 = lit): 3 × 3 PCF over the 1024² depth map (three.js PCFShadowMap).
static float spotShadow(constant Frame& F, depth2d<float> sm, float3 P) {
    if (F.shadowParams.x < 0.5) return 1.0;
    float4 c = F.shadowMatrix * float4(P, 1.0);
    if (c.w <= 0.0) return 1.0;
    float3 s = c.xyz / c.w;
    float2 uv = float2(s.x * 0.5 + 0.5, 0.5 - s.y * 0.5);
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0 || s.z > 1.0) return 1.0;
    float z = s.z + F.shadowParams.y;
    float t = F.shadowParams.z;
    float sum = 0.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) sum += sm.sample_compare(shadowSampler, uv + float2(float(x), float(y)) * t, z);
    }
    return sum * (1.0 / 9.0);
}

/// Irradiance / PI of every light at P (Lambert; multiply by the albedo). `sh` scales the player's flashlight (shadow).
static float3 lambertLight(constant Frame& F, float3 P, float3 N, float sh = 1.0) {
    float3 irr = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * N.y + 0.5);
    irr += F.moonColor.rgb * saturate(dot(N, F.moonDir.xyz));
    for (int i = 0; i < 4; i++) {
        float I = F.spotPos[i].w;
        if (I <= 0.0) continue;
        float3 Lv = F.spotPos[i].xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        float cone = smoothstep(SPOT_COS_OUT, SPOT_COS_IN, dot(-L, F.spotDir[i].xyz));
        irr += SPOT_COLOR * (I * cone * distanceAtten(d, SPOT_RANGE, SPOT_DECAY) * saturate(dot(N, L)) * (i == 0 ? sh : 1.0));
    }
    for (int i = 0; i < 3; i++) {
        float range = F.pointPos[i].w;
        if (range <= 0.0) continue;
        float3 Lv = F.pointPos[i].xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        irr += F.pointColor[i].rgb * (distanceAtten(d, range, POINT_DECAY) * saturate(dot(N, L)));
    }
    return irr;
}

/// MeshStandardMaterial without environment map: Lambert diffuse * (1 - metalness) + GGX specular.
static float3 standardLight(constant Frame& F, float3 P, float3 N, float3 V, float3 albedo, float rough, float metal, float sh = 1.0) {
    float3 diffuse = albedo * (1.0 - metal);
    float3 f0 = mix(float3(0.04), albedo, metal);
    float r = max(rough, 0.0525);
    float alpha = r * r;
    float3 outD = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * N.y + 0.5) * diffuse;
    float3 outS = float3(0.0);
    {
        float3 L = F.moonDir.xyz;
        float nl = saturate(dot(N, L));
        float3 c = F.moonColor.rgb * nl;
        outD += c * diffuse;
        outS += c * PI_F * brdfGGX(L, V, N, f0, alpha);
    }
    for (int i = 0; i < 4; i++) {
        float I = F.spotPos[i].w;
        if (I <= 0.0) continue;
        float3 Lv = F.spotPos[i].xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        float cone = smoothstep(SPOT_COS_OUT, SPOT_COS_IN, dot(-L, F.spotDir[i].xyz));
        float k = I * cone * distanceAtten(d, SPOT_RANGE, SPOT_DECAY) * saturate(dot(N, L)) * (i == 0 ? sh : 1.0);
        if (k <= 0.0) continue;
        float3 c = SPOT_COLOR * k;
        outD += c * diffuse;
        outS += c * PI_F * brdfGGX(L, V, N, f0, alpha);
    }
    for (int i = 0; i < 3; i++) {
        float range = F.pointPos[i].w;
        if (range <= 0.0) continue;
        float3 Lv = F.pointPos[i].xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        float k = distanceAtten(d, range, POINT_DECAY) * saturate(dot(N, L));
        if (k <= 0.0) continue;
        float3 c = F.pointColor[i].rgb * k;
        outD += c * diffuse;
        outS += c * PI_F * brdfGGX(L, V, N, f0, alpha);
    }
    return outD + outS;
}

#endif
