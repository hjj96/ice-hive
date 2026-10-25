import Foundation
import Metal
import IceHiveCore

// ================================================================
//  METAL EFFECTS — the FX section of the web game (07-fx.js) for the
//  Metal renderer (owned by WP5 «Эффекты»): GameEvents → particles,
//  floor stains (multiply decals), splashes and flash lights
//  (fxBugDeath, fxExplosion, fxAcid, fxBulletHit, fxDash,
//  fxNapalmBurst, fxNova, fxTurretDrop, fxHeal), and the per-frame
//  part of renderFx: muzzle flashes, flames, cryo beam, napalm fields,
//  vent steam, sight glints + target dots (no long laser sights since
//  LAND), tracers, telegraphs, beacon beams, and
//  the light pool (point light 0 follows flames / the player's muzzle,
//  1–2 are short blasts). Corpses go to Swarm/Corpses.swift (`corpses`,
//  fed with this file's random sequence), the squad's team rings and
//  progress rings to Squad/GroundGlyphs.swift. Everything is collected
//  into plain arrays, uploaded into the frame arena by upload() and
//  drawn by this file's world items (decals, sprites, particles,
//  ribbons — FX.metal).
// ================================================================

/// Multiply-blended floor stain (`struct DecalInstance` in FX.metal).
struct DecalInstance {
    var model: Mat4
    /// rgb stain tint, w unused.
    var color: F4
    /// xy atlas cell offset (0 / 0.5), zw unused.
    var uv: F4
}

/// Flat floor sprite (`struct SpriteInstance` in FX.metal): glows, splashes, telegraphs, team rings, ring indicators.
struct SpriteInstance {
    /// xyz centre, w = mode (0 textured, 1 ring indicator).
    var center: F4
    /// xyz half extent along the sprite's u axis, w = indicator progress.
    var axisU: F4
    /// xyz half extent along the v axis (v = 0 at center + axisV), w = indicator alpha.
    var axisV: F4
    /// rgb colour (additive), w = opacity multiplier.
    var color: F4
}

/// Camera-facing particle (`struct ParticleInstance` in FX.metal).
struct ParticleInstance {
    /// xyz position, w = size (m, the web point size).
    var pos: F4
    /// rgba colour.
    var color: F4
    /// x = noise seed, yzw unused.
    var extra: F4
}

/// Ribbon vertex (`struct RibbonVertex` in FX.metal): sight glints, tracers, the cryo beam, beacon beams.
struct RibbonVertex {
    /// xyz world position, w = mode (0 dashed line — unused since the laser sights went, 1 flat tracer, 2 cryo beam,
    /// 3 fade along u: sight glints, beacon beams).
    var pos: F4
    /// rgb colour, w = intensity.
    var color: F4
    /// xy uv (u along, v across 0…1), zw unused.
    var uv: F4
}

final class MetalEffects {
    let level: Level
    let pa: MetalParticles
    let pn: MetalParticles
    /// Emission scale (web fxK: low 0.4, med 0.7, high 1).
    private(set) var fxK: Float = 0.7
    private var rng = SeededRNG(seed: 9001)

    /// Where bug deaths leave their bodies (Swarm/Corpses.swift; MetalWorld sets it).
    weak var corpses: Corpses?

    // persistent ground stains (ring buffer, web QUALITY.med budget by default)
    /// (`decalVersion` moves on every change: upload() re-copies them only then)
    private(set) var decals: [DecalInstance] = [] { didSet { decalVersion &+= 1 } }
    private(set) var decalVersion = 0
    private var decalXZ: [Vec2] = []
    private var decRing = 1000
    private var decHead = 0
    private var decY = 0
    /// Stains lying on the lift deck (ring index, base y) once the extraction starts.
    private var liftGore: [(Int, Float)]? = nil
    private var liftRiseLast: Float = 0

    // per-frame sprite lists
    var glowSprites: [SpriteInstance] = []
    var ringSprites: [SpriteInstance] = []
    var fillSprites: [SpriteInstance] = []
    var laneSprites: [SpriteInstance] = []
    var ribbons: [RibbonVertex] = []
    private struct Splash { var x: Float, z: Float, size: Float, r: Float, g: Float, b: Float, t: Float, life: Float }
    private var splashes: [Splash] = []

    // light pool
    struct PointLight { var pos: F3; var color: F3; var intensity: Float }
    /// [0] follows flames / napalm / the player's muzzle, [1], [2] short blasts.
    private(set) var lights = [PointLight](repeating: PointLight(pos: F3(0, -60, 0), color: F3(1, 0.54, 0.23), intensity: 0), count: 3)
    private var flashT: [Float] = [0, 0, 0]
    private var flashDur: [Float] = [1, 1, 1]
    private var flashPeak: [Float] = [0, 0, 0]
    private var steamT: Float = 0

    init(level: Level) {
        self.level = level
        pa = MetalParticles(capacity: 4000, limit: 2600, level: level, seed: 77)
        pn = MetalParticles(capacity: 2400, limit: 1560, level: level, seed: 78)
        decals.reserveCapacity(1500)
        decalXZ.reserveCapacity(1500)
        glowSprites.reserveCapacity(48)
        ringSprites.reserveCapacity(80)
        fillSprites.reserveCapacity(32)
        laneSprites.reserveCapacity(16)
        ribbons.reserveCapacity(800 * 6)
        splashes.reserveCapacity(16)
    }

    /// web fxApplyQuality(): emission scale and the particle / stain budgets of the tier (corpses: Corpses.setQuality).
    func setQuality(fxK k: Float) {
        fxK = k
        let tier: (Int, Int, Int) = k < 0.5 ? (1400, 500, 160) : (k < 0.85 ? (2600, 1000, 320) : (4000, 1500, 520))
        pa.limit = min(pa.capacity, tier.0)
        pn.limit = min(pn.capacity, Int((Float(tier.0) * 0.6).rounded()))
        if decRing != tier.1 {
            decRing = tier.1
            decHead = 0
            if decals.count > decRing { decals.removeLast(decals.count - decRing); decalXZ.removeLast(decalXZ.count - decRing) }
        }
    }

    func reset() {
        pa.clear(); pn.clear()
        decals.removeAll(keepingCapacity: true); decalXZ.removeAll(keepingCapacity: true)
        decHead = 0; decY = 0
        liftGore = nil
        liftRiseLast = 0
        splashes.removeAll(keepingCapacity: true)
        for k in 0..<3 { lights[k].intensity = 0; flashPeak[k] = 0 }
        for k in 0..<sightLevel.count { sightLevel[k] = 0 }
        turretSight = 0
    }

    /// Memory warning: the live particles and splashes go (stains and corpses stay; they are part of the battle).
    func trim() {
        pa.clear(); pn.clear()
        splashes.removeAll(keepingCapacity: true)
    }

