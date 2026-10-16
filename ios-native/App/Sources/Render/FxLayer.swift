import SpriteKit
import IceHiveCore

// ================================================================
//  FX LAYER — effects driven by GameEvents (ports of fxBugDeath,
//  fxExplosion, fxAcid, fxBulletHit, fxDash, fxNapalmBurst, fxNova,
//  fxTurretDrop, fxHeal of 07-fx.js) and the per-frame visuals of
//  renderFx: muzzle flashes, flames, cryo beam, tracers, globs,
//  grenades, medkits, turret, beacons and the floor indicators.
//  Also collects the dynamic point lights for the darkness overlay.
// ================================================================
final class FxLayer {
    let root = SKNode()
    let pa: ParticleSystem     // additive: fire, sparks, frost, glows
    let pn: ParticleSystem     // alpha: smoke, steam, ichor, debris
    let ground: GroundFx
    private let assets: SpriteAssets
    private let level: Level
    private var rng = SeededRNG(seed: 1234)
    /// Emission scale (web fxK: low 0.4, med 0.7, high 1).
    var fxK: Float = 0.7

    private let tracers: SpritePool
    private var tracerTex: [SKTexture] = []
    private let beam = SKSpriteNode(texture: nil)
    private var beamFrames: [SKTexture] = []
    private let props: SpritePool
    private var globTex: Sprite, grenadeTex: Sprite, medkitTex: Sprite, turretBaseTex: Sprite
    private var turretHeads: [Sprite] = []
    private var beaconTops: [Sprite] = []
    private let beaconBeamTex: SKTexture
    private var beaconTopNodes: [SKSpriteNode] = []
    private var beaconBeamNodes: [SKSpriteNode] = []
    private let propInfo: (glob: SpriteSetInfo, grenade: SpriteSetInfo, medkit: SpriteSetInfo, base: SpriteSetInfo, head: SpriteSetInfo, top: SpriteSetInfo)

    private struct Flash { var x: Float, y: Float, z: Float, r: Float, g: Float, b: Float, peak: Float, t: Float, dur: Float }
    private var flashes: [Flash] = []
    /// Lights collected this frame for the lighting layer.
    private(set) var lights: [PointLight] = []
    private var steamT: Float = 0

    init(assets: SpriteAssets, level: Level, worldRoot: SKNode, groundRoot: SKNode) {
        self.assets = assets
        self.level = level
        pa = ParticleSystem(parent: root, assets: assets, level: level, additive: true, capacity: 900)
        pn = ParticleSystem(parent: root, assets: assets, level: level, additive: false, capacity: 520)
        ground = GroundFx(assets: assets, level: level, groundRoot: groundRoot, worldRoot: worldRoot, decalCap: 420, corpseCap: 300)
        tracers = SpritePool(parent: root, capacity: 420) { n in
            n.blendMode = .add
            n.anchorPoint = CGPoint(x: 1, y: 0.5)
            n.zPosition = ZBand.beams
        }
        props = SpritePool(parent: root, capacity: 64) { _ in }
        tracerTex = ["tracer_assault", "tracer_gunner", "tracer_turret"].map { assets.texture($0) }
        beamFrames = (0..<8).map { assets.texture("cryo_beam_\($0)") }
        beam.blendMode = .add
        beam.anchorPoint = CGPoint(x: 0, y: 0.5)
        beam.zPosition = ZBand.beams + 1
        beam.isHidden = true
        root.addChild(beam)
        globTex = assets.sprite("glob")
        grenadeTex = assets.sprite("grenade")
        medkitTex = assets.sprite("medkit")
        turretBaseTex = assets.sprite("turret_base")
        turretHeads = (0..<16).map { assets.sprite("turret_head_\($0 < 10 ? "0" : "")\($0)") }
        beaconTops = (0..<4).map { assets.sprite("beacon_top_\($0)") }
        beaconBeamTex = assets.texture("beacon_beam")
        let M = assets.manifest
        propInfo = (M.info("glob"), M.info("grenade"), M.info("medkit"), M.info("turret_base"), M.info("turret_head"), M.info("beacon_top"))
        for _ in level.layout.beacons {
            let top = SKSpriteNode(texture: beaconTops.first?.tex)
            top.zPosition = ZBand.glow + 2
            top.colorBlendFactor = 1
            root.addChild(top)
            beaconTopNodes.append(top)
            let bm = SKSpriteNode(texture: beaconBeamTex)
            bm.blendMode = .add
            bm.anchorPoint = CGPoint(x: 0.5, y: 0)
            bm.colorBlendFactor = 1
            bm.zPosition = ZBand.beams + 2
            bm.size = CGSize(width: 0.7 * Iso.ppm, height: CGFloat(60 * Iso.cosPitch) * Iso.ppm)
            root.addChild(bm)
            beaconBeamNodes.append(bm)
        }
    }

