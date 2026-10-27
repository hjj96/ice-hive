// ================================================================
//  PARTICLES — the GPU particle system (owned by WP5 «Эффекты»;
//  FX/GPUParticles.swift drives it).
//
//  One pool of particles lives in a device buffer and never goes back
//  to the CPU. Every frame (pre-pass 100, before the world pass):
//    fx_emit  the CPU's emitter records of the frame (one record →
//             N particles; position / velocity / size / colour drawn
//             from the record's ranges by a hash of its seed) are
//             written into the next N slots of the ring;
//    fx_sim   every slot: age, drag, gravity, deck bounce / stick /
//             fall into the abyss (a 128² deck height grid of the
//             level), the light at the particle for the lit kinds
//             (smoke, steam, gibs, ichor, casings: the four
//             flashlights' in-scatter, the light grid of WP2, the
//             ambient), then compaction: the live slots are appended to
//             two draw lists (additive, alpha) whose lengths are the
//             instance counts of two indirect draws (threadgroup
//             aggregated atomics: one global atomic per 256 slots).
//  The world pass draws the two lists (transparent items 500 alpha,
//  510 additive) with vs_gpart: camera-facing quads, velocity-stretched
//  for sparks / ice / gibs / ichor / casings, flipbook frames for fire,
//  blasts and smoke (8 × 8 atlases in Resources/FX), every sprite
//  capped at 25 % of the target's height (overdraw cap of the plan).
//  Struct layouts mirror FX/GPUParticles.swift (sizes asserted there).
// ================================================================
#include "Lighting.h"

// ---------------------------------------------------------------- kinds (FX/GPUParticles.swift PK)
#define PK_GLOW 0      // soft additive glow (motes, heal, pulse)
#define PK_FIRE 1      // flipbook flame (flamer jet, napalm, licks)
#define PK_SMOKE 2     // flipbook smoke, lit (alpha)
#define PK_SPARK 3     // velocity-stretched hot spark, cools white → orange → red, bounces
#define PK_EMBER 4     // small flickering ember, drifts
#define PK_ICE 5       // ice shard / frost glint, stretched, bounces
#define PK_DEBRIS 6    // dark gib / chunk, stretched, lit (alpha), bounces
#define PK_ICHOR 7     // ichor droplet, stretched while flying, sticks to the deck, lit (alpha)
#define PK_STEAM 8     // soft steam / frost mist, flipbook smoke, lit (alpha)
#define PK_CASING 9    // spent casing, brass, stretched, bounces, lit (alpha)
#define PK_FLASH 10    // four-ray hot star (hit flashes, blast cores)
#define PK_BLAST 11    // flipbook fireball
#define PK_DOT 12      // hard hot dot (target dots)

static inline bool pkAlpha(int k) { return k == PK_SMOKE || k == PK_DEBRIS || k == PK_ICHOR || k == PK_STEAM || k == PK_CASING; }
static inline bool pkStretch(int k) { return k == PK_SPARK || k == PK_ICE || k == PK_DEBRIS || k == PK_ICHOR || k == PK_CASING || k == PK_EMBER || k == PK_FIRE; }
static inline bool pkFlip(int k) { return k == PK_FIRE || k == PK_BLAST || k == PK_SMOKE || k == PK_STEAM; }
static inline float pkBounce(int k) {
    return k == PK_SPARK ? 0.38 : (k == PK_ICE ? 0.3 : (k == PK_DEBRIS ? 0.22 : (k == PK_CASING ? 0.42 : (k == PK_EMBER ? 0.15 : 0.0))));
}

// ---------------------------------------------------------------- data
struct Particle {
    float4 posAge;     // xyz world, w = age (s; < 0: waits for its start)
    float4 velLife;    // xyz m/s, w = life (s; 0 = free slot)
    float4 color;      // rgba: HDR colour (additive kinds) or albedo (lit kinds)
    float4 params;     // x size at birth, y size at death (m), z gravity (m/s²), w drag (1/s)
    float4 extra;      // x kind, y seed 0…1, z deck height under it (< −1e8: abyss), w spin (rad/s)
    float4 lit;        // rgb light at the particle (lit kinds), w = bounce factor (0 = the kind's default)
};