    @inline(__always) private func rnd() -> Float { rng.next() }
    @inline(__always) private func rr(_ a: Float, _ b: Float) -> Float { a + (b - a) * rng.next() }
    @inline(__always) private func num(_ base: Float) -> Int { Int((base * fxK).rounded(.up)) }

    // ================================================================ ground stains
    private func walkable2(_ x: Float, _ z: Float) -> Bool {
        let c = level.cellOf(x, z)
        return c >= 0 && level.walkValue(c) != 0
    }

    /// dy/dz of the floor at (x, z) (ramps run along z).
    private func slopeZ(_ x: Float, _ z: Float) -> Float {
        (level.groundY(x, z + 0.05) - level.groundY(x, z - 0.05)) / 0.1
    }

    /// web addDecal: cell 0 splat, 1 streak splat, 2 remains, 3 scorch.
    func addDecal(_ x: Float, _ z: Float, _ size0: Float, _ cell: Int, _ r: Float, _ g: Float, _ b: Float) {
        let c0 = level.cellOf(x, z)
        if c0 < 0 || level.walkValue(c0) == 0 { return }
        var size = size0
        var k = 0
        while k < 3 {
            let h = size * 0.4
            if walkable2(x - h, z - h) && walkable2(x + h, z - h) && walkable2(x - h, z + h) && walkable2(x + h, z + h) { break }
            size *= 0.7
            k += 1
        }
        let gz = slopeZ(x, z)
        let gy = level.groundY(x, z) + (level.isStairCell(c0) ? 0.08 : 0)
        decY = (decY + 1) % 64
        let rot = rnd() * TAU
        let c = cosf(rot) * size, s = sinf(rot) * size
        let m = Mat4(c0: F4(c, -s * gz, -s, 0), c1: F4(0, 1, 0, 0), c2: F4(s, c * gz, c, 0),
                     c3: F4(x, gy + 0.018 + Float(decY) * 0.0002, z, 1))
        let uv: F4 = cell == 0 ? F4(0, 0, 0, 0) : (cell == 1 ? F4(0.5, 0, 0, 0) : (cell == 2 ? F4(0, 0.5, 0, 0) : F4(0.5, 0.5, 0, 0)))
        let d = DecalInstance(model: m, color: F4(r, g, b, 1), uv: uv)
        if decals.count < decRing {
            decals.append(d); decalXZ.append(Vec2(x, z))
        } else {
            decals[decHead] = d; decalXZ[decHead] = Vec2(x, z)
            forgetLiftGore(decHead)
            decHead = (decHead + 1) % decRing
        }
    }

    /// A ring slot riding the lift was reused for a new stain elsewhere: it no longer rides (the web moves it anyway).
    private func forgetLiftGore(_ i: Int) {
        if liftGore != nil { liftGore!.removeAll(where: { $0.0 == i }) }
    }

    /// Stains lying on the lift deck ride up with it (web fxLiftRise; corpses: Corpses.liftRise).
    func liftRise(_ rise: Float) {
        if rise == liftRiseLast { return }
        liftRiseLast = rise
        if liftGore == nil {
            var list: [(Int, Float)] = []
            for (i, p) in decalXZ.enumerated() where level.isLiftCell(level.cellOf(p.x, p.y)) { list.append((i, decals[i].model.c3.y)) }
            liftGore = list
        }
        for (i, y) in liftGore ?? [] where i < decals.count { decals[i].model.c3.y = y + rise }
    }

    // ================================================================ lights / splashes
    /// The web phone build pools a single point light (03-render.js N_PL = 1: flames / napalm / the player's muzzle);
    /// blasts light the deck with a floor splash instead. true = the desktop rig (two extra blast lights).
    static let blastLights = false

    /// web flashLight(): reuse the weaker of the two blast lights (phones: a floor splash).
    func flashLight(_ x: Float, _ y: Float, _ z: Float, _ hex: UInt32, _ peak: Float, _ dur: Float) {
        if !MetalEffects.blastLights {
            splash(x, z, 5 + peak.squareRoot() * 0.25, Float((hex >> 16) & 255) / 640, Float((hex >> 8) & 255) / 640, Float(hex & 255) / 640, dur)
            return
        }
        let best = lights[1].intensity <= lights[2].intensity ? 1 : 2
        lights[best].pos = F3(x, y + level.groundY(x, z), z)
        lights[best].color = linearRGB(hex)
        flashPeak[best] = peak
        flashT[best] = 0
        flashDur[best] = dur
        lights[best].intensity = peak
    }

    /// Persistent splash that fades out over `life`.
    func splash(_ x: Float, _ z: Float, _ size: Float, _ r: Float, _ g: Float, _ b: Float, _ life: Float) {
        let s = Splash(x: x, z: z, size: size, r: r, g: g, b: b, t: 0, life: life)
        if splashes.count < 16 { splashes.append(s); return }
        var worst = 0
        for k in 1..<splashes.count where splashes[k].t / splashes[k].life > splashes[worst].t / splashes[worst].life { worst = k }
        splashes[worst] = s
    }

    /// One-frame light pool on the deck.
    func splashNow(_ x: Float, _ z: Float, _ size: Float, _ r: Float, _ g: Float, _ b: Float) {
        if glowSprites.count >= 40 { return }
        let c0 = level.cellOf(x, z)
        if c0 < 0 || level.walkValue(c0) == 0 { return }
        let gz = slopeZ(x, z)
        let gy = level.groundY(x, z) + 0.04 + (level.isStairCell(c0) ? 0.08 : 0)
        let h = size * 0.5
        glowSprites.append(SpriteInstance(center: F4(x, gy, z, 0), axisU: F4(h, 0, 0, 0), axisV: F4(0, gz * h, h, 0), color: F4(r, g, b, 1)))
    }