    @inline(__always) private func rr(_ a: Float, _ b: Float) -> Float { a + (b - a) * rng.next() }
    @inline(__always) private func rnd() -> Float { rng.next() }
    @inline(__always) private func num(_ base: Float) -> Int { Int((base * fxK).rounded(.up)) }

    /// Web flashLight(): a short-lived point light.
    func flashLight(_ x: Float, _ y: Float, _ z: Float, _ hex: UInt32, _ peak: Float, _ dur: Float) {
        let r = Float((hex >> 16) & 255) / 255, g = Float((hex >> 8) & 255) / 255, b = Float(hex & 255) / 255
        let f = Flash(x: x, y: y + level.groundY(x, z), z: z, r: r, g: g, b: b, peak: peak, t: 0, dur: dur)
        if flashes.count < 8 { flashes.append(f) } else {
            var weakest = 0
            for k in 1..<flashes.count where flashes[k].peak * (1 - flashes[k].t / flashes[k].dur) < flashes[weakest].peak * (1 - flashes[weakest].t / flashes[weakest].dur) { weakest = k }
            flashes[weakest] = f
        }
    }

    // ================================================================ events
    func handle(_ e: GameEvent, game: Game) {
        switch e {
        case .bugKilled(let type, let pos, let frozen, _, _, let scale, let height):
            bugDeath(type, pos.x, pos.y, frozen, scale, height)
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
        case .healed(let m, _, _):
            if m < game.marines.count { heal(game.marines[m]) }
        case .revived(let m):
            if m < game.marines.count { heal(game.marines[m]) }
        case .turretShot(let pos, let angle):
            let ax = sinf(angle), az = cosf(angle)
            pa.emit(pos.x + ax * 0.75, 1.05, pos.y + az * 0.75, ax * 2, 0, az * 2, 0.05, 0.7, 0.3, 0.5, 1, 0.5, 1, 0, 0, 0, tex: .flash)
        case .bugFrozen(let pos):
            for _ in 0..<num(3) { pa.emit(pos.x, 0.4, pos.y, rr(-1, 1), rr(0.5, 1.5), rr(-1, 1), rr(0.2, 0.4), 0.2, 0.05, 0.45, 0.75, 1, 0.8, 2, 1, 3) }
        default:
            break
        }
    }

    private static let ichor: [(Float, Float, Float)] = [(0.62, 0.1, 0.22), (0.5, 0.58, 0.1), (0.58, 0.12, 0.15), (0.62, 0.24, 0.08)]
    private static let ichorP: [(Float, Float, Float)] = [(0.3, 0.05, 0.14), (0.28, 0.32, 0.04), (0.26, 0.06, 0.08), (0.32, 0.12, 0.04)]