struct Emitter {
    float4 pos;        // xyz centre, w = ring radius (> 0: on a horizontal ring around the centre)
    float4 posJitter;  // xyz box half extents, w = max start delay (s)
    float4 vel;        // xyz base velocity, w = radial speed (outward in xz)
    float4 velJitter;  // xyz box half extents, w = spherical random speed
    float4 life;       // x min, y max (s), z size at birth, w size at death (m)
    float4 color;      // rgba
    float4 phys;       // x gravity, y drag, z size jitter (fraction), w radial-speed jitter (fraction)
    float4 extra;      // x spin (rad/s), y colour jitter (fraction), z bounce (0 = kind default), w unused
    uint4 meta;        // x first spawn index, y count, z seed, w kind | flags << 8
};
#define EF_UPPER 1u    // spherical speed only into the upper hemisphere
#define EF_NOFLOOR 2u  // ignores the deck (falls through: the lift shaft)

struct SimParams {
    uint4 counts;      // x slots simulated, y ring size (tier cap), z first ring slot of this frame's spawns, w spawns
    uint4 flags;       // x emitters, y 1 = clear every particle, z 1 = High tier, w list stride (slots allocated)
    float4 time;       // x dt, y time, z lift rise, w unused
    float4 lift;       // xyz lift centre, w radius (0 = no lift)
};

#define GROUND_N 128
#define GROUND_HALF 64.0

// ---------------------------------------------------------------- helpers
static inline uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static inline float rnd01(thread uint& s) {
    s = pcgHash(s);
    return float(s >> 8) * (1.0 / 16777216.0);
}

static inline float rnd11(thread uint& s) { return rnd01(s) * 2.0 - 1.0; }

/// Deck height at p from the level's cell grid (x = height at the cell centre, y = slope along z; x < −1e8 = abyss),
/// the lift deck riding up during the extraction.
static float groundAt(const device float2* G, float3 p, constant SimParams& S) {
    float fx = p.x + GROUND_HALF, fz = p.z + GROUND_HALF;
    if (fx < 0.0 || fz < 0.0 || fx >= float(GROUND_N) || fz >= float(GROUND_N)) return -1e9;
    int cx = int(fx), cz = int(fz);
    float2 g = G[cz * GROUND_N + cx];
    if (g.x < -1e8) return -1e9;
    float h = g.x + g.y * (p.z - (float(cz) - GROUND_HALF + 0.5));
    if (S.lift.w > 0.0) {
        float2 d = p.xz - S.lift.xz;
        if (dot(d, d) < S.lift.w * S.lift.w) h += S.time.z;
    }
    return h;
}

/// Light arriving at a point in the air (no surface): ambient, the flashlights' in-scatter with their cookies, and the
/// grid lights of its cell (WP2's light block) — radiance per unit albedo.
static float3 lightInAir(constant Frame& F, constant LightBlock& LB, float3 P) {
    float3 c = (F.hemiSky.rgb + F.hemiGround.rgb) * 0.65 + F.moonColor.rgb * 0.45;
    for (int i = 0; i < 4; i++) {
        float4 st = spotTermLB(F, LB, i, P);
        c += SPOT_COLOR * (st.w * 0.8);
    }
    uint mask = gridMask(LB, P);
    while (mask != 0u) {
        uint i = ctz(mask);
        mask &= mask - 1u;
        GridLight gl = LB.lights[i];
        float d = length(gl.posRange.xyz - P);
        c += gl.color.rgb * distanceAtten(d, gl.posRange.w, POINT_DECAY);
    }
    return c;
}

