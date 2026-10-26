// ================================================================
//  SWARM TYPES — GPU structs of the swarm (owned by WP3 «Рой»), shared
//  by Swarm.metal and any other file that reads creature instances.
//  Swift mirrors: CreatureInstance / SwarmParams / GlintSocket in
//  Swarm/WorldSwarm.swift (sizes asserted there). The vertex record is
//  the IHV1 rigid vertex of tools/blender/ihv.py.
// ================================================================
#ifndef ICEHIVE_SWARM_TYPES_H
#define ICEHIVE_SWARM_TYPES_H

#include "Common.h"

/// IHV1 rigid vertex (20 bytes): rgb albedo (sRGB) + baked AO; glow, roughness, bone, flags; half rest position + gland
/// phase; snorm8 rest normal. Flags: bit0 gland · bit1 eye · bit2 carapace edge · bit3 socket point · bit4 sac.
struct IhvVertex {
    uchar4 albedoAO;
    uchar4 material;
    packed_half4 rest;
    packed_char4 nrm;
};

#define IHV_GLAND 1u
#define IHV_EYE 2u
#define IHV_EDGE 4u
#define IHV_SAC 16u

/// One creature in a draw (80 bytes): a live bug, a corpse or a bug-sheet specimen.
struct CreatureInstance {
    float4 pos;     // xyz feet (world), w = horizontal scale
    float4 rot;     // cos(heading), sin(heading), sin(pitch), cos(pitch)
    float4 tint;    // rgb albedo tint (value / hue variation), w = vertical scale
    uint4  anim;    // x = clip A rows (r0 | r1 << 16), y = clip B rows, z = unorm16 frac A | frac B << 16,
                    // w = unorm16 weight of B | type << 16 | flags << 24 (CI_QUEEN, CI_CORPSE)
    uint4  fx;      // x = unorm8 ×4: hit flash, burn, frost, dead (0 live → 1 the corpse value band)
                    // y = snorm16 ×2: lean (world x, z tilt in radians — the hit recoil away from the impact)
                    // z = unorm16 seed | unorm16 glow boost << 16 (the attack's gland flare, swell pulse)
                    // w = 0
};

#define CI_QUEEN 1u
#define CI_CORPSE 2u

/// Per bug type constants (linear radiance; WorldSwarm.typeLook).
struct SwarmType {
    float4 rim;     // rgb cold Fresnel rim tint of the type, w = strength
    float4 eye;     // rgb eye colour, w = intensity
    float4 sac;     // rgb sac colour (translucent belly / acid / gas), w = inner glow
    float4 gland;   // rgb gland (pore) emission, w = intensity
    float4 proxy;   // xyz shadow proxy half size (model m), w = proxy centre height (model m)
    uint4  glint;   // x = first socket in the glint table, y = glint sockets, z = first glint instance, w = live bugs
};

struct SwarmParams {
    SwarmType types[4];
    float4 info;    // x = time, y = 1 bug-sheet studio light, z = glint min size (drawable px), w = glint size scale
    float4 queen;   // rgb rim of the Матка, w = unused
};

/// A gland drawn as a glint sprite (WorldSwarm uploads the four types' tables, 32 bytes each).
struct GlintSocket {
    float4 pos;     // xyz rest position (model), w = bone index
    float4 info;    // x = radius (m), y = intensity, z = 1 hot (pink-white) / 0 dim (red), w = gland phase
};

#endif