    private func bugDeath(_ type: BugType, _ x: Float, _ z: Float, _ frozen: Bool, _ sc: Float, _ y: Float) {
        let ty = type.rawValue
        if frozen {
            for _ in 0..<num(8) { pa.emit(x, 0.4, z, rr(-3, 3), rr(1, 4), rr(-3, 3), rr(0.25, 0.5), 0.2, 0.04, 0.35, 0.6, 0.8, 1, 9, 1, 3, tex: .shard) }
            ground.addDecal("decal_frost_\(Int(rnd() * 2) & 1)", x: x, z: z, size: sc * 0.8)
            return
        }
        let cp = FxLayer.ichorP[ty]
        pa.emit(x, 0.35 * sc + y, z, 0, 0.6, 0, 0.11, 0.7 * sc, 1.5 * sc, 1.0, 0.45, 0.7, 0.85, 0, 0, 3)
        for _ in 0..<num(type == .brute ? 9 : 2) {
            pn.emit(x, 0.4 + y, z, rr(-3.2, 3.2), rr(2, 5.5), rr(-3.2, 3.2), rr(0.5, 0.9), rr(0.08, 0.15) * (type == .brute ? 1.6 : 1), 0.07, 0.13, 0.07, 0.11, 1, 15, 0.4, 0, tex: .chunk)
        }
        if type == .brute { ground.splash(x, z, 4, 0.3, 0.06, 0.16, 0.35) }
        let streak = rnd() < 0.5
        ground.addDecal("decal_ichor_\(type.id)_\(streak ? "streak" : "splat")_\(Int(rnd() * 2) & 1)", x: x, z: z, size: sc * rr(1.0, 1.5))
        if type != .boomer {
            ground.addCorpse(type: type, x: x, z: z, scale: sc)
        } else {
            ground.addDecal("decal_burn_\(Int(rnd() * 2) & 1)", x: x, z: z, size: 2.6)
        }
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
            for _ in 0..<num(60) {
                let a = rnd() * 2 * Float.pi
                pa.emit(x + cosf(a) * r * 0.95, 0.3, z + sinf(a) * r * 0.95, cosf(a) * 2, rr(1, 4), sinf(a) * 2, rr(0.2, 0.45), 0.25, 0.05, 0.4, 1, 0.9, 1, 4, 1, 3)
            }
            flashLight(x, 3, z, 0x40ffe0, 380, 0.4)
            ground.splash(x, z, r * 2.4, 0.06, 0.32, 0.28, 0.45)
            return
        case .frost:
            for _ in 0..<num(9) {
                let a = rnd() * 2 * Float.pi, s = rr(2, 6)
                pa.emit(x, 0.4, z, cosf(a) * s, rr(1, 3), sinf(a) * s, rr(0.3, 0.6), 0.26, 0.05, 0.45, 0.75, 1.0, 0.9, 6, 1.5, 3, tex: .shard)
            }
            for _ in 0..<num(3) { pn.emit(x, 0.4, z, rr(-3, 3), rr(2, 4.5), rr(-3, 3), rr(0.5, 0.8), rr(0.1, 0.16), 0.08, 0.55, 0.75, 0.9, 1, 15, 0.4, 0, tex: .chunk) }
            return
        default:
            break
        }
        let big = kind.isBig
        for _ in 0..<num(big ? 26 : 8) {
            let a = rnd() * 2 * Float.pi, s = rr(0.5, r * 1.3)
            pa.emit(x + cosf(a) * 0.3, rr(0.3, 1), z + sinf(a) * 0.3, cosf(a) * s, rr(0.5, 3), sinf(a) * s, rr(0.35, 0.7), rr(0.6, 1.1), rr(1.3, 2.2), 1, 0.55, 0.2, 0.45, -1, 2.2, 1)
        }
        for _ in 0..<num(big ? 22 : 8) {
            let a = rnd() * 2 * Float.pi, s = rr(6, 16)
            pa.emit(x, 0.5, z, cosf(a) * s, rr(2, 7), sinf(a) * s, rr(0.3, 0.7), 0.12, 0.04, 1.0, 0.75, 0.35, 1, 14, 0.6, 3, tex: .spark)
        }
        for _ in 0..<num(big ? 18 : 6) {
            let a = rnd() * 2 * Float.pi, s = rr(0.5, r)
            pn.emit(x + cosf(a) * 0.5, rr(0.4, 1.2), z + sinf(a) * 0.5, cosf(a) * s, rr(1, 3), sinf(a) * s, rr(0.5, 0.9), rr(1.0, 1.6), rr(2.2, 3.4), 1.0, 0.42, 0.12, 0.85, -1.5, 2.0, 1)
        }
        for _ in 0..<num(big ? 16 : 4) {
            pn.emit(x + rr(-1, 1), rr(0.5, 1.5), z + rr(-1, 1), rr(-1.2, 1.2), rr(1, 2.5), rr(-1.2, 1.2), rr(1.6, 2.6), 1.6, 4.2, 0.06, 0.055, 0.06, 0.75, -0.3, 0.8, 2)
        }
        ground.addDecal("decal_burn_\(Int(rnd() * 2) & 1)", x: x, z: z, size: r * (big ? 1.1 : 0.8))
        flashLight(x, 1.6, z, kind == .boomer ? 0xff5a20 : 0xff7a30, big ? 220 : 90, big ? 0.5 : 0.25)
        ground.splash(x, z, r * (big ? 2.4 : 2.0), 0.4, 0.14, 0.03, big ? 0.6 : 0.3)
    }

    private func acid(_ x: Float, _ z: Float) {
        for _ in 0..<num(9) { pa.emit(x, 0.2, z, rr(-2.5, 2.5), rr(1, 3.5), rr(-2.5, 2.5), rr(0.3, 0.6), 0.2, 0.05, 0.7, 1.0, 0.15, 1, 8, 1, 3) }
        for _ in 0..<num(4) { pn.emit(x + rr(-0.6, 0.6), 0.2, z + rr(-0.6, 0.6), 0, rr(0.4, 1), 0, rr(0.8, 1.4), 0.5, 1.4, 0.4, 0.55, 0.15, 0.35, -0.2, 1, 2) }
        ground.addDecal("decal_acid_\(Int(rnd() * 2) & 1)", x: x, z: z, size: rr(1.6, 2.1))
    }

    private func bulletHit(_ x: Float, _ z: Float, _ dx: Float, _ dz: Float, _ killed: Bool) {
        if rnd() > 0.6 * fxK + 0.2 { return }
        pa.emit(x, 0.45, z, -dx * rr(2, 5) + rr(-2, 2), rr(1, 3), -dz * rr(2, 5) + rr(-2, 2), 0.18, 0.14, 0.04, 1.0, 0.75, 0.4, 1, 10, 1, 3, tex: .spark)
        if killed || rnd() < 0.4 {
            pn.emit(x, 0.4, z, rr(-1.5, 1.5) + dx * 2, rr(1, 2.5), rr(-1.5, 1.5) + dz * 2, 0.4, 0.13, 0.05, 0.45, 0.08, 0.2, 0.9, 10, 0.5, 0, tex: .chunk)
        }
    }

    private func dash(_ m: Marine) {
        for _ in 0..<num(12) { pa.emit(m.x + rr(-0.3, 0.3), rr(0.3, 1.5), m.z + rr(-0.3, 0.3), -m.dashX * rr(1, 4), rr(0, 1), -m.dashZ * rr(1, 4), rr(0.2, 0.4), 0.35, 0.05, 0.3, 0.9, 0.85, 0.6, 0, 3, 0) }
        for _ in 0..<num(5) { pn.emit(m.x, 0.15, m.z, rr(-1.5, 1.5), rr(0.3, 1), rr(-1.5, 1.5), rr(0.5, 0.9), 0.4, 1.3, 0.75, 0.8, 0.88, 0.4, -0.2, 2, 2) }
    }

    private func napalmBurst(_ x: Float, _ z: Float, _ r: Float) {
        for _ in 0..<num(70) {
            let a = rnd() * 2 * Float.pi, s = rr(r * 0.6, r * 1.6)
            pa.emit(x, 0.5, z, cosf(a) * s, rr(0.5, 2), sinf(a) * s, rr(0.4, 0.8), 0.6, 2.0, 1, 0.6, 0.22, 0.55, -1, 1.6, 1)
        }
        flashLight(x, 1.5, z, 0xff6a20, 200, 0.6)
        ground.splash(x, z, r * 2.4, 0.38, 0.14, 0.03, 0.7)
        ground.addDecal("decal_burn_\(Int(rnd() * 2) & 1)", x: x, z: z, size: r * 1.8)
    }

    private func nova(_ x: Float, _ z: Float, _ r: Float) {
        for _ in 0..<num(70) {
            let a = rnd() * 2 * Float.pi, s = rr(r * 0.8, r * 2.2)
            pa.emit(x, rr(0.2, 1), z, cosf(a) * s, rr(0.2, 2), sinf(a) * s, rr(0.4, 0.8), rr(0.2, 0.45), 0.05, 0.3, 0.55, 0.8, 1, 1, 2.5, 3)
        }
        flashLight(x, 2, z, 0x6ad8ff, 120, 0.45)
        ground.splash(x, z, r * 2.4, 0.05, 0.13, 0.22, 0.5)
    }

    private func turretDrop(_ x: Float, _ z: Float) {
        for _ in 0..<num(16) { pa.emit(x, 0.5, z, rr(-4, 4), rr(2, 6), rr(-4, 4), rr(0.2, 0.5), 0.12, 0.03, 0.6, 1, 0.6, 1, 14, 0.5, 3, tex: .spark) }
        for _ in 0..<num(6) { pn.emit(x, 0.2, z, rr(-1, 1), rr(0.3, 1), rr(-1, 1), 1, 0.5, 1.6, 0.7, 0.75, 0.82, 0.4, -0.1, 1.5, 2) }
    }

    private func heal(_ m: Marine) {
        for _ in 0..<18 { pa.emit(m.x + rr(-0.5, 0.5), rr(0.2, 1.4), m.z + rr(-0.5, 0.5), 0, rr(1, 2.5), 0, rr(0.5, 0.9), 0.25, 0.05, 0.3, 1, 0.5, 1, -0.5, 1, 0) }
    }

    /// Every effect once at (x, z) — run behind the loading cover so SpriteKit builds its pipelines, uploads and
    /// first-use textures (multiply decals, additive particles, corpses, ring shaders) before anyone sees a frame.
    func warmUp(_ x: Float, _ z: Float) {
        for t in BugType.allCases {
            bugDeath(t, x + 1, z + 1, false, t.spec.scale, 0)
            bugDeath(t, x - 1, z + 1, true, t.spec.scale, 0)
        }
        for kind in [ExplosionKind.frag, .mini, .boomer, .frost, .pulse] { explosion(x, z - 1, 2.5, kind) }
        acid(x + 1, z - 1)
        bulletHit(x, z, 1, 0, true)
        napalmBurst(x - 2, z, 3)
        nova(x, z + 2, 3)
        turretDrop(x + 2, z)
        for k in 0..<4 { ground.splash(x + Float(k), z, 3, 0.3, 0.2, 0.1, 0.5) }
        for ind in ground.beaconInd { ind.show(x: x, y: level.groundY(x, z), z: z, progress: 0.5, r: 1, g: 0.6, b: 0.2, alpha: 1) }
        ground.liftInd.show(x: x, y: level.groundY(x, z), z: z, progress: 0.5, r: 0.25, g: 1, b: 0.85, alpha: 1)
        for ind in ground.reviveInd { ind.show(x: x, y: level.groundY(x, z), z: z, progress: 0.5, r: 1, g: 0.5, b: 0.4, alpha: 1) }
        flashLight(x, 1.5, z, 0xff7a30, 200, 0.3)
        warmRings = 8
    }
    /// Frames the warm-up keeps every ring indicator on screen (their own updates wait).
    private var warmRings = 0

    // ================================================================ per frame
    /// Call before the marine layer draws its team rings; `endFrame()` after `update`.
    func beginFrame() {
        ground.beginFrame()
        lights.removeAll(keepingCapacity: true)
    }

    func endFrame() { ground.endFrame() }

    /// Pre-create every pooled sprite behind the loading cover (no node allocation once the mission runs).
    func reserve() {
        pa.reserve(); pn.reserve()
        tracers.reserve(200); props.reserve(64)
        ground.reserve()
    }

    /// New mission: drop every stain, corpse, particle and light.
    func reset() {
        pa.clear(); pn.clear()
        ground.clear()
        flashes.removeAll()
        lights.removeAll()
    }

    func update(game: Game, dt: Float, time: Float, visible: CGRect, liftRise: Float, feet: [(Float, Float, Float)]) {
        let lv = level
        // continuous emitters tied to the marines
        for (k, m) in game.marines.enumerated() where !m.downed && k < feet.count {
            let f = feet[k]
            let mp = game.muzzlePosition(m)
            let ox = mp.x + (f.0 - m.x), oz = mp.y + (f.2 - m.z)
            if dt > 0 && m.muzzle > 0 && (m.cls == .assault || m.cls == .gunner) {
                let c: (Float, Float, Float) = m.cls == .assault ? (1, 0.35, 0.25) : (1, 0.85, 0.4)
                pa.emit(ox, 1.2, oz, m.ax * 2, 0, m.az * 2, 0.05, 0.9, 0.4, c.0, c.1, c.2, 1, 0, 0, 0, tex: .flash)
                if m.muzzle > 0.85 && rnd() < (m.isPlayer ? 0.7 : 0.3) * fxK {
                    pn.emit(m.x + m.az * 0.3, 1.1, m.z - m.ax * 0.3, m.az * rr(1.5, 2.6), rr(1.5, 3), -m.ax * rr(1.5, 2.6), rr(0.45, 0.7), 0.06, 0.05, 0.95, 0.68, 0.28, 1, 14, 0.3, 0, tex: .dot)
                }
                let fl = (0.55 + 0.45 * rnd()) * min(1, m.muzzle) * (m.isPlayer ? 0.34 : 0.22)
                ground.splashNow(ox + m.ax * 0.6, oz + m.az * 0.6, 3.6, c.0 * fl, c.1 * fl, c.2 * fl)
                if m.isPlayer {
                    let i = 0.5 * (0.55 + 0.45 * rnd()) * min(1, m.muzzle + 0.3)
                    lights.append(PointLight(x: ox + m.ax * 0.4, y: f.1 + 1.0, z: oz + m.az * 0.4, radius: 5, intensity: i,
                                             r: 1, g: m.cls == .assault ? 0.55 : 0.8, b: m.cls == .assault ? 0.4 : 0.5))
                }
            }
            if m.firing && m.cls == .pyro {
                let fl = 0.2 + 0.07 * rnd()
                ground.splashNow(ox + m.ax * 3, oz + m.az * 3, 6.5, fl, fl * 0.45, fl * 0.12)
                if dt > 0 {
                    let cnt = max(1, Int((150 * fxK * dt + rnd() * 0.5).rounded()))
                    for _ in 0..<cnt {
                        let sp = rr(11, 15), sx = rr(-1, 1) * 2.6, sy = rr(-0.2, 1.2)
                        pa.emit(ox, 1.15, oz, m.ax * sp - m.az * sx + m.vx * 0.5, sy, m.az * sp + m.ax * sx + m.vz * 0.5, rr(0.42, 0.58), 0.3, rr(1.4, 2.1), 1, 0.78, 0.4, 0.5, -1.5, 1.25, 1)
                    }
                    if rnd() < 30 * fxK * dt { pn.emit(ox + m.ax * 6, 1.4, oz + m.az * 6, m.ax * 2, 1.4, m.az * 2, 1.4, 1, 3, 0.09, 0.08, 0.08, 0.4, -0.4, 0.6, 2) }
                }
                lights.append(PointLight(x: m.x + m.ax * 3.5, y: f.1 + 1, z: m.z + m.az * 3.5, radius: 9, intensity: 0.75 * (0.8 + 0.2 * sinf(time * 37)), r: 1, g: 0.55, b: 0.25))
            }
            if m.firing && m.cls == .cryo {
                let fl = 0.1 + 0.03 * rnd()
                ground.splashNow(ox + m.ax * m.beamLen * 0.45, oz + m.az * m.beamLen * 0.45, 5.5, fl * 0.45, fl * 0.8, fl)
                if dt > 0 && rnd() < 40 * fxK * dt {
                    let t = rnd() * m.beamLen
                    pa.emit(ox + m.ax * t, 0.8, oz + m.az * t, rr(-1, 1), rr(-0.5, 1), rr(-1, 1), rr(0.3, 0.6), 0.25, 0.05, 0.6, 0.9, 1, 1, 1, 1, 3)
                }
                lights.append(PointLight(x: m.x + m.ax * m.beamLen * 0.5, y: f.1 + 1, z: m.z + m.az * m.beamLen * 0.5, radius: 7, intensity: 0.45, r: 0.45, g: 0.75, b: 1))
            }
        }
        // napalm fields
        for np in game.napalms where np.active {
            let fl = 0.16 + 0.05 * rnd()
            ground.splashNow(np.x, np.z, np.r * 2.6, fl, fl * 0.42, fl * 0.1)
            if dt > 0 {
                let cnt = Int((240 * fxK * dt * (np.r / 5) + rnd()).rounded(.down))
                for _ in 0..<cnt {
                    let a = rnd() * 2 * Float.pi, rad = np.r + rr(-0.4, 0.4)
                    pa.emit(np.x + cosf(a) * rad, 0.15, np.z + sinf(a) * rad, rr(-0.3, 0.3), rr(1.5, 3), rr(-0.3, 0.3), rr(0.3, 0.5), 0.25, 0.9, 1, 0.6, 0.2, 0.6, -1, 1, 1)
                }
            }
            lights.append(PointLight(x: np.x, y: lv.groundY(np.x, np.z) + 1, z: np.z, radius: np.r + 4, intensity: 0.8 * (0.8 + 0.2 * sinf(time * 29)), r: 1, g: 0.5, b: 0.2))
        }
        // extraction: steam off the lift rim, sparks into the shaft
        if game.stage == .extract && dt > 0 {
            let L = level.lift, ry = L.y + liftRise
            let ns = Int((140 * fxK * dt + rnd()).rounded(.down)), nk = Int((90 * fxK * dt + rnd()).rounded(.down))
            for _ in 0..<ns {
                let a = rnd() * 2 * Float.pi
                pn.emit(L.x + cosf(a) * L.r, ry + 0.2, L.z + sinf(a) * L.r, cosf(a) * 0.6, rr(-2, -0.5), sinf(a) * 0.6, 1.2, 0.6, 2.4, 0.8, 0.85, 0.9, 0.35, 0, 0.6, 2, absolute: true)
            }
            for _ in 0..<nk {
                let a = rnd() * 2 * Float.pi
                pa.emit(L.x + cosf(a) * (L.r + 0.6), ry - 0.3, L.z + sinf(a) * (L.r + 0.6), cosf(a) * rr(0.5, 2), rr(-1, 1.5), sinf(a) * rr(0.5, 2), rr(0.4, 0.8), 0.14, 0.04, 1.0, 0.7, 0.3, 1, 12, 0.3, 3, tex: .spark, absolute: true)
            }
        }
        // vent steam near the camera
        steamT -= dt
        if steamT <= 0 && dt > 0 {
            steamT = 0.12
            let c = Iso.ground(from: CGPoint(x: visible.midX, y: visible.midY), height: 0)
            for v in level.layout.vents where abs(v.x - c.x) < 30 && abs(v.y - c.y) < 30 && rnd() < 0.6 {
                pn.emit(v.x + rr(-0.4, 0.4), 0.2, v.y + rr(-0.4, 0.4), rr(-0.3, 0.3) + 0.4, rr(1.2, 2), rr(-0.3, 0.3), rr(2, 3), 0.6, 3.2, 0.8, 0.85, 0.92, 0.22, -0.15, 0.3, 2)
            }
        }
        // short point lights (blasts)
        var k = 0
        while k < flashes.count {
            flashes[k].t += dt
            let f = flashes[k]
            if f.t >= f.dur { flashes.remove(at: k); continue }
            let u = f.t / f.dur
            lights.append(PointLight(x: f.x, y: f.y, z: f.z, radius: 4 + f.peak.squareRoot() * 0.45,
                                     intensity: min(1.4, f.peak / 140) * (1 - u) * (1 - u), r: f.r, g: f.g, b: f.b))
            k += 1
        }

        pa.update(dt: dt, visible: visible)
        pn.update(dt: dt, visible: visible)
        ground.updateSplashes(dt: dt)
        ground.updateTelegraphs(game: game, time: time)
        updateTracers(game: game, visible: visible)
        updateBeam(game: game, time: time, feet: feet)
        updateProps(game: game, time: time, dt: dt, liftRise: liftRise)
    }

    private func updateTracers(game: Game, visible: CGRect) {
        let P = game.projectiles
        tracers.begin()
        let lv = level
        for k in 0..<P.count {
            let p = P.position(k), d = P.direction(k)
            let ci = max(0, min(2, P.colorIndex(k)))
            let len = min(2.4, P.speed(k) * 0.028)
            let y = lv.groundY(p.x, p.y) + 1.2
            let head = Iso.point(p.x, y, p.y)
            if !visible.contains(head) { continue }
            guard let n = tracers.next() else { break }
            let tail = Iso.point(p.x - d.x * len, y, p.y - d.y * len)
            if n.texture !== tracerTex[ci] { n.texture = tracerTex[ci] }
            let dx = head.x - tail.x, dy = head.y - tail.y
            n.position = head
            n.zRotation = CGFloat(atan2(Double(dy), Double(dx)))
            n.size = CGSize(width: max(1, (dx * dx + dy * dy).squareRoot()), height: (ci == 0 ? 0.15 : 0.1) * Iso.ppm * 1.4)
        }
        tracers.end()
    }

    private func updateBeam(game: Game, time: Float, feet: [(Float, Float, Float)]) {
        var shown = false
        for (k, m) in game.marines.enumerated() where m.cls == .cryo && m.firing && !m.downed && k < feet.count {
            let f = feet[k]
            let mp = game.muzzlePosition(m)
            let ox = mp.x + (f.0 - m.x), oz = mp.y + (f.2 - m.z)
            let a = Iso.point(ox, f.1 + 1.2, oz)
            let ex = ox + m.ax * m.beamLen, ez = oz + m.az * m.beamLen
            let b = Iso.point(ex, level.groundY(ex, ez) + 0.5, ez)
            let fr = beamFrames[Int(time * 25.6) % beamFrames.count]
            if beam.texture !== fr { beam.texture = fr }
            let dx = b.x - a.x, dy = b.y - a.y
            beam.position = a
            beam.zRotation = CGFloat(atan2(Double(dy), Double(dx)))
            beam.size = CGSize(width: max(1, (dx * dx + dy * dy).squareRoot()), height: 2.6 * Iso.ppm * 0.85)
            beam.alpha = CGFloat(0.85 + 0.15 * sinf(time * 40))
            shown = true
            break
        }
        if beam.isHidden == shown { beam.isHidden = !shown }
    }

    private func prop(_ tex: Sprite, _ info: SpriteSetInfo, _ x: Float, _ y: Float, _ z: Float, scale: CGFloat = 1, z band: CGFloat? = nil) -> SKSpriteNode? {
        guard let n = props.next() else { return nil }
        n.show(tex, size: CGSize(width: info.size.width * scale, height: info.size.height * scale), anchor: info.anchor)
        n.position = Iso.point(x, y, z)
        n.zPosition = band ?? ZBand.object(Iso.nearness(x, y, z)) + 0.5
        n.colorBlendFactor = 0
        n.alpha = 1
        return n
    }

    private func updateProps(game: Game, time: Float, dt: Float, liftRise: Float) {
        let lv = level
        props.begin()
        // acid globs in flight
        let G = game.globs
        for k in 0..<G.count {
            let u = G.progress(k), a = G.from(k), b = G.to(k)
            let gx = a.x + (b.x - a.x) * u, gz = a.y + (b.y - a.y) * u
            let gy = lv.groundY(a.x, a.y) + (lv.groundY(b.x, b.y) - lv.groundY(a.x, a.y)) * u + 0.6 + sinf(u * Float.pi) * 3.2
            _ = prop(globTex, propInfo.glob, gx, gy, gz, z: ZBand.glow + 3)
            if dt > 0 && rnd() < 0.5 { pa.emit(gx, gy, gz, 0, 0, 0, 0.25, 0.3, 0.05, 0.6, 1, 0.15, 0.8, 1, 0, 0, absolute: true) }
        }
        // grenades
        for g in game.grenades where g.active {
            let u = g.progress
            let x = g.sx + (g.tx - g.sx) * u, z = g.sz + (g.tz - g.sz) * u
            let y = lv.groundY(g.sx, g.sz) + (lv.groundY(g.tx, g.tz) - lv.groundY(g.sx, g.sz)) * u + 1.2 + sinf(u * Float.pi) * (g.big ? 3 : 1.2) - u
            _ = prop(grenadeTex, propInfo.grenade, x, y, z, scale: g.big ? 1 : 0.7, z: ZBand.glow + 3)
            if dt > 0 { pa.emit(x, y, z, 0, 0, 0, 0.12, 0.25, 0.05, 1, 0.7, 0.3, 0.7, 0, 0, 0, absolute: true) }
        }
        // medkits (blink in their last 5 s)
        for m in game.medkits where m.active && (m.t > 5 || sinf(time * 14) > 0) {
            _ = prop(medkitTex, propInfo.medkit, m.x, lv.groundY(m.x, m.z) + 0.12 + sinf(time * 3 + m.x) * 0.06, m.z)
        }
        // turret
        let T = game.turret
        if T.active {
            let ty = lv.groundY(T.x, T.z)
            _ = prop(turretBaseTex, propInfo.base, T.x, ty, T.z)
            if let h = prop(turretHeads[Iso.dir16(T.angle)], propInfo.head, T.x, ty, T.z) { h.zPosition += 0.1 }
        }
        props.end()

        // beacons: spinning top, beam, ring indicator
        for (k, b) in game.beacons.enumerated() where k < beaconTopNodes.count {
            let gy = lv.groundY(b.x, b.z)
            let col: (Float, Float, Float) = b.state == 2 ? (0.25, 1.0, 0.85) : (b.state == 1 ? (1.0, 0.7, 0.15) : (1.0, 0.25, 0.15))
            let top = beaconTopNodes[k]
            let spin = time * (b.state == 1 ? 4 : 1.2)
            let fi = Iso.wrap(Int(spin / (Float.pi / 2) * 4), 4)
            top.show(beaconTops[fi], size: propInfo.top.size, anchor: propInfo.top.anchor)
            top.position = Iso.point(b.x, gy + 2.9 + sinf(time * 2 + Float(k)) * 0.12, b.z)
            top.color = SKColor(red: CGFloat(min(1, col.0 * 1.3)), green: CGFloat(min(1, col.1 * 1.3)), blue: CGFloat(min(1, col.2 * 1.3)), alpha: 1)
            let beamNode = beaconBeamNodes[k]
            if b.state > 0 {
                beamNode.isHidden = false
                beamNode.position = Iso.point(b.x, gy + 2.2, b.z)
                let i: Float = b.state == 2 ? 0.6 : 0.25 + 0.2 * sinf(time * 10)
                beamNode.color = Tone.color(col.0 * i * 2, col.1 * i * 2, col.2 * i * 2)
            } else {
                beamNode.isHidden = true
            }
            if k < ground.beaconInd.count && warmRings == 0 {
                ground.beaconInd[k].show(x: b.x, y: gy + 0.04, z: b.z, progress: b.progress, r: col.0, g: col.1, b: col.2, alpha: b.state == 2 ? 0.5 : 1)
            }
            if b.state == 1 {
                lights.append(PointLight(x: b.x, y: gy + 2, z: b.z, radius: 6.5, intensity: 0.35 + 0.1 * sinf(time * 10), r: 1, g: 0.75, b: 0.35))
            }
        }
        // lift indicator
        let st = game.stage
        if warmRings > 0 {
            warmRings -= 1
            return
        }
        if st == .toLift || st == .hold || st == .extract {
            let L = lv.lift
            let prog: Float = st == .hold ? 1 - game.liftT / game.liftDur : (st == .extract ? 1 : 0)
            let ex = st == .extract ? min(1, game.extractT / 2) : 0
            ground.liftInd.show(x: L.x, y: L.y + liftRise + 0.06, z: L.z, progress: prog, r: 0.25, g: 1, b: 0.85,
                                alpha: st == .extract ? 0.4 + 0.4 * ex * ex * (3 - 2 * ex) : 0.4)
        } else {
            ground.liftInd.hide()
        }
        // revive rings
        for k in 0..<ground.reviveInd.count {
            if k < game.marines.count && game.marines[k].downed {
                let m = game.marines[k]
                ground.reviveInd[k].show(x: m.x, y: lv.groundY(m.x, m.z) + 0.06, z: m.z, progress: m.revive,
                                         r: 1, g: 0.25 + m.revive * 0.6, b: 0.2 + m.revive * 0.6, alpha: 1)
            } else {
                ground.reviveInd[k].hide()
            }
        }
    }

    var nodeCount: Int { pa.visibleCount + pn.visibleCount + tracers.used + props.used + ground.nodeCount }
}