    // ================================================================ events
    func handle(_ e: GameEvent, game: Game) {
        switch e {
        case .bugKilled(let type, let pos, let frozen, _, let heading, let scale, let height):
            bugDeath(type, pos.x, pos.y, frozen, heading, scale, height)
        case .bulletHit(let pos, let dir, let killed):
            bulletHit(pos.x, pos.y, dir.x, dir.y, killed)
        case .explosion(let kind, let pos, let radius):
            explosion(pos.x, pos.y, radius, kind)
        case .acidSplash(let pos):
            acid(pos.x, pos.y)
        case .dash(let m, _):
            if m < game.marines.count { dash(game.marines[m]) }
        case .ability(_, let kind, let pos, let radius):
            switch kind {
            case .napalm: napalmBurst(pos.x, pos.y, radius)
            case .nova: nova(pos.x, pos.y, radius)
            case .turret: turretDrop(pos.x, pos.y)
            case .grenade: break
            }
        case .healed(let m, _, _), .revived(let m):
            if m < game.marines.count { heal(game.marines[m]) }
        case .turretShot(let pos, let angle):
            let ax = sinf(angle), az = cosf(angle)
            pa.emit(pos.x + ax * 0.75, 1.05, pos.y + az * 0.75, ax * 2, 0, az * 2, 0.05, 0.7, 0.3, 0.5, 1, 0.5, 1, 0, 0, 0)
        case .bugFrozen(let pos):
            for _ in 0..<num(3) { pa.emit(pos.x, 0.4, pos.y, rr(-1, 1), rr(0.5, 1.5), rr(-1, 1), rr(0.2, 0.4), 0.2, 0.05, 0.45, 0.75, 1, 0.8, 2, 1, 3) }
        case .beaconCompleted(let k):
            if k >= 0 && k < game.beacons.count {
                let b = game.beacons[k]
                flashLight(b.x, 3, b.z, 0x40ffe0, 600, 1.0)
            }
        case .turretExpired(let pos):
            turretDrop(pos.x, pos.y)
        default:
            break
        }
    }

    // stain tints (multiplied over the floor) and the ichor droplet colours
    private static let ichor: [(Float, Float, Float)] = [(0.62, 0.1, 0.22), (0.5, 0.58, 0.1), (0.58, 0.12, 0.15), (0.62, 0.24, 0.08)]
    private static let ichorP: [(Float, Float, Float)] = [(0.3, 0.05, 0.14), (0.28, 0.32, 0.04), (0.26, 0.06, 0.08), (0.32, 0.12, 0.04)]

    private func bugDeath(_ type: BugType, _ x: Float, _ z: Float, _ frozen: Bool, _ hd: Float, _ sc: Float, _ y: Float) {
        let ty = type.rawValue
        if frozen {
            for _ in 0..<num(8) { pa.emit(x, 0.4, z, rr(-3, 3), rr(1, 4), rr(-3, 3), rr(0.25, 0.5), 0.2, 0.04, 0.35, 0.6, 0.8, 1, 9, 1, 3) }
            addDecal(x, z, sc * 0.8, 0, 0.72, 0.84, 0.98)
            return
        }
        let c = MetalEffects.ichor[ty], cp = MetalEffects.ichorP[ty]
        pa.emit(x, 0.35 * sc + y, z, 0, 0.6, 0, 0.11, 0.7 * sc, 1.5 * sc, 1.0, 0.45, 0.7, 0.85, 0, 0, 3)
        for _ in 0..<num(type == .brute ? 9 : 2) {
            pn.emit(x, 0.4 + y, z, rr(-3.2, 3.2), rr(2, 5.5), rr(-3.2, 3.2), rr(0.5, 0.9), rr(0.08, 0.15) * (type == .brute ? 1.6 : 1), 0.07,
                    0.13, 0.07, 0.11, 1, 15, 0.4, 0)
        }
        if type == .brute { splash(x, z, 4, 0.3, 0.06, 0.16, 0.35) }
        addDecal(x, z, sc * rr(1.0, 1.5), rnd() < 0.5 ? 0 : 1, c.0, c.1, c.2)
        if type != .boomer { corpses?.add(x, z, hd, sc, type, rnd: rnd) } else { addDecal(x, z, 2.6, 3, 0.1, 0.08, 0.08) }
        for _ in 0..<num(type == .brute ? 14 : 5) {
            pn.emit(x, 0.35, z, rr(-2.5, 2.5), rr(1.5, 4), rr(-2.5, 2.5), rr(0.4, 0.8), rr(0.12, 0.22), 0.06, cp.0 * 1.6, cp.1 * 1.6, cp.2 * 1.6, 0.95, 12, 0.5, 0)
        }
        if type != .spitter {
            for _ in 0..<num(2) { pa.emit(x, 0.4, z, rr(-2, 2), rr(1, 3), rr(-2, 2), 0.35, 0.18, 0.05, 1.0, 0.25, 0.5, 1, 8, 0.5, 3) }
        }
    }

    private func explosion(_ x: Float, _ z: Float, _ r: Float, _ kind: ExplosionKind) {
        switch kind {
        case .pulse:
            // (its two shock rings come from the core's telegraph pool)
            for _ in 0..<num(60) {
                let a = rnd() * TAU
                pa.emit(x + cosf(a) * r * 0.95, 0.3, z + sinf(a) * r * 0.95, cosf(a) * 2, rr(1, 4), sinf(a) * 2, rr(0.2, 0.45), 0.25, 0.05, 0.4, 1, 0.9, 1, 4, 1, 3)
            }
            flashLight(x, 3, z, 0x40ffe0, 380, 0.4)
            splash(x, z, r * 2.4, 0.06, 0.32, 0.28, 0.45)
            return
        case .frost:
            for _ in 0..<num(9) {
                let a = rnd() * TAU, s = rr(2, 6)
                pa.emit(x, 0.4, z, cosf(a) * s, rr(1, 3), sinf(a) * s, rr(0.3, 0.6), 0.26, 0.05, 0.45, 0.75, 1.0, 0.9, 6, 1.5, 3)
            }
            for _ in 0..<num(3) { pn.emit(x, 0.4, z, rr(-3, 3), rr(2, 4.5), rr(-3, 3), rr(0.5, 0.8), rr(0.1, 0.16), 0.08, 0.55, 0.75, 0.9, 1, 15, 0.4, 0) }
            for _ in 0..<3 { pn.emit(x, 0.4, z, rr(-3, 3), rr(2, 4), rr(-3, 3), rr(0.4, 0.7), 0.12, 0.08, 0.75, 0.9, 1.0, 0.95, 15, 0.4, 0) }
            return
        default:
            break
        }
        let big = kind.isBig
        for _ in 0..<num(big ? 26 : 8) {
            let a = rnd() * TAU, s = rr(0.5, r * 1.3)
            pa.emit(x + cosf(a) * 0.3, rr(0.3, 1), z + sinf(a) * 0.3, cosf(a) * s, rr(0.5, 3), sinf(a) * s, rr(0.35, 0.7), rr(0.6, 1.1), rr(1.3, 2.2), 1, 0.55, 0.2, 0.45, -1, 2.2, 1)
        }
        for _ in 0..<num(big ? 22 : 8) {
            let a = rnd() * TAU, s = rr(6, 16)
            pa.emit(x, 0.5, z, cosf(a) * s, rr(2, 7), sinf(a) * s, rr(0.3, 0.7), 0.12, 0.04, 1.0, 0.75, 0.35, 1, 14, 0.6, 3)
        }
        for _ in 0..<num(big ? 18 : 6) {
            let a = rnd() * TAU, s = rr(0.5, r)
            pn.emit(x + cosf(a) * 0.5, rr(0.4, 1.2), z + sinf(a) * 0.5, cosf(a) * s, rr(1, 3), sinf(a) * s, rr(0.5, 0.9), rr(1.0, 1.6), rr(2.2, 3.4), 1.0, 0.42, 0.12, 0.85, -1.5, 2.0, 1)
        }
        for _ in 0..<num(big ? 16 : 4) {
            pn.emit(x + rr(-1, 1), rr(0.5, 1.5), z + rr(-1, 1), rr(-1.2, 1.2), rr(1, 2.5), rr(-1.2, 1.2), rr(1.6, 2.6), 1.6, 4.2, 0.06, 0.055, 0.06, 0.75, -0.3, 0.8, 2)
        }
        addDecal(x, z, r * (big ? 1.1 : 0.8), 3, 0.08, 0.07, 0.07)
        flashLight(x, 1.6, z, kind == .boomer ? 0xff5a20 : 0xff7a30, big ? 220 : 90, big ? 0.5 : 0.25)
        splash(x, z, r * (big ? 2.4 : 2.0), 0.4, 0.14, 0.03, big ? 0.6 : 0.3)
    }

