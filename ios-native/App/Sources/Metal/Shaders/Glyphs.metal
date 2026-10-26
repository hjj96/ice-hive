// ================================================================
//  GLYPHS (owned by WP4 «Отряд») — the ground glyphs of GroundGlyphs
//  .swift: analytic shapes on deck quads, anti-aliased by fwidth,
//  written as linear radiance into a MAX-blended pipeline (overlaps
//  keep the brightest, never sum to white):
//    kind 0  HP arc: 300° open behind the marine, pips, the armour left
//            lit (the rest a dim track), an aim chevron outside it; the
//            player's thin pale inner arc: magazine / heat (blinks on
//            overheat / reload)
//    kind 1  downed: a pulsing red ring filling white with the revive
//            progress, a cross in the middle
//    kind 2  segmented ring (beacons, the lift): segments light up with
//            the progress, slowly turning
// ================================================================
#include "Common.h"

struct GlyphInstance {
    float4 center;   // xyz, w = radius (m)
    float4 color;    // rgb linear radiance, w = kind
    float4 a;        // arc: hp, pips, aim angle, player · ring: progress, segments, rotation, alpha
    float4 b;        // x = time, y = pulse, z = the player's magazine / heat (−1 none), w = 1 blinking
};

struct GlyphOut {
    float4 position [[position]];
    float2 uv;       // radius units: x along world +x, y along world +z
    float4 color;
    float4 a;
    float4 b;
};

#define GLYPH_EXTENT 1.4

vertex GlyphOut vs_glyph(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         constant Frame& F [[buffer(1)]],
                         const device GlyphInstance* G [[buffer(2)]]) {
    GlyphInstance g = G[iid];
    float2 c = quadCorner(vid) * GLYPH_EXTENT;
    float3 w = g.center.xyz + float3(c.x, 0.0, c.y) * g.center.w;
    GlyphOut o;
    o.position = F.viewProj * float4(w, 1.0);
    o.uv = c;
    o.color = g.color;
    o.a = g.a;
    o.b = g.b;
    return o;
}

static inline float band(float r, float r0, float r1, float aa) {
    return smoothstep(r0 - aa, r0 + aa, r) * (1.0 - smoothstep(r1 - aa, r1 + aa, r));
}

/// Angle of p about +y measured from +z toward +x, wrapped relative to `ref` into (−π, π].
static inline float relAngle(float2 p, float ref) {
    float a = atan2(p.x, p.y) - ref;
    return a - 2.0 * M_PI_F * floor((a + M_PI_F) / (2.0 * M_PI_F));
}

fragment float4 fs_glyph(GlyphOut in [[stage_in]]) {
    float2 p = in.uv;
    float r = length(p);
    float aa = max(fwidth(r), 1e-4) * 0.9;
    int kind = int(in.color.w + 0.5);
    float3 col = in.color.rgb;
    float3 outc = float3(0.0);
    if (kind == 0) {
        bool player = in.a.w > 0.5;
        float hp = in.a.x, pips = max(1.0, in.a.y);
        float rel = relAngle(p, in.a.z);
        float span = 2.6179939;      // 150°
        float ang = abs(rel);
        float arcw = max(fwidth(rel), 1e-4) * 1.2;
        float onArc = 1.0 - smoothstep(span - arcw, span + arcw, ang);
        float ring = band(r, player ? 0.86 : 0.88, 1.0, aa) * onArc;
        // fill: from the left end (rel = −span) round to the right end
        float s = (rel + span) / (2.0 * span);
        float sw = max(fwidth(s), 1e-4);
        float lit = 1.0 - smoothstep(hp - sw, hp + sw, s);
        // pip gaps
        float f = fract(s * pips);
        float gw = 0.035 * pips / 6.0 + sw * pips;
        float gap = smoothstep(0.0, gw, f) * (1.0 - smoothstep(1.0 - gw, 1.0, f));
        float3 c = mix(col * 0.16, col, lit);
        outc = c * ring * mix(0.35, 1.0, gap);
        // aim chevron, just outside the arc
        float rr = r - 1.08;
        float wedge = (0.2 - rr) * 0.55;
        float chev = step(0.0, rr) * step(rr, 0.2) * (1.0 - smoothstep(wedge - aa, wedge + aa, abs(rel) * r));
        outc = max(outc, col * (player ? 1.3 : 1.0) * chev);
        // the player's thin outer hairline
        if (player) outc = max(outc, col * 0.35 * band(r, 1.3, 1.34, aa) * onArc);
        // the player's magazine / heat: a thin pale inner arc filling the same way
        if (in.b.z >= 0.0) {
            float mag = 1.0 - smoothstep(in.b.z - sw, in.b.z + sw, s);
            float blink = in.b.w > 0.5 ? (sin(in.b.x * 18.0) > 0.0 ? 1.0 : 0.25) : 0.8;
            float3 pale = float3(0.72, 0.79, 0.85);
            outc = max(outc, pale * blink * mix(0.12, 1.0, mag) * band(r, 0.76, 0.81, aa) * onArc);
        }
    } else if (kind == 1) {
        float pulse = in.b.y;
        float rel = relAngle(p, 0.0);
        float s = (rel + M_PI_F) / (2.0 * M_PI_F);
        float sw = max(fwidth(s), 1e-4);
        float filled = 1.0 - smoothstep(in.a.x - sw, in.a.x + sw, s);
        float ring = band(r, 0.84, 1.0, aa);
        float3 base = col * (0.45 + 0.55 * pulse);
        float3 c = mix(base, float3(1.0, 0.9, 0.85) * 1.2, filled);
        outc = c * ring;
        float cw = 0.075, cl = 0.34;
        float2 q = abs(p);
        float crossv = max(step(q.x, cw) * step(q.y, cl), step(q.y, cw) * step(q.x, cl));
        outc = max(outc, col * (0.5 + 0.5 * pulse) * crossv);
    } else {
        float alpha = in.a.w;
        float segs = max(1.0, in.a.y);
        float rel = relAngle(p, in.a.z);
        float s = (rel + M_PI_F) / (2.0 * M_PI_F);
        float f = fract(s * segs);
        float idx = floor(s * segs);
        float sw = max(fwidth(s), 1e-4) * segs;
        float seg = smoothstep(0.08, 0.08 + sw, f) * (1.0 - smoothstep(0.92 - sw, 0.92, f));
        float lit = step(idx + 0.5, in.a.x * segs);
        float ring = band(r, 0.94, 1.0, aa);
        outc = col * ring * seg * mix(0.16, 1.0, lit) * alpha;
        // a faint inner hairline
        outc = max(outc, col * 0.12 * alpha * band(r, 0.9, 0.91, aa));
    }
    return float4(outc, 1.0);
}
