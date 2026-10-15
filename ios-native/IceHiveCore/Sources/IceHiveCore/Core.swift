import Foundation

// ================================================================
//  CORE — constants and small math helpers (port of 01-core.js)
//  World space: x right/left, z toward the camera; the simulation
//  is 2D on the XZ plane, every visual height comes from Level.groundY.
//  Angles follow the JS convention: aim = atan2(dx, dz), so the unit
//  direction of an angle a is (sin a, cos a).
// ================================================================

/// 2D world vector (x, z).
public typealias Vec2 = SIMD2<Float>

public let TAU: Float = Float.pi * 2
/// Fixed simulation step (60 Hz).
public let SIM_DT: Float = 1.0 / 60.0
/// Bug array capacity (the bench may push 3000).
public let MAX_BUGS: Int = 3200
/// Walk grid / spatial hash: G x G cells of 1 m.
public let GRID: Int = 128
/// Half extent: world x, z in [-64, 64).
public let GRID_HALF: Float = 64
/// Camera yaw used by the web game (camera sits at +x,+z looking toward -x,-z).
/// Screen axes expressed in world XZ: screen-up = forward.
public let FWD_X: Float = -0.70710678118
public let FWD_Z: Float = -0.70710678118
public let RIGHT_X: Float = 0.70710678118
public let RIGHT_Z: Float = -0.70710678118

@inline(__always) func clampf(_ v: Float, _ a: Float, _ b: Float) -> Float { v < a ? a : (v > b ? b : v) }
@inline(__always) func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func hypotf2(_ a: Float, _ b: Float) -> Float { (a * a + b * b).squareRoot() }
@inline(__always) func smooth01(_ t0: Float) -> Float { let t = clampf(t0, 0, 1); return t * t * (3 - 2 * t) }
/// Shortest signed angle from a to b, in (-pi, pi].
@inline(__always) func angDiff(_ a: Float, _ b: Float) -> Float {
    let d = b - a
    if d > -Float.pi && d <= Float.pi { return d }
    if !d.isFinite { return 0 }
    return d.remainder(dividingBy: TAU)
}
/// floor() to Int that never traps (NaN / huge values clamp far outside the grid).
@inline(__always) func floorInt(_ v: Float) -> Int {
    if v >= -1_000_000 && v <= 1_000_000 { return Int(v.rounded(.down)) }
    return v > 0 ? 1_000_000 : -1_000_000
}
@inline(__always) func atan2f2(_ y: Float, _ x: Float) -> Float { Float(atan2(Double(y), Double(x))) }
@inline(__always) func sinf2(_ a: Float) -> Float { Float(sin(Double(a))) }
@inline(__always) func cosf2(_ a: Float) -> Float { Float(cos(Double(a))) }
@inline(__always) func expf2(_ a: Float) -> Float { Float(exp(Double(a))) }
@inline(__always) func powf2(_ a: Float, _ b: Float) -> Float { Float(pow(Double(a), Double(b))) }

/// "m:ss" like the web HUD.
public func formatTime(_ s0: Float) -> String {
    let s = max(0, Int(s0.isFinite ? s0.rounded(.down) : 0))
    let sec = s % 60
    return "\(s / 60):" + (sec < 10 ? "0\(sec)" : "\(sec)")
}

// ================================================================
//  Seeded RNG — mulberry32 (same generator the web game uses for its
//  procedural art). ALL simulation randomness goes through one
//  instance owned by the Game, so a seed reproduces a run exactly.
// ================================================================
public struct SeededRNG {
    public private(set) var state: UInt32

    public init(seed: UInt32) { state = seed }

    /// Next raw 32-bit value.
    @inline(__always) public mutating func nextUInt32() -> UInt32 {
        state = state &+ 0x6D2B_79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return t ^ (t >> 14)
    }

    /// Uniform in [0, 1) (24 random bits: never returns 1.0).
    @inline(__always) public mutating func next() -> Float {
        Float(nextUInt32() >> 8) * (1.0 / 16_777_216.0)
    }

    /// Uniform in [a, b).
    @inline(__always) public mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }

    /// Uniform integer in [0, n) (n > 0).
    @inline(__always) public mutating func int(_ n: Int) -> Int {
        let v = Int(next() * Float(n))
        return v < n ? v : n - 1
    }
}