    private func acid(_ x: Float, _ z: Float) {
        for _ in 0..<num(9) { pa.emit(x, 0.2, z, rr(-2.5, 2.5), rr(1, 3.5), rr(-2.5, 2.5), rr(0.3, 0.6), 0.2, 0.05, 0.7, 1.0, 0.15, 1, 8, 1, 3) }
        for _ in 0..<num(4) { pn.emit(x + rr(-0.6, 0.6), 0.2, z + rr(-0.6, 0.6), 0, rr(0.4, 1), 0, rr(0.8, 1.4), 0.5, 1.4, 0.4, 0.55, 0.15, 0.35, -0.2, 1, 2) }
        addDecal(x, z, rr(1.6, 2.1), 0, 0.42, 0.6, 0.06)
    }

    private func bulletHit(_ x: Float, _ z: Float, _ dx: Float, _ dz: Float, _ killed: Bool) {
        if rnd() > 0.6 * fxK + 0.2 { return }
        pa.emit(x, 0.45, z, -dx * rr(2, 5) + rr(-2, 2), rr(1, 3), -dz * rr(2, 5) + rr(-2, 2), 0.18, 0.14, 0.04, 1.0, 0.75, 0.4, 1, 10, 1, 3)
        if killed || rnd() < 0.4 {
            pn.emit(x, 0.4, z, rr(-1.5, 1.5) + dx * 2, rr(1, 2.5), rr(-1.5, 1.5) + dz * 2, 0.4, 0.13, 0.05, 0.45, 0.08, 0.2, 0.9, 10, 0.5, 0)
        }
    }

    private func dash(_ m: Marine) {
        for _ in 0..<num(12) { pa.emit(m.x + rr(-0.3, 0.3), rr(0.3, 1.5), m.z + rr(-0.3, 0.3), -m.dashX * rr(1, 4), rr(0, 1), -m.dashZ * rr(1, 4), rr(0.2, 0.4), 0.35, 0.05, 0.3, 0.9, 0.85, 0.6, 0, 3, 0) }
        for _ in 0..<num(5) { pn.emit(m.x, 0.15, m.z, rr(-1.5, 1.5), rr(0.3, 1), rr(-1.5, 1.5), rr(0.5, 0.9), 0.4, 1.3, 0.75, 0.8, 0.88, 0.4, -0.2, 2, 2) }
    }

    private func napalmBurst(_ x: Float, _ z: Float, _ r: Float) {
        for _ in 0..<num(70) {
            let a = rnd() * TAU, s = rr(r * 0.6, r * 1.6)
            pa.emit(x, 0.5, z, cosf(a) * s, rr(0.5, 2), sinf(a) * s, rr(0.4, 0.8), 0.6, 2.0, 1, 0.6, 0.22, 0.55, -1, 1.6, 1)
        }
        flashLight(x, 1.5, z, 0xff6a20, 200, 0.6)
        splash(x, z, r * 2.4, 0.38, 0.14, 0.03, 0.7)
        addDecal(x, z, r * 1.8, 3, 0.12, 0.08, 0.06)
    }

    private func nova(_ x: Float, _ z: Float, _ r: Float) {
        for _ in 0..<num(70) {
            let a = rnd() * TAU, s = rr(r * 0.8, r * 2.2)
            pa.emit(x, rr(0.2, 1), z, cosf(a) * s, rr(0.2, 2), sinf(a) * s, rr(0.4, 0.8), rr(0.2, 0.45), 0.05, 0.3, 0.55, 0.8, 1, 1, 2.5, 3)
        }
        flashLight(x, 2, z, 0x6ad8ff, 120, 0.45)
        splash(x, z, r * 2.4, 0.05, 0.13, 0.22, 0.5)
    }

    private func turretDrop(_ x: Float, _ z: Float) {
        for _ in 0..<num(16) { pa.emit(x, 0.5, z, rr(-4, 4), rr(2, 6), rr(-4, 4), rr(0.2, 0.5), 0.12, 0.03, 0.6, 1, 0.6, 1, 14, 0.5, 3) }
        for _ in 0..<num(6) { pn.emit(x, 0.2, z, rr(-1, 1), rr(0.3, 1), rr(-1, 1), 1, 0.5, 1.6, 0.7, 0.75, 0.82, 0.4, -0.1, 1.5, 2) }
    }

    private func heal(_ m: Marine) {
        for _ in 0..<18 { pa.emit(m.x + rr(-0.5, 0.5), rr(0.2, 1.4), m.z + rr(-0.5, 0.5), 0, rr(1, 2.5), 0, rr(0.5, 0.9), 0.25, 0.05, 0.3, 1, 0.5, 1, -0.5, 1, 0) }
    }

    /// One bug on fire (writeBugInstances): a few embers per second.
    @inline(__always) func burningBug(_ x: Float, _ z: Float, _ sc: Float, dt: Float) {
        if rnd() < 9 * dt * fxK {
            pa.emit(x + rr(-0.2, 0.2), 0.35 * sc, z + rr(-0.2, 0.2), 0, rr(1, 2.2), 0, rr(0.25, 0.45), 0.35 * sc, 0.7 * sc, 1, 0.6, 0.25, 0.55, -0.5, 1, 1)
        }
    }

    // ================================================================ per frame (renderFx)
    /// Marine pose the effects attach to (interpolated feet, aim).
    struct MarinePose { var x: Float, y: Float, z: Float }

    func beginFrame() {
        glowSprites.removeAll(keepingCapacity: true)
        ringSprites.removeAll(keepingCapacity: true)
        fillSprites.removeAll(keepingCapacity: true)
        laneSprites.removeAll(keepingCapacity: true)
        ribbons.removeAll(keepingCapacity: true)
    }

