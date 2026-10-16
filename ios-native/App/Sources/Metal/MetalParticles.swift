import Foundation
import IceHiveCore

// ================================================================
//  METAL PARTICLES — CPU particle pool of 07-fx.js (class Particles):
//  19 floats per particle, swap-remove on death, floor bounce on the
//  deck under the particle (or keep falling into the abyss), colour
//  ramps per kind (0 fade, 1 fire, 2 smoke, 3 spark). update() writes
//  the GPU instances (camera-facing quads) straight into the frame
//  arena. Additive pool: fire, sparks, frost, glows; alpha pool:
//  smoke, steam, ichor, debris.
// ================================================================
final class MetalParticles {
    static let stride = 19
    let capacity: Int
    /// Live limit of the quality tier (web PA.max / PN.max).
    var limit: Int
    private(set) var count = 0
    private let d: UnsafeMutablePointer<Float>
    private let level: Level
    private var rng: SeededRNG

    init(capacity: Int, limit: Int, level: Level, seed: UInt32) {
        self.capacity = capacity
        self.limit = min(limit, capacity)
        self.level = level
        rng = SeededRNG(seed: seed)
        d = .allocate(capacity: capacity * MetalParticles.stride)
        d.initialize(repeating: 0, count: capacity * MetalParticles.stride)
    }

    deinit { d.deallocate() }

    func clear() { count = 0 }

    /// y is relative to the floor under (x, z) unless `absolute`.
    func emit(_ x: Float, _ y0: Float, _ z: Float, _ vx: Float, _ vy: Float, _ vz: Float, _ life: Float, _ s0: Float, _ s1: Float,
              _ r: Float, _ g: Float, _ b: Float, _ a: Float, _ grav: Float, _ drag: Float, _ kind: Float, absolute: Bool = false) {
        let gy = level.groundY(x, z)
        let y = absolute ? y0 : y0 + gy
        var i = count
        if i >= limit {
            i = min(limit - 1, Int(rng.next() * Float(limit)))
            if i < 0 { return }
        } else {
            count += 1
        }
        let o = i * MetalParticles.stride
        d[o] = x; d[o + 1] = y; d[o + 2] = z; d[o + 3] = vx; d[o + 4] = vy; d[o + 5] = vz
        d[o + 6] = 0; d[o + 7] = max(0.001, life); d[o + 8] = s0; d[o + 9] = s1
        d[o + 10] = r; d[o + 11] = g; d[o + 12] = b; d[o + 13] = a; d[o + 14] = grav; d[o + 15] = drag; d[o + 16] = kind
        d[o + 17] = gy + 0.03
        d[o + 18] = rng.next()
    }

    /// Advance by dt and write up to `max` instances into `out`; returns how many were written.
    func update(dt: Float, out: UnsafeMutablePointer<ParticleInstance>?, max outMax: Int) -> Int {
        var n = count
        var i = 0
        var w = 0
        let S = MetalParticles.stride
        while i < n {
            let o = i * S
            d[o + 6] += dt
            if d[o + 6] >= d[o + 7] {
                n -= 1
                if i != n { (d + o).update(from: d + n * S, count: S) }
                continue
            }
            let dr = 1 / (1 + d[o + 15] * dt)
            d[o + 3] *= dr
            d[o + 5] *= dr
            d[o + 4] = d[o + 4] * dr - d[o + 14] * dt
            d[o] += d[o + 3] * dt
            d[o + 1] += d[o + 4] * dt
            d[o + 2] += d[o + 5] * dt
            if d[o + 1] < d[o + 17] && d[o + 14] > 0 {
                // landed: bounce on the floor under the particle now, or keep falling into the abyss
                let c = level.cellOf(d[o], d[o + 2])
                if c >= 0 && level.walkValue(c) != 0 {
                    let gy = level.groundY(d[o], d[o + 2]) + 0.03
                    if d[o + 1] < gy { d[o + 1] = gy; d[o + 4] *= -0.25; d[o + 3] *= 0.5; d[o + 5] *= 0.5 }
                    d[o + 17] = gy
                } else {
                    d[o + 17] = -1e9
                }
            }
            if let out = out, w < outMax {
                let t = d[o + 6] / d[o + 7]
                let k = d[o + 16]
                var r = d[o + 10], g = d[o + 11], b = d[o + 12], a = d[o + 13]
                if k == 1 {
                    // fire: white-yellow -> orange -> deep red -> gone
                    let u = t * 1.6
                    if u < 1 {
                        r = r + (1.0 - r) * u; g = g + (0.42 - g) * u; b = b + (0.08 - b) * u
                    } else {
                        let v = min(1, u - 1)
                        r = 1.0 + (0.5 - 1.0) * v; g = 0.42 + (0.06 - 0.42) * v; b = 0.08 + (0.02 - 0.08) * v
                    }
                    a *= 1 - t * t
                } else if k == 2 {
                    a *= min(1, t * 6) * (1 - t)
                } else if k == 3 {
                    a *= (1 - t) * (1 - t)
                } else {
                    a *= 1 - t
                }
                let size = d[o + 8] + (d[o + 9] - d[o + 8]) * t
                out[w] = ParticleInstance(pos: F4(d[o], d[o + 1], d[o + 2], size), color: F4(r, g, b, a), extra: F4(d[o + 18], 0, 0, 0))
                w += 1
            }
            i += 1
        }
        count = n
        return w
    }
}
