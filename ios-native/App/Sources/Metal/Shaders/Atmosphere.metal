// ================================================================
//  ATMOSPHERE — air and weather (owned by WP2 «Свет и воздух»): the
//  abyss haze plane (alpha, unlit, no fog) and the GPU-animated weather
//  of 07-fx.js — snowfall around the camera target, pink motes rising
//  out of the abyss, low mist banks drifting over the decks.
// ================================================================
#include "Common.h"

struct WeatherParams {
    float4 center;   // xyz camera target, w = kind (0 snow, 1 motes, 2 mist)
    float4 extra;    // x = particle count
};

// ================================================================ abyss haze plane (static mesh, alpha)
vertex MeshOut vs_haze(MeshIn v [[stage_in]],
                       constant Frame& F [[buffer(1)]],
                       constant Material& M [[buffer(3)]]) {
    float3 w = v.position + float3(0.0, M.floor.z, 0.0);
    return meshOut(F, w, v.normal, v.color, v.glow, v.leg.xy, float3(0.0));
}

fragment float4 fs_haze(MeshOut in [[stage_in]],
                        constant Frame& F [[buffer(1)]],
                        texture2d<float> map [[texture(0)]]) {
    float4 t = map.sample(clampSampler, in.uv);
    return float4(encodeColor(F, t.rgb * in.color, in.depth, false), t.a);
}

// ================================================================ weather (GPU animated, 07-fx.js snow / motes / mist)
static float hash11(float n) { return fract(sin(n * 12.9898 + 78.233) * 43758.5453); }

vertex QuadOut vs_weather(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant Frame& F [[buffer(1)]],
                          constant WeatherParams& W [[buffer(2)]]) {
    float k = float(iid);
    float seed = hash11(k * 3.17 + 0.5);
    float kind = W.center.w;
    float time = F.camPos.w;
    float3 c = W.center.xyz;
    float3 p;
    float size, alpha;
    float3 col;
    if (kind < 0.5) {
        // snowfall around the camera target
        p = float3(hash11(k + 1.1) * 48.0 - 24.0, hash11(k + 2.3) * 18.0, hash11(k + 3.7) * 48.0 - 24.0);
        p.y = fmod(fmod(p.y - time * (1.1 + seed * 0.9), 18.0) + 18.0, 18.0) - 1.0 + c.y;
        p.x += sin(time * 0.8 + seed * 40.0) * 0.5 + time * 1.6;
        p.z += cos(time * 0.6 + seed * 30.0) * 0.4 + time * 0.7;
        p.x = fmod(fmod(p.x - c.x + 24.0, 48.0) + 48.0, 48.0) - 24.0 + c.x;
        p.z = fmod(fmod(p.z - c.z + 24.0, 48.0) + 48.0, 48.0) - 24.0 + c.z;
        size = 0.025 + seed * 0.04;
        alpha = 0.35 + seed * 0.45;
        col = float3(0.85, 0.9, 1.0);
    } else if (kind < 1.5) {
        // pink motes rising out of the abyss
        p = float3(-50.0 + hash11(k + 4.1) * 95.0, -6.0 - hash11(k + 5.3) * 40.0, -58.0 + hash11(k + 6.7) * 100.0);
        p.x += sin(time * 0.3 + seed * 20.0) * 0.8;
        p.z += cos(time * 0.25 + seed * 13.0) * 0.8;
        size = 0.12 + seed * 0.2;
        alpha = max(0.0, (0.4 + 0.6 * sin(time * (1.0 + seed * 2.0) + seed * 50.0)) * smoothstep(-48.0, -8.0, p.y));
        col = float3(1.0, 0.2, 0.45);
    } else {
        // low mist banks drifting over the decks
        p = float3(hash11(k + 7.1) * 60.0 - 30.0, 0.4 + hash11(k + 8.3) * 1.4 + c.y, hash11(k + 9.7) * 60.0 - 30.0);
        p.x += time * (0.35 + seed * 0.3);
        p.z += time * 0.12;
        p.x = fmod(fmod(p.x - c.x + 30.0, 60.0) + 60.0, 60.0) - 30.0 + c.x;
        p.z = fmod(fmod(p.z - c.z + 30.0, 60.0) + 60.0, 60.0) - 30.0 + c.z;
        size = 6.0 + seed * 6.0;
        alpha = (0.07 + 0.05 * sin(time * 0.3 + seed * 20.0)) * 1.4;
        col = float3(0.62, 0.72, 0.84);
    }
    float z = max(0.05, -(F.view * float4(p, 1.0)).z);
    float lo = kind > 1.5 ? 8.0 : 1.0;
    float hi = kind < 0.5 ? 7.0 : (kind < 1.5 ? 8.0 : 180.0);
    float px = clamp(size * F.misc.x / z, lo, hi);
    float hs = 0.5 * px * z / F.misc.x;
    float2 q = quadCorner(vid);
    float3 w = p + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    // constant colour per flake / mote / bank: encoded once per vertex (exact)
    return quadOut(F, w, float4(encodeColor(F, col, 0.0, false), alpha), q * 0.5, float4(kind, seed, 0.0, 0.0));
}

fragment float4 fs_weather(QuadOut in [[stage_in]]) {
    float d = length(in.uv) * 2.0;
    float kind = in.params.x;
    float a;
    if (kind < 0.5) {
        a = in.color.a * (1.0 - smoothstep(0.2, 1.0, d));
    } else if (kind < 1.5) {
        a = in.color.a * (1.0 - smoothstep(0.0, 1.0, d));
    } else {
        float s = in.params.y;
        float2 q = in.uv;
        float n = 0.75 + 0.25 * sin(q.x * 9.0 + s * 30.0) * sin(q.y * 7.0 - s * 17.0);
        a = in.color.a * n * (1.0 - smoothstep(0.1, 1.0, d));
    }
    return float4(in.color.rgb, a);
}