    @inline(__always) private func muzzle(_ m: Marine, _ p: MarinePose) -> (Float, Float) {
        (p.x + m.ax * 0.95 + m.az * 0.22, p.z + m.az * 0.95 - m.ax * 0.22)
    }

    func update(game: Game, dt: Float, time: Float, poses: [MarinePose], focus: F3, liftRise rise: Float) {
        // emitters tied to ongoing actions
        for (k, m) in game.marines.enumerated() where !m.downed && k < poses.count {
            let p = poses[k]
            let (ox, oz) = muzzle(m, p)
            if m.muzzle > 0 && (m.cls == .assault || m.cls == .gunner) {
                let c: (Float, Float, Float) = m.cls == .assault ? (1, 0.35, 0.25) : (1, 0.85, 0.4)
                if dt > 0 {
                    pa.emit(ox, 1.2, oz, m.ax * 2, 0, m.az * 2, 0.05, 0.9, 0.4, c.0, c.1, c.2, 1, 0, 0, 0)
                    // spent casings / heat-sink pellets kicked out to the right
                    if m.muzzle > 0.85 && rnd() < (m.isPlayer ? 0.7 : 0.3) * fxK {
                        pn.emit(p.x + m.az * 0.3, 1.1, p.z - m.ax * 0.3, m.az * rr(1.5, 2.6), rr(1.5, 3), -m.ax * rr(1.5, 2.6), rr(0.45, 0.7), 0.06, 0.05, 0.95, 0.68, 0.28, 1, 14, 0.3, 0)
                    }
                }
                // the muzzle flash lights the deck around the shooter
                let f = (0.55 + 0.45 * rnd()) * min(1, m.muzzle) * (m.isPlayer ? 0.34 : 0.22)
                splashNow(ox + m.ax * 0.6, oz + m.az * 0.6, 3.6, c.0 * f, c.1 * f, c.2 * f)
            }
            if m.firing && m.cls == .pyro {
                let f = 0.2 + 0.07 * rnd()
                splashNow(ox + m.ax * 3, oz + m.az * 3, 6.5, f, f * 0.45, f * 0.12)
                if dt > 0 {
                    let n = max(1, Int((150 * fxK * dt + rnd() * 0.5).rounded()))
                    for _ in 0..<n {
                        let sp = rr(11, 15), sx = rr(-1, 1) * 2.6, sy = rr(-0.2, 1.2)
                        pa.emit(ox, 1.15, oz, m.ax * sp - m.az * sx + m.vx * 0.5, sy, m.az * sp + m.ax * sx + m.vz * 0.5, rr(0.42, 0.58), 0.3, rr(1.4, 2.1), 1, 0.78, 0.4, 0.5, -1.5, 1.25, 1)
                    }
                    if rnd() < 30 * fxK * dt { pn.emit(ox + m.ax * 6, 1.4, oz + m.az * 6, m.ax * 2, 1.4, m.az * 2, 1.4, 1, 3, 0.09, 0.08, 0.08, 0.4, -0.4, 0.6, 2) }
                }
            }
            if m.firing && m.cls == .cryo {
                let f = 0.1 + 0.03 * rnd()
                splashNow(ox + m.ax * m.beamLen * 0.45, oz + m.az * m.beamLen * 0.45, 5.5, f * 0.45, f * 0.8, f)
                if dt > 0 && rnd() < 40 * fxK * dt {
                    let t = rnd() * m.beamLen
                    pa.emit(ox + m.ax * t, 0.8, oz + m.az * t, rr(-1, 1), rr(-0.5, 1), rr(-1, 1), rr(0.3, 0.6), 0.25, 0.05, 0.6, 0.9, 1, 1, 1, 1, 3)
                }
            }
        }
        for np in game.napalms where np.active {
            let f = 0.16 + 0.05 * rnd()
            splashNow(np.x, np.z, np.r * 2.6, f, f * 0.42, f * 0.1)
            if dt > 0 {
                let cnt = Int((240 * fxK * dt * (np.r / 5) + rnd()).rounded())
                for _ in 0..<cnt {
                    let a = rnd() * TAU, rad = np.r + rr(-0.4, 0.4)
                    pa.emit(np.x + cosf(a) * rad, 0.15, np.z + sinf(a) * rad, rr(-0.3, 0.3), rr(1.5, 3), rr(-0.3, 0.3), rr(0.3, 0.5), 0.25, 0.9, 1, 0.6, 0.2, 0.6, -1, 1, 1)
                }
            }
        }
        if game.stage == .extract && dt > 0 {
            // the platform tears loose: steam pours off the rim, sparks rain into the shaft
            let L = level.lift, ry = L.y + rise
            let ns = Int((140 * fxK * dt + rnd()).rounded()), nk = Int((90 * fxK * dt + rnd()).rounded())
            for _ in 0..<ns {
                let a = rnd() * TAU
                pn.emit(L.x + cosf(a) * L.r, ry + 0.2, L.z + sinf(a) * L.r, cosf(a) * 0.6, rr(-2, -0.5), sinf(a) * 0.6, 1.2, 0.6, 2.4, 0.8, 0.85, 0.9, 0.35, 0, 0.6, 2, absolute: true)
            }
            for _ in 0..<nk {
                let a = rnd() * TAU
                pa.emit(L.x + cosf(a) * (L.r + 0.6), ry - 0.3, L.z + sinf(a) * (L.r + 0.6), cosf(a) * rr(0.5, 2), rr(-1, 1.5), sinf(a) * rr(0.5, 2), rr(0.4, 0.8), 0.14, 0.04, 1.0, 0.7, 0.3, 1, 12, 0.3, 3, absolute: true)
            }
        }
        steamT -= dt
        if steamT <= 0 && dt > 0 {
            steamT = 0.12
            for v in level.layout.vents where abs(v.x - focus.x) < 30 && abs(v.y - focus.z) < 30 && rnd() < 0.6 {
                pn.emit(v.x + rr(-0.4, 0.4), 0.2, v.y + rr(-0.4, 0.4), rr(-0.3, 0.3) + 0.4, rr(1.2, 2), rr(-0.3, 0.3), rr(2, 3), 0.6, 3.2, 0.8, 0.85, 0.92, 0.22, -0.15, 0.3, 2)
            }
        }
        // persistent splashes
        var k = 0
        while k < splashes.count {
            splashes[k].t += dt
            let e = splashes[k]
            if e.t >= e.life { splashes.remove(at: k); continue }
            let f = (1 - e.t / e.life) * (1 - e.t / e.life)
            splashNow(e.x, e.z, e.size * (0.8 + 0.2 * e.t / e.life), e.r * f, e.g * f, e.b * f)
            k += 1
        }
        liftRise(rise)
        telegraphs(game: game, time: time)
        tracers(game: game)
        sights(game: game, dt: dt, poses: poses)
        beam(game: game, time: time, poses: poses)
        beaconBeams(game: game, time: time, focus: focus)
        pointLights(game: game, dt: dt, time: time, poses: poses)
    }

