// ================================================================
//  SHADERS — the Metal renderer of «Ледяной Улей» (-renderer metal).
//  Ports of the web game's three.js materials (game/js 03-render.js,
//  05-sim.js, 07-fx.js): MeshStandardMaterial (props, marines, floors
//  with the snow mask), the instanced Lambert bug material with leg
//  animation and glints, corpses, multiply decals, additive / alpha
//  particles, laser / tracer / beam ribbons, floor sprites and the
//  GPU-animated weather. Lighting: hemisphere + moon + 4 flashlights
//  (three.js spot attenuation) + 3 point lights; ACES filmic tone
//  mapping, sRGB encoding, then exp2 fog in display space (three.js
//  applies fog after the colour-space conversion when it renders to
//  the screen). The drawable is bgra8Unorm: blending happens on the
//  encoded values, like WebGL's default framebuffer.
//  Struct layouts mirror MetalShared.swift.
// ================================================================
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
};

struct Material {
    float4 pbr;     // roughness, metalness, snow caps, glow strength
    float4 floor;   // snow bias, (unused), vertical offset, unlit
};

struct BugInstance {
    float4 pos;     // xyz feet, w = horizontal scale
    float4 rot;     // cos(hd), sin(hd), sin(pitch), cos(pitch)
    float4 color;   // rgb tint, w = vertical scale
    float4 anim;    // phase, flash, burn, freeze
};

struct MeshInstance {
    float4x4 model;
    float4 tint;     // rgb multiplies the vertex colour
    float4 emissive; // rgb added emissive, w = 1 replaces the vertex colour by tint
};

struct DecalInstance {
    float4x4 model;
    float4 color;
    float4 uv;       // xy atlas cell offset
};

struct SpriteInstance {
    float4 center;   // xyz, w = mode (0 textured, 1 ring indicator)
    float4 axisU;    // xyz half extent, w = indicator progress
    float4 axisV;    // xyz half extent (v = 0 at center + axisV), w = indicator alpha
    float4 color;    // rgb, w = opacity
};

struct ParticleInstance {
    float4 pos;      // xyz, w = size (m)
    float4 color;    // rgba
    float4 extra;    // x = seed
};

struct RibbonVertex {
    float4 pos;      // xyz, w = mode
    float4 color;    // rgb, w = intensity
    float4 uv;
};

