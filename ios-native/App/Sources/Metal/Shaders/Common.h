// ================================================================
//  COMMON — what every shader file of the world and the post chain
//  shares (WP1 «Кадр» owns this header): the per-frame constants,
//  the vertex / interpolant structs of the mesh and quad pipelines,
//  samplers, the screen-quad helper and the OUTPUT CONTRACT of the
//  world target:
//    encodeColor(F, lin, depth, fogged)  every material's colour out
//    encodeMultiply(c)                   factor of a multiply blend
//  Materials compute linear radiance and hand it to these two; what
//  the world target stores (and where tone mapping happens) is
//  decided here and in Post.metal only.
//  Struct layouts mirror MetalShared.swift (Frame, Material,
//  MeshInstance); module structs live in their owner's file / header
//  (BugInstance: SwarmTypes.h, FX instances: FX.metal).
//  No program-scope `constant` variables here (the header is included
//  by several translation units): scalars are macros, tables are
//  functions.
// ================================================================
#ifndef ICEHIVE_COMMON_H
#define ICEHIVE_COMMON_H

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- shared data
struct Frame {
    float4x4 viewProj;
    float4x4 view;
    float4 camPos;        // xyz, w = time
    float4 fog;           // rgb display-space colour, w = density
    float4 hemiSky;       // colour * intensity / PI
    float4 hemiGround;
    float4 moonDir;       // toward the light
    float4 moonColor;     // colour * intensity / PI
    float4 spotPos[4];    // xyz, w = intensity / PI
    float4 spotDir[4];
    float4 pointPos[3];   // xyz, w = cutoff distance
    float4 pointColor[3]; // colour * intensity / PI
    float4 misc;          // x = px per metre at unit depth, y = drawable height, z = lift rise, w unused
    float4 camRight;
    float4 camUp;
    float4x4 shadowMatrix; // the player's flashlight (spot 0) view-projection
    float4 shadowParams;   // x = on, y = depth bias, z = 1 / map size
    float4 fx;             // x = particle mask noise taps (2, or 1 on the low tier)
};

struct Material {
    float4 pbr;     // roughness, metalness, snow caps, glow strength
    float4 floor;   // snow bias, (unused), vertical offset, receives the flashlight shadow
};

/// Generic instanced mesh (MetalRenderer's mesh batches: marines, props, corpses, unlit bits).
struct MeshInstance {
    float4x4 model;
    float4 tint;     // rgb multiplies the vertex colour
    float4 emissive; // rgb added emissive, w = 1 replaces the vertex colour by tint
};

struct MeshIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float3 color    [[attribute(2)]];
    float  glow     [[attribute(3)]];
    float3 leg      [[attribute(4)]];
};

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 color;
    float  glow;
    float2 uv;
    float  depth;
    float3 extra;    // instanced meshes: added emissive; bugs: flash, burn, freeze
};

struct QuadOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float4 params;
    float  depth;
};

/// Depth-only passes (flashlight shadow).
struct ShadowOut { float4 position [[position]]; };

// ---------------------------------------------------------------- constants
#define PI_F 3.14159265

constexpr sampler repeatSampler(filter::linear, mip_filter::linear, address::repeat);
constexpr sampler clampSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler dataSampler(filter::linear, address::clamp_to_edge);

// ---------------------------------------------------------------- tone mapping / output
static float3 acesFilmic(float3 c) {
    const float3x3 ACES_IN = float3x3(float3(0.59719, 0.07600, 0.02840),
                                      float3(0.35458, 0.90834, 0.13383),
                                      float3(0.04823, 0.01566, 0.83777));
    const float3x3 ACES_OUT = float3x3(float3(1.60475, -0.10208, -0.00327),
                                       float3(-0.53108, 1.10813, -0.07276),
                                       float3(-0.07367, -0.00605, 1.07602));
    c *= 1.0 / 0.6;
    c = ACES_IN * c;
    float3 a = c * (c + 0.0245786) - 0.000090537;
    float3 b = c * (0.983729 * c + 0.4329510) + 0.238081;
    c = a / b;
    return saturate(ACES_OUT * c);
}

static float3 linearToSRGB(float3 c) {
    float3 lo = c * 12.92;
    float3 hi = pow(max(c, float3(0.0)), float3(0.41666)) * 1.055 - 0.055;
    return select(hi, lo, c <= float3(0.0031308));
}

/// The colour a material writes into the world target: tonemapping_fragment + colorspace_fragment (+ fog_fragment
/// when fogged), like three.js rendering straight to the canvas.
static float3 encodeColor(constant Frame& F, float3 lin, float depth, bool fogged) {
    float3 c = linearToSRGB(acesFilmic(lin));
    if (fogged) {
        float d = F.fog.w * depth;
        c = mix(c, F.fog.rgb, 1.0 - exp(-d * d));
    }
    return c;
}

/// The factor a multiply-blended draw (floor stains) writes for a linear factor `c` (1 = no change).
static float3 encodeMultiply(float3 c) {
    return linearToSRGB(c);
}

// ---------------------------------------------------------------- vertex helpers
static MeshOut meshOut(constant Frame& F, float3 world, float3 normal, float3 color, float glow, float2 uv, float3 extra) {
    MeshOut o;
    o.position = F.viewProj * float4(world, 1.0);
    o.world = world;
    o.normal = normal;
    o.color = color;
    o.glow = glow;
    o.uv = uv;
    o.depth = -(F.view * float4(world, 1.0)).z;
    o.extra = extra;
    return o;
}

/// Corner `vid` (0…5) of a two-triangle quad over [-1, 1]²: (-1,-1) (1,-1) (1,1) (-1,-1) (1,1) (-1,1).
static float2 quadCorner(uint vid) {
    float x = (vid == 1u || vid == 2u || vid == 4u) ? 1.0 : -1.0;
    float y = (vid == 2u || vid == 4u || vid == 5u) ? 1.0 : -1.0;
    return float2(x, y);
}

static QuadOut quadOut(constant Frame& F, float3 w, float4 color, float2 uv, float4 params) {
    QuadOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.color = color;
    o.uv = uv;
    o.params = params;
    o.depth = -(F.view * float4(w, 1.0)).z;
    return o;
}

#endif