    // ---------------------------------------------------------------- telegraphs / rings
    private func telegraphs(game: Game, time: Float) {
        let blink = 0.55 + 0.45 * sinf(time * 18)
        for e in game.telegraphs where e.active {
            let u = e.progress
            switch e.shape {
            case .lane:
                if laneSprites.count >= 16 { continue }
                let wind = max(0.001, e.wind)
                var inten: Float = e.t < e.wind ? blink * min(1, e.t / wind * 4 + 0.3) * (0.8 + 0.5 * e.t / wind)
                    : 1.3 * (1 - (e.t - e.wind) / max(0.001, e.life - e.wind))
                inten = max(0, inten)
                let cx = e.x + e.dx * e.len / 2, cz = e.z + e.dz * e.len / 2
                let y0 = level.groundY(e.x, e.z), y1 = level.groundY(e.x + e.dx * e.len, e.z + e.dz * e.len)
                let hw = e.w / 2, hl = e.len / 2
                laneSprites.append(SpriteInstance(center: F4(cx, (y0 + y1) * 0.5 + 0.06, cz, 0), axisU: F4(-e.dz * hw, 0, e.dx * hw, 0),
                                                  axisV: F4(e.dx * hl, (y1 - y0) * 0.5, e.dz * hl, 0), color: F4(e.r * inten, e.g * inten, e.b * inten, 1)))
            case .fill:
                if fillSprites.count >= 32 { continue }
                let rad = e.r0 * (0.12 + 0.88 * u)
                let inten = (0.3 + 0.7 * u) * (u > 0.75 ? blink * 1.3 : 1)
                let y = level.groundY(e.x, e.z) + 0.055
                fillSprites.append(SpriteInstance(center: F4(e.x, y, e.z, 0), axisU: F4(rad, 0, 0, 0), axisV: F4(0, 0, -rad, 0),
                                                  color: F4(e.r * inten, e.g * inten, e.b * inten, 1)))
            case .ring:
                if ringSprites.count >= 64 { continue }
                let inten = max(0, e.pulse ? blink * min(1, u * 4 + 0.3) : 1 - u)
                let rad = e.r0 + (e.r1 - e.r0) * smooth01f(u)
                let y = level.groundY(e.x, e.z) + 0.05
                ringSprites.append(SpriteInstance(center: F4(e.x, y, e.z, 0), axisU: F4(rad, 0, 0, 0), axisV: F4(0, 0, -rad, 0),
                                                  color: F4(e.r * inten, e.g * inten, e.b * inten, 1)))
            }
        }
    }

    // ---------------------------------------------------------------- ribbons
    private func quad(_ a: F3, _ b: F3, _ c: F3, _ d: F3, _ ca: F4, _ cb: F4, _ cc: F4, _ cd: F4,
                      _ ua: F4, _ ub: F4, _ uc: F4, _ ud: F4, mode: Float) {
        let va = RibbonVertex(pos: F4(a.x, a.y, a.z, mode), color: ca, uv: ua)
        let vb = RibbonVertex(pos: F4(b.x, b.y, b.z, mode), color: cb, uv: ub)
        let vc = RibbonVertex(pos: F4(c.x, c.y, c.z, mode), color: cc, uv: uc)
        let vd = RibbonVertex(pos: F4(d.x, d.y, d.z, mode), color: cd, uv: ud)
        ribbons.append(va); ribbons.append(vb); ribbons.append(vc)
        ribbons.append(va); ribbons.append(vc); ribbons.append(vd)
    }

    /// Sight level 0…1 of each marine (fades in while it fires, out after) and of the turret.
    private var sightLevel = [Float](repeating: 0, count: 4)
    private var turretSight: Float = 0
    /// Longest sight glint (m): no long laser line across the screen, only a short fading glint off the muzzle.
    static let sightGlintLength: Float = 1.2

    /// Sights (owner feedback: the constant long coloured laser lines got in the way, LAND): while a marine fires, a short
    /// class-coloured glint fades off its muzzle (≤ 1.2 m, brightest at the barrel, gone at the tip) and a small dot of
    /// the same hue sits on the bug it aims at; nothing while it does not fire. The turret gets the same in green.
    private func sights(game: Game, dt: Float, poses: [MarinePose]) {
        let B = game.bugs
        let L = MetalEffects.sightGlintLength
        for (k, m) in game.marines.enumerated() where k < poses.count && k < sightLevel.count {
            let want: Float = m.firing && !m.downed ? 1 : 0
            let rate: Float = want > sightLevel[k] ? 14 : 5
            sightLevel[k] += (want - sightLevel[k]) * min(1, rate * dt)
            if m.downed { sightLevel[k] = 0 }
            let lv = sightLevel[k]
            if lv < 0.02 { continue }
            let p = poses[k]
            let (ox, oz) = muzzle(m, p)
            let oy = p.y + 1.22
            let col = linearRGB(m.spec.laser)
            let ex = ox + m.ax * L, ez = oz + m.az * L
            // glint: a soft halo and a thin hot core, both fading to nothing at the tip (ribbon mode 3: k² along it)
            glint(ox, oy, oz, ex, oy - 0.06, ez, 0.09, col, 0.55 * lv)
            glint(ox, oy, oz, ex, oy - 0.06, ez, 0.022, col, 2.4 * lv)
            // target dot on the aimed bug (the player's a little larger and brighter)
            if lv > 0.35 {
                let hit = game.raycastBugs(origin: Vec2(ox, oz), dir: Vec2(m.ax, m.az), maxDistance: 24)
                if hit.bug >= 0 && hit.bug < B.count {
                    let hx = ox + m.ax * hit.distance, hz = oz + m.az * hit.distance
                    let hy = level.groundY(hx, hz) + max(-0.5, B.heights[hit.bug]) + 0.5
                    let c = col * (m.isPlayer ? 1.6 : 1.0) * lv
                    pa.emit(hx, hy, hz, 0, 0, 0, 0.04, m.isPlayer ? 0.42 : 0.3, 0.5, c.x, c.y, c.z, 1, 0, 0, 0, absolute: true)
                }
            }
        }
        let T = game.turret
        let tWant: Float = T.active ? 1 : 0
        turretSight += (tWant - turretSight) * min(1, (tWant > turretSight ? 14 : 5) * dt)
        if T.active && turretSight > 0.02 {
            let ax = sinf(T.angle), az = cosf(T.angle)
            let ox = T.x + ax * 0.75, oz = T.z + az * 0.75
            let ty = level.groundY(T.x, T.z) + 1.05
            let dist = game.turretLaserLength
            let hit = game.raycastBugs(origin: Vec2(ox, oz), dir: Vec2(ax, az), maxDistance: dist + 0.01)
            let on: Float = hit.bug >= 0 ? 1 : 0.4
            let g = F3(0.4, 2.2, 0.6)
            glint(ox, ty, oz, ox + ax * L, ty - 0.08, oz + az * L, 0.016, g, 1.1 * on * turretSight)
            if hit.bug >= 0 && hit.bug < B.count {
                let hx = ox + ax * hit.distance, hz = oz + az * hit.distance
                let hy = level.groundY(hx, hz) + max(-0.5, B.heights[hit.bug]) + 0.5
                pa.emit(hx, hy, hz, 0, 0, 0, 0.04, 0.3, 0.5, 0.25, 1.4, 0.4, 1, 0, 0, 0, absolute: true)
            }
        }
    }

