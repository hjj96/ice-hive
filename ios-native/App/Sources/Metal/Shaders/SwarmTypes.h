// ================================================================
//  SWARM TYPES — GPU structs of the swarm (owned by WP3 «Рой»), shared
//  by Swarm.metal and any other file that reads bug instances. Swift
//  mirror: BugInstance in Swarm/WorldSwarm.swift.
// ================================================================
#ifndef ICEHIVE_SWARM_TYPES_H
#define ICEHIVE_SWARM_TYPES_H

#include "Common.h"

struct BugInstance {
    float4 pos;     // xyz feet, w = horizontal scale
    float4 rot;     // cos(hd), sin(hd), sin(pitch), cos(pitch)
    float4 color;   // rgb tint, w = vertical scale
    float4 anim;    // phase, flash, burn, freeze
};

#endif