// ---------------------------------------------------------------- C0: emit
kernel void fx_emit(device Particle* P [[buffer(0)]],
                    const device Emitter* E [[buffer(1)]],
                    constant SimParams& S [[buffer(3)]],
                    const device float2* G [[buffer(6)]],
                    uint t [[thread_position_in_grid]]) {
    if (t >= S.counts.w || S.flags.x == 0u) return;
    // the emitter of spawn t: binary search over the records' first spawn indices
    uint lo = 0u, hi = S.flags.x - 1u;
    while (lo < hi) {
        uint mid = (lo + hi + 1u) >> 1;
        if (E[mid].meta.x <= t) lo = mid; else hi = mid - 1u;
    }
    Emitter e = E[lo];
    uint i = t - e.meta.x;
    if (i >= e.meta.y) return;
    uint s = pcgHash(e.meta.z ^ (i * 0x9E3779B9u));
    uint kind = e.meta.w & 255u, fl = e.meta.w >> 8;

    float3 pos = e.pos.xyz;
    float3 off = float3(rnd11(s), rnd11(s), rnd11(s)) * e.posJitter.xyz;
    float3 radial;
    if (e.pos.w > 0.0) {
        float a = rnd01(s) * 6.2831853;
        radial = float3(cos(a), 0.0, sin(a));
        pos += radial * e.pos.w;
    } else if (dot(off.xz, off.xz) > 1e-8) {
        radial = normalize(float3(off.x, 0.0, off.z));
    } else {
        float a = rnd01(s) * 6.2831853;
        radial = float3(cos(a), 0.0, sin(a));
    }
    pos += off;
    float3 v = e.vel.xyz + float3(rnd11(s), rnd11(s), rnd11(s)) * e.velJitter.xyz;
    v += radial * (e.vel.w * (1.0 + rnd11(s) * e.phys.w));
    if (e.velJitter.w > 0.0) {
        // uniform direction on the sphere (upper half when asked), speed 35–100 %
        float z = rnd11(s), a = rnd01(s) * 6.2831853;
        float r = sqrt(max(0.0, 1.0 - z * z));
        float3 d = float3(r * cos(a), z, r * sin(a));
        if ((fl & EF_UPPER) != 0u) d.y = abs(d.y);
        v += d * (e.velJitter.w * (0.35 + 0.65 * rnd01(s)));
    }
    float life = mix(e.life.x, e.life.y, rnd01(s));
    float sj = 1.0 + rnd11(s) * e.phys.z;
    float cj = 1.0 + rnd11(s) * e.extra.y;
    Particle p;
    p.posAge = float4(pos, -rnd01(s) * e.posJitter.w);
    p.velLife = float4(v, max(life, 0.01));
    p.color = float4(e.color.rgb * cj, e.color.a);
    p.params = float4(e.life.z * sj, e.life.w * sj, e.phys.x, e.phys.y);
    float g = (fl & EF_NOFLOOR) != 0u ? -1e9 : groundAt(G, pos, S);
    p.extra = float4(float(kind), rnd01(s), g, e.extra.x * rnd11(s));
    p.lit = float4(0.0, 0.0, 0.0, e.extra.z);
    uint ring = max(S.counts.y, 1u);
    P[(S.counts.z + t) % ring] = p;
}