    /// Short glint ribbon from (x0, y0, z0) to (x1, y1, z1), half width `w`: brightest at the start, k² to nothing at the
    /// end (fs_ribbon mode 3 with uv.x 0 → 1 along it).
    private func glint(_ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float, _ w: Float, _ col: F3, _ inten: Float) {
        let dx = x1 - x0, dz = z1 - z0
        let l = max(1e-4, (dx * dx + dz * dz).squareRoot())
        let px = -dz / l * w, pz = dx / l * w
        let c = F4(col.x, col.y, col.z, inten)
        quad(F3(x0 + px, y0, z0 + pz), F3(x0 - px, y0, z0 - pz), F3(x1 - px, y1, z1 - pz), F3(x1 + px, y1, z1 + pz),
             c, c, c, c, F4(0, 0, 0, 0), F4(0, 1, 0, 0), F4(1, 1, 0, 0), F4(1, 0, 0, 0), mode: 3)
    }

    private static let tracerColors: [F3] = [F3(2.6, 0.35, 0.25), F3(2.4, 1.9, 0.7), F3(0.7, 2.4, 0.8)]

    private func tracers(game: Game) {
        let P = game.projectiles
        let zero = F4(0, 0, 0, 1)
        for k in 0..<P.count {
            let p = P.position(k), d = P.direction(k)
            let ci = max(0, min(2, P.colorIndex(k)))
            let len = min(2.4, P.speed(k) * 0.028), w: Float = ci == 0 ? 0.075 : 0.05
            let tx = p.x - d.x * len, tz = p.y - d.y * len, px = -d.y * w, pz = d.x * w
            let y = 1.2 + level.groundY(p.x, p.y)
            let c = MetalEffects.tracerColors[ci]
            let cf = F4(c.x, c.y, c.z, 1)
            quad(F3(p.x + px, y, p.y + pz), F3(p.x - px, y, p.y - pz), F3(tx - px, y, tz - pz), F3(tx + px, y, tz + pz),
                 cf, cf, zero, zero, .zero, .zero, .zero, .zero, mode: 1)
        }
    }

    /// Cryo beam: a plane stretched along the aim, widening away from the muzzle (web updateBeam).
    private func beam(game: Game, time: Float, poses: [MarinePose]) {
        for (k, m) in game.marines.enumerated() where m.cls == .cryo && m.firing && !m.downed && k < poses.count {
            let p = poses[k]
            let (ox, oz) = muzzle(m, p)
            let len = m.beamLen
            let inten = 0.85 + 0.15 * sinf(time * 40)
            let col = F4(1, 1, 1, inten)
            func vtx(_ u: Float, _ v: Float) -> F3 {
                let along = u * len, w = (0.35 + u * 0.95) * v
                return F3(ox + m.ax * along + m.az * w, p.y + 1.2 - u * 0.7, oz + m.az * along - m.ax * w)
            }
            for s in 0..<8 {
                let u0 = Float(s) / 8, u1 = Float(s + 1) / 8
                quad(vtx(u0, 1), vtx(u0, -1), vtx(u1, -1), vtx(u1, 1), col, col, col, col,
                     F4(u0, 0, 0, 0), F4(u0, 1, 0, 0), F4(u1, 1, 0, 0), F4(u1, 0, 0, 0), mode: 2)
            }
            break
        }
    }

    /// Beacon beams: a camera-facing 60 m column fading upward (web CylinderGeometry beam).
    private var camRightXZ = F3(1, 0, 0)
    func setCameraRight(_ r: F3) {
        let l = max(1e-4, (r.x * r.x + r.z * r.z).squareRoot())
        camRightXZ = F3(r.x / l, 0, r.z / l)
    }

    private func beaconBeams(game: Game, time: Float, focus: F3) {
        for b in game.beacons where b.state > 0 {
            let col: F3 = b.state == 2 ? F3(0.25, 1.0, 0.85) : F3(1.0, 0.7, 0.15)
            let i: Float = b.state == 2 ? 0.6 : 0.25 + 0.2 * sinf(time * 10)
            let gy = level.groundY(b.x, b.z)
            let r = camRightXZ * 0.35
            let base = F3(b.x, gy, b.z), top = F3(b.x, gy + 60, b.z)
            let c = F4(col.x * 2, col.y * 2, col.z * 2, i)
            quad(base - r, base + r, top + r, top - r, c, c, c, c, F4(0, 0, 0, 0), F4(0, 1, 0, 0), F4(1, 1, 0, 0), F4(1, 0, 0, 0), mode: 3)
        }
    }

    // ---------------------------------------------------------------- point lights
    private func pointLights(game: Game, dt: Float, time: Float, poses: [MarinePose]) {
        var l0 = lights[0]
        var pyro: Marine? = nil, pyroK = 0
        for (k, m) in game.marines.enumerated() where m.cls == .pyro { pyro = m; pyroK = k }
        let nap = game.napalms.first(where: { $0.active })
        if let py = pyro, py.firing, !py.downed, pyroK < poses.count {
            let p = poses[pyroK]
            l0.pos = F3(p.x + py.ax * 3.5, p.y + 1.4, p.z + py.az * 3.5)
            l0.color = linearRGB(0xff7a28)
            l0.intensity = 110 * (0.8 + 0.2 * sinf(time * 37))
        } else if let n = nap {
            l0.pos = F3(n.x, level.groundY(n.x, n.z) + 1.5, n.z)
            l0.color = linearRGB(0xff6a20)
            l0.intensity = 140 * (0.8 + 0.2 * sinf(time * 29))
        } else if let P = game.marines.first, !P.downed, P.muzzle > 0, P.cls == .assault || P.cls == .gunner, let p = poses.first {
            let (ox, oz) = muzzle(P, p)
            l0.pos = F3(ox + P.ax * 0.4, p.y + 1.3, oz + P.az * 0.4)
            l0.color = linearRGB(P.cls == .assault ? 0xff6040 : 0xffc060)
            l0.intensity = 75 * (0.55 + 0.45 * rnd()) * min(1, P.muzzle + 0.3)
        } else if let P = game.marines.first, !P.downed, P.firing, P.cls == .cryo, let p = poses.first {
            l0.pos = F3(p.x + P.ax * P.beamLen * 0.5, p.y + 1.2, p.z + P.az * P.beamLen * 0.5)
            l0.color = linearRGB(0x60c8ff)
            l0.intensity = 60 * (0.85 + 0.15 * sinf(time * 40))
        } else {
            l0.intensity = max(0, l0.intensity - dt * 600)
        }
        lights[0] = l0
        for k in 1..<3 {
            flashT[k] += dt
            let u = flashT[k] / max(0.001, flashDur[k])
            lights[k].intensity = u < 1 ? flashPeak[k] * (1 - u) * (1 - u) : 0
        }
    }

