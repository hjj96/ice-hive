import Foundation

// ================================================================
//  GPU DATA LAYOUTS — Swift mirrors of the frame-wide structs in
//  Shaders/Common.h (Frame, Material, MeshInstance) and the buffer /
//  texture slots every shader file uses. Module structs live with
//  their owner (BugInstance: Swarm/WorldSwarm.swift ↔ SwarmTypes.h;
//  decal / sprite / particle / ribbon instances: FX/MetalEffects.swift
//  ↔ FX.metal). Every field is a float4 / float4x4 so Swift and MSL
//  agree on the layout without packing rules. Keep both sides in sync.
// ================================================================

/// Per-frame constants (`struct Frame` in Shaders/Common.h), buffer index BufferIndex.frame in every stage.
struct FrameUniforms {
    var viewProj = Mat4.identity
    var view = Mat4.identity
    /// xyz camera position, w = time (s).
    var camPos = F4(0, 0, 0, 0)
    /// rgb fog colour in display (sRGB) space, w = exp2 density.
    var fog = F4(0, 0, 0, 0)
    /// Hemisphere sky / ground colour × intensity / π (linear).
    var hemiSky = F4(0, 0, 0, 0)
    var hemiGround = F4(0, 0, 0, 0)
    /// Moon: xyz unit vector toward the light; colour × intensity / π.
    var moonDir = F4(0, 1, 0, 0)
    var moonColor = F4(0, 0, 0, 0)
    /// Four flashlights: xyz position, w = intensity / π (0 = off); xyz unit direction.
    var spotPos: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var spotDir: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    /// Three point lights: xyz position, w = cutoff distance; rgb = colour × intensity / π.
    var pointPos: (F4, F4, F4) = (.zero, .zero, .zero)
    var pointColor: (F4, F4, F4) = (.zero, .zero, .zero)
    /// x = pixels per metre at unit depth (web pxScale), y = world target height px, z = lift rise, w unused
    var misc = F4(0, 0, 0, 0)
    /// xyz camera right vector, w unused; xyz camera up vector (billboards).
    var camRight = F4(1, 0, 0, 0)
    var camUp = F4(0, 1, 0, 0)
    /// The player's flashlight shadow (web «высокая»: spots[0].castShadow): light view-projection (Metal depth 0…1).
    var shadowMatrix = Mat4.identity
    /// x = 1 shadows on, y = depth bias (three.js shadow.bias), z = 1 / map size, w unused.
    var shadowParams = F4(0, 0, 0, 0)
    /// x = noise taps of the particle mask (2; 1 on the low tier), yzw unused.
    var fx = F4(2, 0, 0, 0)
}

/// Generic instanced mesh (`struct MeshInstance`): marines, props, corpses, unlit bits.
struct MeshInstance {
    var model: Mat4
    /// rgb multiplies the vertex colour, w = emissive multiplier of aGlow.
    var tint: F4
    /// rgb added emissive (hurt / invulnerable flash), w = 1: replace the vertex colour by `tint.rgb` (unlit tips).
    var emissive: F4
}

/// Material constants of one static / instanced mesh draw (`struct Material`).
struct MaterialUniforms {
    /// x roughness, y metalness, z snow caps (0 / 1), w glow strength (web makeGlowMaterial glow).
    var pbr: F4
    /// x snow bias of the floor mask, y = 1 uses the floor texture, z = vertical offset (lift rise),
    /// w = 1 receives the flashlight shadow (three.js receiveShadow: floors, level props, hazard strips, corpses)
    var floor: F4
}

/// Buffer / texture slots shared with every shader file.
enum BufferIndex {
    static let vertices = 0
    static let frame = 1
    static let instances = 2
    static let material = 3
}

enum TextureIndex {
    static let main = 0
    static let snow = 1
    static let noise = 2
    static let shadow = 3
}