// ---------------------------------------------------------------- C0: simulate, light, compact
kernel void fx_sim(device Particle* P [[buffer(0)]],
                   device uint* lists [[buffer(1)]],
                   device atomic_uint* args [[buffer(2)]],
                   constant SimParams& S [[buffer(3)]],
                   constant Frame& F [[buffer(4)]],
                   constant LightBlock& LB [[buffer(5)]],
                   const device float2* G [[buffer(6)]],
                   uint gid [[thread_position_in_grid]],
                   uint lid [[thread_position_in_threadgroup]]) {
    threadgroup atomic_uint tgN[3];
    threadgroup uint tgBase[2];
    if (lid == 0u) {
        atomic_store_explicit(&tgN[0], 0u, memory_order_relaxed);
        atomic_store_explicit(&tgN[1], 0u, memory_order_relaxed);
        atomic_store_explicit(&tgN[2], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int cls = -1;
    uint local = 0u;
    if (gid < S.counts.x) {
        Particle p = P[gid];
        if (S.flags.y != 0u) {
            if (p.velLife.w != 0.0) { p.velLife.w = 0.0; P[gid] = p; }
        } else if (p.velLife.w > 0.0) {
            float dt = S.time.x;
            float age = p.posAge.w + dt;
            int kind = int(p.extra.x + 0.5);
            if (age >= p.velLife.w) {
                p.velLife.w = 0.0;
            } else if (age < 0.0) {
                p.posAge.w = age;
            } else {
                float wasAge = p.posAge.w;
                float dtm = wasAge < 0.0 ? age : dt;   // a delayed particle moves only from its start
                float dr = 1.0 / (1.0 + p.params.w * dtm);
                float3 v = p.velLife.xyz;
                v.xz *= dr;
                v.y = v.y * dr - p.params.z * dtm;
                float3 was = p.posAge.xyz;
                float3 pos = was + v * dtm;
                if (p.params.z > 0.0 && pos.y < p.extra.z + 0.02) {
                    float g = groundAt(G, pos, S);
                    if (g > -1e8 && was.y >= g - 0.25) {
                        // landed on the deck: bounce, stick (ichor) or rest
                        pos.y = g + 0.02;
                        if (kind == PK_ICHOR) {
                            v = float3(0.0);
                            p.params.z = 0.0;
                        } else {
                            float b = p.lit.w > 0.0 ? p.lit.w : pkBounce(kind);
                            v.y = -v.y * b;
                            v.xz *= 0.55;
                            if (abs(v.y) < 0.35) { v.y = 0.0; v.xz *= 0.6; }
                            if (dot(v, v) < 0.01) { v = float3(0.0); p.params.z = 0.0; }
                        }
                        p.extra.z = g;
                    } else {
                        p.extra.z = g > -1e8 ? g - 0.25 : -1e9;   // over the abyss (or below the deck's edge): keeps falling
                    }
                }
                p.posAge = float4(pos, age);
                p.velLife.xyz = v;
                if (pkAlpha(kind)) p.lit.rgb = lightInAir(F, LB, pos);
                cls = pkAlpha(kind) ? 1 : 0;
                local = atomic_fetch_add_explicit(&tgN[cls], 1u, memory_order_relaxed);
                if (kind == PK_FIRE || kind == PK_BLAST) atomic_fetch_add_explicit(&tgN[2], 1u, memory_order_relaxed);
            }
            P[gid] = p;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lid == 0u) {
        uint n0 = atomic_load_explicit(&tgN[0], memory_order_relaxed);
        uint n1 = atomic_load_explicit(&tgN[1], memory_order_relaxed);
        uint n2 = atomic_load_explicit(&tgN[2], memory_order_relaxed);
        tgBase[0] = n0 > 0u ? atomic_fetch_add_explicit(&args[1], n0, memory_order_relaxed) : 0u;
        tgBase[1] = n1 > 0u ? atomic_fetch_add_explicit(&args[5], n1, memory_order_relaxed) : 0u;
        if (n2 > 0u) atomic_fetch_add_explicit(&args[8], n2, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (cls >= 0) lists[uint(cls) * S.flags.w + tgBase[cls] + local] = gid;
}

// ---------------------------------------------------------------- R2: draw
struct PartOut {
    float4 position [[position]];
    float4 color;
    float2 uv;        // -1 … 1 across the quad (x along the motion for stretched kinds)
    float4 info;      // x kind, y life fraction, z seed, w stretch (length / width)
    float4 fb;        // flipbook: xy origin of frame A, zw of frame B (atlas uv)
    float fbMix;
    float depth;
};

/// Fog transmittance of an additive sprite at `depth` (its light is scattered away, not replaced).
static inline float fogKeep(constant Frame& F, float depth) {
    float d = F.fog.w * depth;
    return exp(-d * d);
}

static inline float2 cellOf(float frame) {
    float f = clamp(floor(frame), 0.0, 63.0);
    return float2(fmod(f, 8.0), floor(f / 8.0)) * 0.125;
}

vertex PartOut vs_gpart(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant Frame& F [[buffer(1)]],
                        const device Particle* P [[buffer(2)]],
                        const device uint* list [[buffer(3)]]) {
    Particle p = P[list[iid]];
    int kind = int(p.extra.x + 0.5);
    float life = max(p.velLife.w, 1e-3);
    float t = saturate(p.posAge.w / life);
    float seed = p.extra.y;
    float3 C = p.posAge.xyz;
    float3 v = p.velLife.xyz;
    // size over the life: flames and blasts swell fast and settle, smoke keeps growing
    float grow = (kind == PK_FIRE || kind == PK_BLAST) ? 1.0 - (1.0 - t) * (1.0 - t) : t;
    float size = mix(p.params.x, p.params.y, grow);
    float4 col = p.color;
    float time = F.camPos.w;
    float age = p.posAge.w;
    switch (kind) {
        case PK_SPARK: {
            // cools white-hot → orange → dull red, the HDR tint of the record on top
            float hot = pow(1.0 - t, 1.6);
            float3 c = mix(float3(1.0, 0.18, 0.03), mix(float3(1.0, 0.55, 0.16), float3(1.0, 0.92, 0.75), saturate(hot * 1.6 - 0.6)), saturate(hot * 2.2));
            col.rgb = c * col.rgb * (0.6 + 3.4 * hot);
            col.a *= saturate((1.0 - t) * 3.0);
            break;
        }
        case PK_EMBER: {
            float fl = 0.65 + 0.35 * sin(time * 23.0 + seed * 61.0);
            col.rgb *= fl * (0.4 + 1.6 * (1.0 - t));
            col.a *= 1.0 - t * t;
            break;
        }
        case PK_ICE: {
            float tw = 0.5 + 0.5 * sin(time * 31.0 + seed * 97.0);
            col.rgb *= 0.7 + 1.5 * tw * (1.0 - t);
            col.a *= (1.0 - t);
            break;
        }
        case PK_FIRE:
        case PK_BLAST:
            col.a *= 1.0 - t * t * t;
            break;
        case PK_SMOKE:
        case PK_STEAM:
            col.a *= saturate(t * 7.0) * (1.0 - t) * (1.0 - t * 0.3);
            break;
        case PK_DEBRIS:
        case PK_CASING:
            col.a *= saturate((1.0 - t) * 5.0);
            break;
        case PK_ICHOR:
            col.a *= saturate((1.0 - t) * 3.0);
            break;
        case PK_FLASH:
            col.rgb *= (1.0 - t) * (1.0 - t);
            break;
        default:
            col.a *= 1.0 - t;
            break;
    }
    // lit kinds: the albedo under the light the simulation found at the particle
    float depth = max(0.05, -(F.view * float4(C, 1.0)).z);
    if (pkAlpha(kind)) {
        col.rgb = encodeColor(F, col.rgb * p.lit.rgb, depth, true);
    } else {
        col.rgb *= fogKeep(F, depth);
    }
    // the screen: pixels per metre here; a sprite never covers more than a quarter of the target's height, and one
    // thinner than a pixel and a half fades instead of shimmering
    float pxm = F.misc.x / depth;
    float maxM = 0.25 * F.misc.y / pxm;
    float minM = 1.5 / pxm;
    if (kind == PK_DOT) size = 3.2 / pxm * p.params.x;
    size = min(size, maxM);
    if (size < minM) { col.a *= size / minM; size = minM; }
    float3 R = F.camRight.xyz, U = F.camUp.xyz;
    float halfL = size * 0.5, halfW = size * 0.5;
    float stretch = 0.0;   // > 0: the quad's x runs along the motion (length / width)
    if (pkStretch(kind)) {
        // stretched along the motion on screen: length = size + the distance covered in ~1/30 s, capped
        float2 vs = float2(dot(v, R), dot(v, U));
        float sp = length(vs);
        if (sp > 0.05) {
            float2 d = vs / sp;
            float3 a = R * d.x + U * d.y;
            float3 b = R * -d.y + U * d.x;
            float k = kind == PK_SPARK ? 0.04 : (kind == PK_ICE ? 0.03 : (kind == PK_FIRE ? 0.035 : 0.022));
            halfL = min(size * 0.5 + sp * k, min(1.2, maxM * 0.5));
            if (kind == PK_DEBRIS || kind == PK_CASING) halfL = min(halfL, size * 1.6);
            // flames stretch only a little (a licking jet, not streaks), their frames rise along the motion
            if (kind == PK_FIRE) halfL = min(halfL, size * 0.95);
            R = a;
            U = b;
            stretch = halfL / max(halfW, 1e-4);
        }
    } else if (kind != PK_DOT) {
        // flipbooks and glows: a random roll per particle, spinning slowly; flames and smoke only lean (their frames
        // rise and are lit from above)
        bool upright = kind == PK_FIRE || kind == PK_SMOKE || kind == PK_STEAM;
        float ang = upright ? (seed - 0.5) * 0.7 + p.extra.w * age * 0.25 : seed * 6.2831853 + p.extra.w * age;
        float cs = cos(ang), sn = sin(ang);
        float3 r2 = R * cs + U * sn;
        U = U * cs - R * sn;
        R = r2;
    }
    float2 q = quadCorner(vid);
    float3 w = C + R * (q.x * halfL) + U * (q.y * halfW);
    PartOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.color = col;
    o.uv = q;
    o.info = float4(float(kind), t, seed, stretch);
    float frame = t * 63.0;
    o.fb = float4(cellOf(frame), cellOf(frame + 1.0));
    o.fbMix = fract(frame);
    o.depth = depth;
    return o;
}

/// One frame of an 8 × 8 flipbook atlas at sprite coordinates q (−1…1, +y up: the atlas's rows run top-down), inset
/// half a texel from the cell's edge.
static inline float4 flipTap(texture2d<float> atlas, float2 cell, float2 q) {
    float2 lu = clamp(float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5), 0.004, 0.996);
    return atlas.sample(clampSampler, cell + lu * 0.125);
}

/// Black-body-ish ramp of a flame's heat 0…1: deep red → orange → yellow → white-hot (linear, HDR above 1).
static inline float3 heatRamp(float h) {
    float3 c = mix(float3(0.35, 0.03, 0.005), float3(1.0, 0.32, 0.04), saturate(h * 2.2));
    c = mix(c, float3(1.0, 0.72, 0.28), saturate(h * 2.2 - 0.9));
    c = mix(c, float3(1.0, 0.95, 0.85), saturate(h * 2.5 - 1.7));
    return c * (0.5 + 2.6 * h * h);
}

fragment float4 fs_gpart_add(PartOut in [[stage_in]],
                             constant Frame& F [[buffer(1)]],
                             texture2d<float> noise [[texture(2)]],
                             texture2d<float> fireAtlas [[texture(6)]],
                             texture2d<float> blastAtlas [[texture(7)]]) {
    int kind = int(in.info.x + 0.5);
    float2 q = in.uv;
    float3 c = in.color.rgb;
    float a = in.color.a;
    if (kind == PK_FIRE || kind == PK_BLAST) {
        bool fire = kind == PK_FIRE;
        // a flame carried by its motion licks forward: the frame's up along the quad's x
        if (fire && in.info.w > 0.0) q = float2(-q.y, q.x);
        float4 s0 = fire ? flipTap(fireAtlas, in.fb.xy, q) : flipTap(blastAtlas, in.fb.xy, q);
        float4 s1 = fire ? flipTap(fireAtlas, in.fb.zw, q) : flipTap(blastAtlas, in.fb.zw, q);
        float4 s = mix(s0, s1, in.fbMix);
        // r = heat, g = density; the record's colour tints the ramp, its alpha fades it
        float heat = s.r * (1.15 - 0.55 * in.info.y);
        c = heatRamp(heat) * c;
        a *= s.g;
    } else if (kind == PK_SPARK || kind == PK_ICE || kind == PK_EMBER) {
        // a streak: hot thin core, brightest toward its head (+x), tapered tail
        float across = 1.0 - q.y * q.y;
        float along = smoothstep(-1.0, 0.2, q.x) * (1.0 - smoothstep(0.75, 1.0, q.x));
        float core = pow(saturate(across), in.info.w > 2.0 ? 6.0 : 2.5);   // long streaks: a thinner core
        a *= core * along;
        c *= 1.0 + 1.5 * pow(saturate(across), 12.0);
    } else if (kind == PK_FLASH) {
        // four thin rays and a hot core, rolled per particle
        float r = length(q);
        float ang = atan2(q.y, q.x) + in.info.z * 6.2831853;
        float rays = pow(abs(cos(ang * 2.0)), 24.0) * (1.0 - smoothstep(0.1, 1.0, r));
        float core = exp(-r * r * 18.0) * 1.6 + exp(-r * r * 4.0) * 0.35;
        a *= saturate(core + rays);
        c *= 1.0 + core;
    } else if (kind == PK_DOT) {
        float r = length(q);
        a *= exp(-r * r * 6.0) + 0.6 * exp(-r * r * 30.0);
    } else {
        // soft glow with a noise-broken edge
        float n = noise.sample(repeatSampler, q * 0.31 + in.info.z * float2(7.31, 3.17)).r;
        float d = length(q) * (0.8 + 0.4 * n);
        float m = saturate(1.0 - d);
        a *= m * m;
    }
    return float4(c, a);
}

fragment float4 fs_gpart_alpha(PartOut in [[stage_in]],
                               constant Frame& F [[buffer(1)]],
                               texture2d<float> noise [[texture(2)]],
                               texture2d<float> smokeAtlas [[texture(8)]]) {
    int kind = int(in.info.x + 0.5);
    float2 q = in.uv;
    float3 c = in.color.rgb;
    float a = in.color.a;
    if (kind == PK_SMOKE || kind == PK_STEAM) {
        float4 s = mix(flipTap(smokeAtlas, in.fb.xy, q), flipTap(smokeAtlas, in.fb.zw, q), in.fbMix);
        // r = self-shadowed shade (lit from above the camera), g = density
        c *= 0.45 + 0.95 * s.r;
        a *= s.g;
    } else if (kind == PK_DEBRIS) {
        // a jagged chunk: a hard noisy edge, a lit facet and a dark one
        float n = noise.sample(repeatSampler, q * 0.23 + in.info.z * float2(5.1, 9.7)).r;
        float d = length(q) * (0.75 + 0.5 * n);
        a *= 1.0 - smoothstep(0.78, 0.9, d);
        c *= q.x + q.y > 0.0 ? 1.15 : 0.6;
    } else if (kind == PK_ICHOR) {
        // a wet drop: round, a tiny specular glint
        float r = length(q);
        a *= 1.0 - smoothstep(0.7, 0.95, r);
        float g = exp(-dot(q - float2(0.35, 0.35), q - float2(0.35, 0.35)) * 30.0);
        c += float3(0.6, 0.55, 0.5) * g * 0.6;
    } else if (kind == PK_CASING) {
        // a brass cylinder: a bright line along it
        float across = abs(q.y);
        a *= (1.0 - smoothstep(0.75, 1.0, across)) * (1.0 - smoothstep(0.8, 1.0, abs(q.x)));
        c *= 0.6 + 1.6 * exp(-across * across * 10.0);
    }
    return float4(c, a);
}