    // ================================================================ drawing (FX.metal)
    static let pipelines: [PipelineSpec] = [
        .world("decal", "vs_decal", "fs_decal", .multiply), .world("sprite", "vs_sprite", "fs_sprite", .add),
        .world("particleAdd", "vs_particle", "fs_particle_add", .add), .world("particleAlpha", "vs_particle", "fs_particle_alpha", .alpha),
        .world("ribbon", "vs_ribbon", "fs_ribbon", .add),
    ]
    private var renderer: MetalRenderer!
    private var psDecal: MTLRenderPipelineState?, psSprite: MTLRenderPipelineState?, psParticleAdd: MTLRenderPipelineState?
    private var psParticleAlpha: MTLRenderPipelineState?, psRibbon: MTLRenderPipelineState?
    private var texGlow: MTLTexture!, texRing: MTLTexture!, texFill: MTLTexture!, texLane: MTLTexture!, texDecals: MTLTexture!
    private var texDash: MTLTexture!, texStreak: MTLTexture!
    private let decalPool = EventPool<DecalInstance>("stains", capacity: 1500)
    // this frame's arena regions
    private var rDecals = Region(), rGlow = Region(), rRings = Region(), rFill = Region(), rLanes = Region()
    private var rRibbons = Region(), rPA = Region(), rPN = Region()

    /// Live particles drawn this frame (heartbeat `parts`).
    var particleCount: Int { rPA.count + rPN.count }

    /// Resolve pipelines and textures, register the world items (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        psDecal = r.pipeline("decal"); psSprite = r.pipeline("sprite"); psParticleAdd = r.pipeline("particleAdd")
        psParticleAlpha = r.pipeline("particleAlpha"); psRibbon = r.pipeline("ribbon")
        let st = r.store
        texGlow = st.texture("glow"); texRing = st.texture("ring"); texFill = st.texture("fill"); texLane = st.texture("lane")
        texDecals = st.texture("decals"); texDash = st.texture("dash"); texStreak = st.texture("streak")
        r.register(.transparent, order: 200, "decals") { [unowned self] enc in self.encodeDecals(enc) }
        r.register(.transparent, order: 300, "glow sprites") { [unowned self] enc in self.sprites(enc, self.rGlow, self.texGlow) }
        r.register(.transparent, order: 320, "ring sprites") { [unowned self] enc in self.sprites(enc, self.rRings, self.texRing) }
        r.register(.transparent, order: 330, "fill sprites") { [unowned self] enc in self.sprites(enc, self.rFill, self.texFill) }
        r.register(.transparent, order: 340, "lane sprites") { [unowned self] enc in self.sprites(enc, self.rLanes, self.texLane) }
        r.register(.transparent, order: 500, "particles alpha") { [unowned self] enc in self.particles(enc, self.psParticleAlpha, self.rPN) }
        r.register(.transparent, order: 510, "particles add") { [unowned self] enc in self.particles(enc, self.psParticleAdd, self.rPA) }
        r.register(.transparent, order: 600, "ribbons") { [unowned self] enc in self.encodeRibbons(enc) }
    }

    /// Upload this frame's stains, sprites (`teamRings`, Squad/GroundGlyphs, share the ring draw), ribbons, and the
    /// particles (simulated straight into the arena).
    func upload(_ r: MetalRenderer, teamRings: [SpriteInstance], dt: Float) {
        rDecals = decalPool.region(decals, version: decalVersion, renderer: r)
        rGlow = r.upload(glowSprites)
        rRings = r.upload(ringSprites, teamRings)
        rFill = r.upload(fillSprites)
        rLanes = r.upload(laneSprites)
        rRibbons = r.upload(ribbons)
        rPA = Region(); rPN = Region()
        if let a = r.alloc(ParticleInstance.self, max(1, pa.count)) {
            rPA = Region(offset: a.1, count: pa.update(dt: dt, out: a.0, max: max(1, pa.count)))
        } else {
            _ = pa.update(dt: dt, out: nil, max: 0)
        }
        if let a = r.alloc(ParticleInstance.self, max(1, pn.count)) {
            rPN = Region(offset: a.1, count: pn.update(dt: dt, out: a.0, max: max(1, pn.count)))
        } else {
            _ = pn.update(dt: dt, out: nil, max: 0)
        }
    }

    private func encodeDecals(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psDecal, rDecals.count > 0 else { return }
        let r = renderer!
        r.use(enc, ps)
        enc.setDepthBias(-4, slopeScale: -2, clamp: 0)
        enc.setVertexBuffer(rDecals.buffer ?? r.arena, offset: rDecals.offset, index: BufferIndex.instances)
        r.bindMain(enc, texDecals)
        r.drawQuads(enc, rDecals.count)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    private func sprites(_ enc: MTLRenderCommandEncoder, _ reg: Region, _ tex: MTLTexture) {
        guard let ps = psSprite, reg.count > 0 else { return }
        let r = renderer!
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: reg.offset, index: BufferIndex.instances)
        r.bindMain(enc, tex)
        r.drawQuads(enc, reg.count)
    }

    private func particles(_ enc: MTLRenderCommandEncoder, _ ps: MTLRenderPipelineState?, _ reg: Region) {
        guard let ps = ps, reg.count > 0 else { return }
        let r = renderer!
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: reg.offset, index: BufferIndex.instances)
        r.drawQuads(enc, reg.count)
    }

    private func encodeRibbons(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psRibbon, rRibbons.count > 0 else { return }
        let r = renderer!
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: rRibbons.offset, index: BufferIndex.instances)
        r.bindMain(enc, texDash)
        enc.setFragmentTexture(texStreak, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: rRibbons.count)
        r.count(triangles: rRibbons.count / 3)
    }
}
