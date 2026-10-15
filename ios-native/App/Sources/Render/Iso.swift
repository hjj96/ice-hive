import SpriteKit
import IceHiveCore

// ================================================================
//  ISO — the orthographic 3/4 projection of the asset manifest
//  (yaw 45°, pitch 57°, 24 pt per metre). Every sprite of the world
//  lives in "world points": u = (x − z)·0.707107·24 (right),
//  v = (y·0.544639 − (x + z)·0.593030)·24 (up). The camera scales
//  the whole world to the web game's field of view.
// ================================================================
enum Iso {
    /// Points per metre in world space (the sprites' native scale).
    static let ppm: CGFloat = 24
    static let ppmF: Float = 24
    static let cosYaw: Float = 0.707107
    static let sinPitch: Float = 0.838671
    static let cosPitch: Float = 0.544639
    /// cosYaw · sinPitch: ground depth (x + z) to screen v.
    static let depthK: Float = 0.593030
    /// Flat (top-down) textures sit in a container with this yScale.
    static let groundSquash: CGFloat = 0.838671

    /// World point (x, height y, z) → world points.
    @inline(__always) static func point(_ x: Float, _ y: Float, _ z: Float) -> CGPoint {
        let u = (x - z) * cosYaw * ppmF
        let v = (y * cosPitch - (x + z) * depthK) * ppmF
        return CGPoint(x: CGFloat(u), y: CGFloat(v))
    }

    /// Larger = closer to the camera = drawn later.
    @inline(__always) static func nearness(_ x: Float, _ y: Float, _ z: Float) -> CGFloat {
        CGFloat((x + z) * 0.385118 + y * sinPitch)
    }

    /// 16-direction index of a world heading (atan2(dx, dz)); dir 0 faces world +z.
    @inline(__always) static func dir16(_ heading: Float) -> Int {
        if !heading.isFinite { return 0 }
        let k = Int((heading * (16 / (2 * Float.pi))).rounded())
        return k & 15
    }

    /// Ground point (x, z) under a world-points position, assuming the floor height `y`.
    static func ground(from p: CGPoint, height y: Float) -> Vec2 {
        let u = Float(p.x) / ppmF, v = Float(p.y) / ppmF
        let a = u / cosYaw                      // x − z
        let b = (y * cosPitch - v) / depthK     // x + z
        return Vec2((a + b) * 0.5, (b - a) * 0.5)
    }

    /// Screen-space angle (radians, SpriteKit convention) of a world ground direction (dx, dz).
    @inline(__always) static func screenAngle(_ dx: Float, _ dz: Float) -> CGFloat {
        let u = (dx - dz) * cosYaw
        let v = -(dx + dz) * depthK
        return CGFloat(atan2(Double(v), Double(u)))
    }

    /// zRotation for a flat texture inside a ground container (manifest: r − π/4, r = web rotation about +y).
    @inline(__always) static func groundRotation(_ r: Float) -> CGFloat { CGFloat(r) - .pi / 4 }

    /// Positive modulo for frame indices.
    @inline(__always) static func wrap(_ v: Int, _ n: Int) -> Int {
        let r = v % n
        return r < 0 ? r + n : r
    }

    /// Frame index of a looping phase (radians) split into n frames.
    @inline(__always) static func phaseFrame(_ ph: Float, _ n: Int) -> Int {
        if !ph.isFinite { return 0 }
        let f = ph / (2 * Float.pi) * Float(n)
        let k = Int(f - Float(n) * (f / Float(n)).rounded(.down))
        return k < 0 ? 0 : (k >= n ? n - 1 : k)
    }
}

// ================================================================
//  Z BANDS — with ignoresSiblingOrder every leaf node carries an
//  absolute zPosition (all containers stay at z = 0).
// ================================================================
enum ZBand {
    static let background: CGFloat = -10000
    static let under: CGFloat = -9000
    static let floor: CGFloat = -8000
    static let floorDecal: CGFloat = -7000
    static let decal: CGFloat = -6900
    static let corpse: CGFloat = -6800
    static let shadow: CGFloat = -6700
    /// Railings / posts / lamps on far (N / W) platform edges: behind everything standing on the deck.
    static let farEdge: CGFloat = -400
    /// Objects: + nearness · objectScale (props, bugs, marines), nearness within ±60.
    static let objects: CGFloat = 0
    static let objectScale: CGFloat = 4
    /// Railings / posts / lamps on near (S / E) edges: in front of everything on the deck.
    static let nearEdge: CGFloat = 400
    /// Full-screen darkness / flashlight overlay (camera child).
    static let darkness: CGFloat = 1000
    /// Additive floor light: glow pools, team rings, telegraphs, indicators.
    static let floorGlow: CGFloat = 1100
    /// Additive emissive layers of sprites (*Glow atlases).
    static let glow: CGFloat = 1200
    static let beams: CGFloat = 1250
    static let particlesAlpha: CGFloat = 1300
    static let particlesAdd: CGFloat = 1400
    static let hud: CGFloat = 5000

    @inline(__always) static func object(_ nearness: CGFloat) -> CGFloat { objects + nearness * objectScale }
}

// ================================================================
//  TONE — the web colours are linear HDR values pushed through ACES
//  filmic + sRGB (three.js ACESFilmicToneMapping, exposure 1).
// ================================================================
enum Tone {
    @inline(__always) private static func fit(_ v: Float) -> Float {
        let a = v * (v + 0.0245786) - 0.000090537
        let b = v * (0.983729 * v + 0.4329510) + 0.238081
        return a / b
    }
    @inline(__always) private static func srgb(_ c: Float) -> Float {
        let v = max(0, min(1, c))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
    }
    /// Display colour (sRGB 0…1) of a linear web colour.
    static func display(_ r0: Float, _ g0: Float, _ b0: Float) -> (Float, Float, Float) {
        let k: Float = 1 / 0.6
        let r = r0 * k, g = g0 * k, b = b0 * k
        let ri = fit(0.59719 * r + 0.35458 * g + 0.04823 * b)
        let gi = fit(0.07600 * r + 0.90834 * g + 0.01566 * b)
        let bi = fit(0.02840 * r + 0.13383 * g + 0.83777 * b)
        let ro = 1.60475 * ri - 0.53108 * gi - 0.07367 * bi
        let go = -0.10208 * ri + 1.10813 * gi - 0.00605 * bi
        let bo = -0.00327 * ri - 0.07276 * gi + 1.07602 * bi
        return (srgb(ro), srgb(go), srgb(bo))
    }
    static func color(_ r: Float, _ g: Float, _ b: Float, alpha: CGFloat = 1) -> SKColor {
        let d = display(r, g, b)
        return SKColor(red: CGFloat(d.0), green: CGFloat(d.1), blue: CGFloat(d.2), alpha: alpha)
    }
    /// sRGB hex (0xRRGGBB) → SKColor.
    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> SKColor {
        SKColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                blue: CGFloat(v & 255) / 255, alpha: alpha)
    }
    /// sRGB hex → linear components (web: THREE.Color.setHex).
    static func linear(_ v: UInt32) -> (Float, Float, Float) {
        func l(_ c: UInt32) -> Float {
            let s = Float(c) / 255
            return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4)
        }
        return (l((v >> 16) & 255), l((v >> 8) & 255), l(v & 255))
    }
}