struct WeatherParams {
    float4 center;   // xyz camera target, w = kind (0 snow, 1 motes, 2 mist)
    float4 extra;    // x = particle count
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

// ---------------------------------------------------------------- constants
constant float PI_F = 3.14159265;
constant float3 SPOT_COLOR = float3(1.0, 0.8879, 0.7304);   // 0xfff2de, linear
constant float SPOT_COS_OUT = 0.87758;                       // cos(0.5)
constant float SPOT_COS_IN = 0.97479;                        // cos(0.5 * (1 - 0.55))
constant float SPOT_RANGE = 32.0;
constant float SPOT_DECAY = 1.35;
constant float POINT_DECAY = 2.0;

constant float3x3 ACES_IN = float3x3(float3(0.59719, 0.07600, 0.02840),
                                     float3(0.35458, 0.90834, 0.13383),
                                     float3(0.04823, 0.01566, 0.83777));
constant float3x3 ACES_OUT = float3x3(float3(1.60475, -0.10208, -0.00327),
                                      float3(-0.53108, 1.10813, -0.07276),
                                      float3(-0.07367, -0.00605, 1.07602));

constexpr sampler repeatSampler(filter::linear, mip_filter::linear, address::repeat);
constexpr sampler clampSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler dataSampler(filter::linear, address::clamp_to_edge);

// ---------------------------------------------------------------- tone mapping / output
static float3 acesFilmic(float3 c) {
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

/// tonemapping_fragment + colorspace_fragment (+ fog_fragment when fogged)
static float3 encodeColor(constant Frame& F, float3 lin, float depth, bool fogged) {
    float3 c = linearToSRGB(acesFilmic(lin));
    if (fogged) {
        float d = F.fog.w * depth;
        c = mix(c, F.fog.rgb, 1.0 - exp(-d * d));
    }
    return c;
}

// ---------------------------------------------------------------- lighting
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

/// Irradiance / PI of every light at P (Lambert; multiply by the albedo).
static float3 lambertLight(constant Frame& F, float3 P, float3 N) {
    float3 irr = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * N.y + 0.5);
    irr += F.moonColor.rgb * saturate(dot(N, F.moonDir.xyz));
    for (int i = 0; i < 4; i++) {
        float I = F.spotPos[i].w;
        if (I <= 0.0) continue;
        float3 Lv = F.spotPos[i].xyz - P;
        float d = length(Lv);
        float3 L = Lv / max(d, 1e-4);
        float cone = smoothstep(SPOT_COS_OUT, SPOT_COS_IN, dot(-L, F.spotDir[i].xyz));
        irr += SPOT_COLOR * (I * cone * distanceAtten(d, SPOT_RANGE, SPOT_DECAY) * saturate(dot(N, L)));
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
static float3 standardLight(constant Frame& F, float3 P, float3 N, float3 V, float3 albedo, float rough, float metal) {
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
        float k = I * cone * distanceAtten(d, SPOT_RANGE, SPOT_DECAY) * saturate(dot(N, L));
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

// ================================================================ static level meshes
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
                         constant Material& M [[buffer(3)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 albedo = in.color;
    if (M.pbr.z > 0.5) {
        albedo = mix(albedo, float3(0.80, 0.86, 0.93), smoothstep(0.72, 0.97, N.y) * (1.0 - in.glow) * 0.8);
    }
    float3 c = standardLight(F, in.world, N, V, albedo, M.pbr.x, M.pbr.y);
    c += in.color * in.glow * M.pbr.w + in.extra;
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

/// makeFloorMaterial: grating / slab texture + the world-space snow drift mask
fragment float4 fs_floor(MeshOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]],
                         constant Material& M [[buffer(3)]],
                         texture2d<float> map [[texture(0)]],
                         texture2d<float> snow [[texture(1)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float3 albedo = map.sample(repeatSampler, in.uv).rgb * in.color;
    float sm = snow.sample(dataSampler, (in.world.xz + 64.0) / 128.0).r + M.floor.x;
    float bar = smoothstep(0.08, 0.32, dot(albedo, float3(0.3333)));
    float fill = smoothstep(0.28, 0.72, sm) * step(0.5, N.y) * mix(0.55, 1.0, bar);
    albedo = mix(albedo, float3(0.68, 0.74, 0.82), fill);
    float rough = mix(M.pbr.x, 0.92, fill);
    float metal = mix(M.pbr.y, 0.0, fill);
    float3 c = standardLight(F, in.world, N, V, albedo, rough, metal);
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

/// textured standard material (hazard strips; the landing pad mark with its alpha)
fragment float4 fs_textured(MeshOut in [[stage_in]],
                            constant Frame& F [[buffer(1)]],
                            constant Material& M [[buffer(3)]],
                            texture2d<float> map [[texture(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float4 t = map.sample(repeatSampler, in.uv);
    float3 c = standardLight(F, in.world, N, V, t.rgb * in.color, M.pbr.x, M.pbr.y);
    return float4(encodeColor(F, c, in.depth, true), t.a);
}

/// floor light pools (additive, unlit, no fog) and the abyss haze plane (alpha, unlit, no fog)
fragment float4 fs_basic_textured(MeshOut in [[stage_in]],
                                  constant Frame& F [[buffer(1)]],
                                  texture2d<float> map [[texture(0)]]) {
    float4 t = map.sample(clampSampler, in.uv);
    return float4(encodeColor(F, t.rgb * in.color, in.depth, false), t.a);
}

// ================================================================ instanced meshes
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
                           constant Frame& F [[buffer(1)]]) {
    float3 N = normalize(in.normal);
    float3 c = lambertLight(F, in.world, N) * in.color;
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

/// MeshBasicMaterial (glob, grenade, beacon tip): tone mapped, no fog
fragment float4 fs_unlit(MeshOut in [[stage_in]],
                         constant Frame& F [[buffer(1)]]) {
    return float4(encodeColor(F, in.color, in.depth, false), 1.0);
}

// ================================================================ swarm
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
                       constant Frame& F [[buffer(1)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(F.camPos.xyz - in.world);
    float flash = in.extra.x, burn = in.extra.y, frz = in.extra.z;
    float3 albedo = mix(in.color, float3(0.2, 0.38, 0.55), frz * 0.8);
    albedo *= 1.0 - burn * 0.6;
    float3 c = lambertLight(F, in.world, N) * albedo;
    float rim = 1.0 - abs(dot(N, V));
    c += in.color * in.glow * (1.0 - frz);
    c += float3(0.22, 0.14, 0.26) * (rim * rim * rim * 0.3 * (1.0 - in.glow) * (1.0 - frz));
    c += float3(1.0, 0.3, 0.04) * (burn * (0.12 + 0.88 * in.glow) * 0.9);
    c += float3(1.0, 0.92, 0.88) * (flash * 0.8);
    c += float3(0.05, 0.16, 0.3) * (frz * 0.5);
    return float4(encodeColor(F, c, in.depth, true), 1.0);
}

// ================================================================ quads (decals, sprites, particles, ribbons)
constant float2 QUAD[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0) };

static QuadOut quadOut(constant Frame& F, float3 w, float4 color, float2 uv, float4 params) {
    QuadOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.color = color;
    o.uv = uv;
    o.params = params;
    o.depth = -(F.view * float4(w, 1.0)).z;
    return o;
}

// glints: every glow speckle of a visible bug again as an anti-aliased dot of at least ~1.6 drawable pixels, shaded
// exactly like the speckle itself (makeBugMaterial: lit vertex colour + aGlow emissive, tone mapped, fogged) and
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
        float3 Lv = F.spotPos[i].xyz - P;
        float d = length(Lv);
        float cone = smoothstep(SPOT_COS_OUT, SPOT_COS_IN, dot(-Lv / max(d, 1e-4), F.spotDir[i].xyz));
        irr += SPOT_COLOR * (I * cone * distanceAtten(d, SPOT_RANGE, SPOT_DECAY) * NL);
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
    float2 q = QUAD[vid];
    float3 v = w + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    QuadOut o = quadOut(F, v, float4(col, 1.0), q * hp, float4(0.5 * diam, 0.0, 0.0, 0.0));
    return o;
}

fragment float4 fs_glint(QuadOut in [[stage_in]]) {
    // uv in drawable px from the centre; params.x = radius (px)
    float a = saturate(in.params.x + 0.5 - length(in.uv));
    return float4(in.color.rgb, a);
}

// persistent floor stains: multiply blend over the lit floor (07-fx.js decalMat)
vertex QuadOut vs_decal(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Frame& F [[buffer(1)]],
                        const device DecalInstance* I [[buffer(2)]]) {
    DecalInstance d = I[iid];
    float2 q = QUAD[vid] * 0.5;
    float3 w = (d.model * float4(q.x, 0.0, q.y, 1.0)).xyz;
    float2 uv = float2(q.x + 0.5, q.y + 0.5) * 0.5 + d.uv.xy;
    return quadOut(F, w, d.color, uv, float4(0.0));
}

fragment float4 fs_decal(QuadOut in [[stage_in]],
                         texture2d<float> atlas [[texture(0)]]) {
    float4 t = atlas.sample(clampSampler, in.uv);
    float3 c = mix(float3(1.0), t.rgb * in.color.rgb, t.a);
    return float4(linearToSRGB(c), 1.0);
}

// flat floor sprites: light pools / splashes / telegraphs / team rings (textured, additive) and the beacon / lift /
// revive progress rings (procedural, ringIndMat)
vertex QuadOut vs_sprite(uint vid [[vertex_id]], uint iid [[instance_id]],
                         constant Frame& F [[buffer(1)]],
                         const device SpriteInstance* I [[buffer(2)]]) {
    SpriteInstance s = I[iid];
    float2 q = QUAD[vid];
    float3 w = s.center.xyz + s.axisU.xyz * q.x + s.axisV.xyz * q.y;
    return quadOut(F, w, s.color, q, float4(s.center.w, s.axisU.w, s.axisV.w, 0.0));
}

fragment float4 fs_sprite(QuadOut in [[stage_in]],
                          constant Frame& F [[buffer(1)]],
                          texture2d<float> map [[texture(0)]]) {
    float2 p = in.uv;   // -1 … 1 along u, v
    if (in.params.x < 0.5) {
        float4 t = map.sample(clampSampler, float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5));
        return float4(encodeColor(F, t.rgb * in.color.rgb, in.depth, false), t.a * in.color.a);
    }
    float prog = in.params.y, alpha = in.params.z, time = F.camPos.w;
    float r = length(p);
    float ang = fract(atan2(p.x, p.y) / 6.2831853 + 1.0);
    float ring = smoothstep(0.84, 0.865, r) * (1.0 - smoothstep(0.955, 0.98, r));
    float seg = step(0.3, fract(ang * 40.0));
    float pr = step(ang, prog);
    float inner = (1.0 - smoothstep(0.0, 0.86, r)) * 0.05 * (0.6 + 0.4 * sin(time * 3.0 - r * 8.0));
    float sweep = (1.0 - smoothstep(0.0, 0.86, abs(r - fract(time * 0.5) * 0.86))) * 0.12 * step(r, 0.86);
    float3 c = in.color.rgb * (ring * (pr * 1.7 + (1.0 - pr) * 0.35 * seg) + inner + sweep * (1.0 - step(0.999, prog)));
    return float4(encodeColor(F, c * alpha, in.depth, false), 1.0);
}

// particles: camera-facing quads with the web point-sprite size rule (size * pxScale / depth, 1…300 px)
vertex QuadOut vs_particle(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Frame& F [[buffer(1)]],
                           const device ParticleInstance* I [[buffer(2)]]) {
    ParticleInstance p = I[iid];
    float2 q = QUAD[vid];
    float z = max(0.05, -(F.view * float4(p.pos.xyz, 1.0)).z);
    float px = clamp(p.pos.w * F.misc.x / z, 1.0, 300.0);
    float hs = 0.5 * px * z / F.misc.x;
    float3 w = p.pos.xyz + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    return quadOut(F, w, p.color, q * 0.5, float4(p.extra.x, 0.0, 0.0, 0.0));
}

static float particleMask(float2 q, float seed, texture2d<float> noise) {
    float n = noise.sample(repeatSampler, q * 0.31 + seed * float2(7.31, 3.17)).r * 0.6
            + noise.sample(repeatSampler, q * 0.69 - seed * float2(2.93, 5.71)).r * 0.4;
    float d = length(q) * 2.0 * (0.75 + 0.5 * n);
    return 1.0 - smoothstep(0.0, 1.0, d);
}

fragment float4 fs_particle_add(QuadOut in [[stage_in]],
                                constant Frame& F [[buffer(1)]],
                                texture2d<float> noise [[texture(2)]]) {
    float a = particleMask(in.uv, in.params.x, noise);
    a *= a;
    return float4(encodeColor(F, in.color.rgb, in.depth, false), in.color.a * a);
}

fragment float4 fs_particle_alpha(QuadOut in [[stage_in]],
                                  constant Frame& F [[buffer(1)]],
                                  texture2d<float> noise [[texture(2)]]) {
    float a = particleMask(in.uv, in.params.x, noise);
    a = smoothstep(0.0, 0.6, a);
    return float4(encodeColor(F, in.color.rgb, in.depth, false), in.color.a * a);
}

// ribbons: laser sights (dash texture), tracers (flat), cryo beam (streak noise), beacon beams (vertical fade)
vertex QuadOut vs_ribbon(uint vid [[vertex_id]],
                         constant Frame& F [[buffer(1)]],
                         const device RibbonVertex* V [[buffer(2)]]) {
    RibbonVertex r = V[vid];
    return quadOut(F, r.pos.xyz, r.color, r.uv.xy, float4(r.pos.w, 0.0, 0.0, 0.0));
}

fragment float4 fs_ribbon(QuadOut in [[stage_in]],
                          constant Frame& F [[buffer(1)]],
                          texture2d<float> dash [[texture(0)]],
                          texture2d<float> streak [[texture(1)]]) {
    float mode = in.params.x;
    float time = F.camPos.w;
    float2 uv = in.uv;
    float3 c;
    if (mode < 0.5) {
        float across = 1.0 - abs(uv.y * 2.0 - 1.0);
        across *= across;
        float d = dash.sample(repeatSampler, float2(uv.x * 1.6 - time * 2.5, 0.5)).r;
        c = in.color.rgb * across * (0.45 + 0.55 * d);
    } else if (mode < 1.5) {
        c = in.color.rgb;
    } else if (mode < 2.5) {
        float across = 1.0 - abs(uv.y * 2.0 - 1.0);
        float n = streak.sample(repeatSampler, float2(uv.x * 0.9 - time * 3.2, uv.y)).r
                + streak.sample(repeatSampler, float2(uv.x * 0.5 - time * 1.7, uv.y * 0.7 + 0.2)).r;
        float core = pow(across, 3.0) * 1.4;
        float fade = smoothstep(0.0, 0.08, uv.x) * (1.0 - smoothstep(0.75, 1.0, uv.x));
        c = float3(0.45, 0.85, 1.25) * (across * n * 0.9 + core) * fade * in.color.w;
    } else {
        float k = 1.0 - uv.x;
        float across = 1.0 - abs(uv.y * 2.0 - 1.0);
        c = in.color.rgb * in.color.w * k * k * (0.35 + 0.65 * across);
    }
    return float4(encodeColor(F, c, in.depth, false), 1.0);
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
    float2 q = QUAD[vid];
    float3 w = p + (F.camRight.xyz * q.x + F.camUp.xyz * q.y) * hs;
    return quadOut(F, w, float4(col, alpha), q * 0.5, float4(kind, seed, 0.0, 0.0));
}

fragment float4 fs_weather(QuadOut in [[stage_in]],
                           constant Frame& F [[buffer(1)]]) {
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
    return float4(encodeColor(F, in.color.rgb, in.depth, false), a);
}
