import SpriteKit
import IceHiveCore

/// Particle textures of the Particles atlas.
enum PTex: Int {
    case soft, puff, spark, streak, flash, shard, chunk, dot, firePyro, fireBlast, fireball
}

// ================================================================
//  PARTICLES — port of the web PA (additive) / PN (alpha) systems:
//  emit(x, y, z, vx, vy, vz, life, s0, s1, r, g, b, a, grav, drag, kind)
//  with y relative to the floor, kinds 0 fade, 1 fire (baked ramp
//  frames), 2 smoke (fade in / out), 3 spark. Drawn with pooled
//  sprites above the darkness (they are their own light).
// ================================================================
final class ParticleSystem {
    private struct P {
        var x: Float = 0, y: Float = 0, z: Float = 0
        var vx: Float = 0, vy: Float = 0, vz: Float = 0
        var t: Float = 0, life: Float = 1
        var s0: Float = 0, s1: Float = 0
        var a: Float = 1
        var grav: Float = 0, drag: Float = 0
        var floorY: Float = 0
        var kind: UInt8 = 0
        var tex: PTex = .soft
        var variant: Int = 0
        var color: SKColor? = nil
    }

    let additive: Bool
    let capacity: Int
    /// Emission scale (web fxK: quality tier).
    var quality: Float = 0.7
    private var ps: [P]
    private(set) var count = 0
    private let pool: SpritePool
    private var rng = SeededRNG(seed: 99)
    private let level: Level
    private var frames: [[SKTexture]] = []

    init(parent: SKNode, assets: SpriteAssets, level: Level, additive: Bool, capacity: Int) {
        self.additive = additive
        self.capacity = capacity
        self.level = level
        ps = [P](repeating: P(), count: capacity)
        pool = SpritePool(parent: parent, capacity: capacity) { n in
            n.blendMode = additive ? .add : .alpha
            n.zPosition = additive ? ZBand.particlesAdd : ZBand.particlesAlpha
            n.colorBlendFactor = 1
        }
        func list(_ names: [String]) -> [SKTexture] { names.map { assets.texture($0) } }
        let all: [PTex] = [.soft, .puff, .spark, .streak, .flash, .shard, .chunk, .dot, .firePyro, .fireBlast, .fireball]
        for t in all {
            switch t {
            case .soft: frames.append(list((0..<4).map { "p_soft_\($0)" }))
            case .puff: frames.append(list((0..<4).map { "p_puff_\($0)" }))
            case .spark: frames.append(list(["p_spark"]))
            case .streak: frames.append(list(["p_streak"]))
            case .flash: frames.append(list(["p_flash_0", "p_flash_1"]))
            case .shard: frames.append(list((0..<3).map { "p_shard_\($0)" }))
            case .chunk: frames.append(list((0..<3).map { "p_chunk_\($0)" }))
            case .dot: frames.append(list(["p_dot"]))
            case .firePyro: frames.append(list((0..<8).map { "fire_pyro_\($0)" }))
            case .fireBlast: frames.append(list((0..<8).map { "fire_blast_\($0)" }))
            case .fireball: frames.append(list((0..<8).map { "fireball_\($0)" }))
            }
        }
    }

    @inline(__always) func rr(_ a: Float, _ b: Float) -> Float { a + (b - a) * rng.next() }
    @inline(__always) func rnd() -> Float { rng.next() }

    /// Same arguments as the web emit(); `tex` overrides the default sprite.
    func emit(_ x: Float, _ y: Float, _ z: Float, _ vx: Float, _ vy: Float, _ vz: Float, _ life: Float,
              _ s0: Float, _ s1: Float, _ r: Float, _ g: Float, _ b: Float, _ a: Float,
              _ grav: Float, _ drag: Float, _ kind: UInt8, tex: PTex? = nil, absolute: Bool = false) {
        let gy = level.groundY(x, z)
        var i = count
        if i >= capacity { i = Int(rng.next() * Float(capacity)) % capacity } else { count += 1 }
        var p = P()
        p.x = x; p.y = absolute ? y : y + gy; p.z = z
        p.vx = vx; p.vy = vy; p.vz = vz
        p.t = 0; p.life = max(0.01, life); p.s0 = s0; p.s1 = s1; p.a = a
        p.grav = grav; p.drag = drag; p.kind = kind; p.floorY = gy + 0.03
        if kind == 1 {
            p.tex = additive ? (g > 0.65 ? .firePyro : .fireBlast) : .fireball
            p.color = nil
        } else {
            p.tex = tex ?? (additive ? .soft : .puff)
            p.color = Tone.color(r, g, b)
        }
        let nv = frames[p.tex.rawValue].count
        p.variant = nv > 1 ? Int(rng.next() * Float(nv)) % nv : 0
        ps[i] = p
    }

    func clear() { count = 0; pool.hideAll() }

    func update(dt: Float, visible: CGRect) {
        let minX = visible.minX - 40, maxX = visible.maxX + 40, minY = visible.minY - 40, maxY = visible.maxY + 40
        pool.begin()
        var i = 0
        while i < count {
            var p = ps[i]
            p.t += dt
            if p.t >= p.life {
                count -= 1
                if i != count { ps[i] = ps[count] }
                continue
            }
            let dr = 1 / (1 + p.drag * dt)
            p.vx *= dr; p.vz *= dr; p.vy = p.vy * dr - p.grav * dt
            p.x += p.vx * dt; p.y += p.vy * dt; p.z += p.vz * dt
            if p.y < p.floorY && p.grav > 0 {
                let c = level.cellOf(p.x, p.z)
                if c >= 0 && level.walkValue(c) != 0 {
                    let gy = level.groundY(p.x, p.z) + 0.03
                    if p.y < gy { p.y = gy; p.vy *= -0.25; p.vx *= 0.5; p.vz *= 0.5 }
                    p.floorY = gy
                } else {
                    p.floorY = -1e9
                }
            }
            ps[i] = p
            i += 1
            let pt = Iso.point(p.x, p.y, p.z)
            if pt.x < minX || pt.x > maxX || pt.y < minY || pt.y > maxY { continue }
            guard let n = pool.next() else { continue }
            let u = p.t / p.life
            let s = CGFloat(p.s0 + (p.s1 - p.s0) * u) * Iso.ppm
            n.size = CGSize(width: s, height: s)
            n.position = pt
            var alpha = p.a
            let tex: SKTexture
            switch p.kind {
            case 1:
                let fr = frames[p.tex.rawValue]
                tex = fr[min(fr.count - 1, Int(u * Float(fr.count)))]
                alpha = 1
            case 2:
                tex = frames[p.tex.rawValue][p.variant]
                alpha *= min(1, u * 6) * (1 - u)
            case 3:
                tex = frames[p.tex.rawValue][p.variant]
                alpha *= (1 - u) * (1 - u)
            default:
                tex = frames[p.tex.rawValue][p.variant]
                alpha *= 1 - u
            }
            if n.texture !== tex { n.texture = tex }
            if let c = p.color {
                n.color = c
                n.colorBlendFactor = 1
            } else {
                n.colorBlendFactor = 0
            }
            n.alpha = CGFloat(max(0, min(1, alpha)))
        }
        pool.end()
    }

    var visibleCount: Int { pool.used }
}
