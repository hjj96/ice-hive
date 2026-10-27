import Foundation
import Metal
import IceHiveCore

// ================================================================
//  METAL EFFECTS — the effects of the world (owned by WP5 «Эффекты»):
//  core GameEvents and the per-frame state of the weapons become
//    • GPU particle emitter records (FX/GPUParticles.swift — the
//      compute particles: sparks, embers, ice, flames, blasts, smoke,
//      steam, ichor, gibs, casings, flashes);
//    • stains (FX/Decals.swift — wet forward decals on High);
//    • beams (FX/Ribbons.swift — short HDR tracers, sight glints, the
//      cryo beam, beacon columns);
//    • light on the deck (additive floor fx: shock rings, ground fire,
//      acid glow, frost bursts) and MAX-blended telegraphs (thin rims,
//      soft acid pools, charge lanes) — FX.metal, one draw each;
//    • short-lived grid lights (WP2 LightingHub.emit): every shot's
//      muzzle, hits that kill, blasts, acid, frost, heals;
//    • heat distortion sprites (High; the composite of WP1 reads them).
//  Shooting (the owner's priority): each round pops a light at the
//  muzzle, throws a casing (rifle, rotary) and a few muzzle sparks, its
//  tracer is a short bolt with a white-hot head; a hit at the real hit
//  point on the bug (WorldSwarm.impactPoint when MetalWorld wires the
//  swarm in, else the bug's body height from the core) throws
//  velocity-stretched sparks off the chitin that bounce and cool, a
//  hit flash and the type's ichor, wet splats on the deck. The flamer
//  is a flipbook jet with lit smoke, embers, scorch and heat haze; the
//  cryo beam a crackling white-cyan ribbon throwing ice glints and
//  frost mist that rimes the deck. Explosions: a white-hot core, a
//  flipbook fireball, flame licks, a fan of sparks, embers, gibs, dark
//  smoke, a shock ring on the deck, heat waves, a scorch with cooling
//  embers, a big light (the exposure dip is MetalWorld's). Hard caps
//  per tier: particles (ring), live flames, live explosions; every
//  sprite ≤ 25 % of the screen height (Particles.metal).
//  Corpses are Swarm/Corpses.swift (fed with this file's random
//  sequence), the squad's ground glyphs Squad/GroundGlyphs.swift.
//  Look-dev: `-fxSheet` (every effect staged around the squad, frozen
//  mid-air), `-fxPeak` (the plan's scripted peak: three chained
//  boomers + napalm + the cryo beam, every 2.5 s), `-fxHigh` (both on
//  the High tier). Once per second `hb fx …` (counts, caps, CPU).
// ================================================================

/// Flat floor sprite of the web renderer (`fx.glowSprites`, read by LightGrid; GroundGlyphs' empty team rings).
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

/// Light on the deck / telegraph (`struct FloorFx` in FX.metal), 64 bytes.
struct FloorFx {
    /// xyz on the deck, w = radius (m; lanes: half width).
    var center: F4
    /// rgb HDR, w = opacity.
    var color: F4
    /// x mode (FloorMode), y progress 0…1, z thickness (fraction of the radius), w seed / blink.
    var params: F4
    /// xy unit direction in xz (lanes), z half length (lanes), w slope along the direction (dy / m).
    var axis: F4
}

/// One heat sprite of the distortion pass (`struct HeatInstance` in FX.metal), 32 bytes.
struct HeatInstance {
    /// xyz centre, w = radius (m).
    var pos: F4
    /// x strength 0…1, y mode (0 blob, 1 expanding wave, 2 rising column), z progress 0…1, w seed.
    var params: F4
}

enum FloorMode: Float { case glow = 0, shock = 1, fire = 2, acid = 3, frost = 4, ring = 10, fill = 11, lane = 12, wave = 13 }

final class MetalEffects {
    let level: Level
    let gpu: GPUParticles
    let decals: Decals
    let ribbons = Ribbons()
    /// The old pools' emit() for callers outside the effects (WorldLevel): additive / alpha.
    var pa: ParticlePool { gpu.additivePool }
    var pn: ParticlePool { gpu.alphaPool }
    /// Emission scale (web fxK: low 0.4, med 0.7, high 1).
    private(set) var fxK: Float = 0.7
    private var rng = SeededRNG(seed: 9001)

    /// Where bug deaths leave their bodies (Swarm/Corpses.swift; MetalWorld sets it).
    weak var corpses: Corpses?
    /// The swarm, for hits on the chitin (WorldSwarm.impactPoint); nil until MetalWorld sets it (handoff): the core's
    /// bug heights stand in.
    weak var swarm: WorldSwarm?
    /// The squad, for muzzle / eject sockets and bores (WorldSquad.muzzle / socket / bore); nil until MetalWorld sets it
    /// (handoff): the core's muzzle point at the weapon's height stands in.
    weak var squad: WorldSquad?

    /// Floor light pools of the web renderer (LightGrid turns bright ones into lights): empty — the effects emit their
    /// lights into the grid themselves (LightingHub.emit).
    private(set) var glowSprites: [SpriteInstance] = []
    private var floorAdd: [FloorFx] = []
    private var floorMax: [FloorFx] = []
    private var heat: [HeatInstance] = []

    // light pool (LightGrid reads it): [0] follows flames / napalm / the player's muzzle, [1], [2] unused
    struct PointLight { var pos: F3; var color: F3; var intensity: Float }
    private(set) var lights = [PointLight](repeating: PointLight(pos: F3(0, -60, 0), color: F3(1, 0.54, 0.23), intensity: 0), count: 3)
    /// Short grid lights (muzzle pops, kills, blasts …), re-emitted every frame with their fall-off.
    private struct FlashLight { var pos: F3; var color: F3; var peak: Float; var t: Float; var dur: Float; var range: Float; var priority: Float }
    private var flashLights: [FlashLight] = []
    /// Timed floor fx (shock rings, acid glow, ground fire …) and heat sprites.
    private struct TimedFloor { var fx: FloorFx; var t: Float; var life: Float; var fade: Bool }
    private var timedFloor: [TimedFloor] = []
    private struct TimedHeat { var h: HeatInstance; var t: Float; var life: Float }
    private var timedHeat: [TimedHeat] = []
    /// Live explosions (cap counter): age.
    private var blasts: [Float] = []
    private var blastsPeak = 0
    private var blastsReduced = 0
    /// Flame spawns of the last frames (the GPU's flame count is three frames old).
    private var flameSpawns = [Int](repeating: 0, count: 4)
    private var flameSlot = 0
    private var flameThrottled = 0
    // per-marine emission accumulators (fractional rates), shot counters
    private var acc = [[Float]](repeating: [Float](repeating: 0, count: 6), count: 4)
    private var shots = [Int](repeating: 0, count: 4)
    private var scorchT = [Float](repeating: 0, count: 4)
    private var napalmAcc: [Float] = [0, 0, 0, 0, 0, 0, 0, 0]
    private var steamT: Float = 0
    private var burnAcc: Float = 0
    /// Effect clock (s): advances with the effects' dt (frozen look-dev shots stop it).
    private(set) var clock: Float = 0
    private var frameTime: Float = 0
    private var lastDt: Float = 0
    private var liftRiseNow: Float = 0
    private var extractAcc: [Float] = [0, 0]
    private let look = FXLookDev()

    private var renderer: MetalRenderer?
    private var psFloor: MTLRenderPipelineState?
    private var psTele: MTLRenderPipelineState?
    private var psHeat: MTLRenderPipelineState?
    private var rFloor = Region(), rTele = Region(), rHeat = Region()
    private var cpuAcc: Double = 0
    private var cpuFrames = 0
    private var lastLog: Double = 0

    static let pipelines: [PipelineSpec] = GPUParticles.pipelines + Decals.pipelines + Ribbons.pipelines + [
        .world("floorFx", "vs_floorfx", "fs_floorfx", .add),
        .world("telegraph", "vs_floorfx", "fs_telegraph", .max),
        // heat offsets around 0.5, signed through the alpha blend (the ¼-res RG8 target of WP1)
        PipelineSpec(label: "heat", vertex: "vs_heat", fragment: "fs_heat", blend: .alpha, layout: nil, target: .distortion, required: false),
    ]

    /// Explosions alive at once per tier (more: the newest are drawn without fireball and licks).
    static let blastCapHigh = 6, blastCapEfficient = 3

    init(level: Level) {
        self.level = level
        gpu = GPUParticles(level: level)
        decals = Decals(level: level)
        floorAdd.reserveCapacity(64)
        floorMax.reserveCapacity(96)
        heat.reserveCapacity(32)
        flashLights.reserveCapacity(32)
        timedFloor.reserveCapacity(32)
        timedHeat.reserveCapacity(16)
        assert(MemoryLayout<FloorFx>.stride == 64, "FloorFx is 64 bytes in FX.metal")
        assert(MemoryLayout<HeatInstance>.stride == 32, "HeatInstance is 32 bytes in FX.metal")
    }

    /// web fxApplyQuality(): emission scale and the tier's caps (particles, stains; corpses: Corpses.setQuality).
    func setQuality(fxK k: Float) {
        fxK = look.forceHigh ? 1 : k
        if look.forceHigh { renderer?.quality.setChosen(fxK: 1) }
        applyTier()
    }

    private func applyTier() {
        let high = (renderer?.frameTier ?? .efficient) == .high
        gpu.setTier(high: high, fxK: fxK)
        decals.setTier(high: high, fxK: fxK)
    }

    private var blastCap: Int { gpu.ringCap >= GPUParticles.capHigh ? MetalEffects.blastCapHigh : MetalEffects.blastCapEfficient }

    func reset() {
        gpu.clear()
        decals.reset()
        flashLights.removeAll(keepingCapacity: true)
        timedFloor.removeAll(keepingCapacity: true)
        timedHeat.removeAll(keepingCapacity: true)
        blasts.removeAll(keepingCapacity: true)
        for k in 0..<3 { lights[k].intensity = 0 }
        for k in 0..<sightLevel.count { sightLevel[k] = 0 }
        turretSight = 0
        look.restart()
    }

    /// Memory warning: the live particles go (stains and corpses stay; they are part of the battle).
    func trim() { gpu.clear() }

    @inline(__always) private func rnd() -> Float { rng.next() }
    @inline(__always) private func rr(_ a: Float, _ b: Float) -> Float { a + (b - a) * rng.next() }
    @inline(__always) private func num(_ base: Float) -> Int { Int((base * fxK).rounded(.up)) }
    /// Emission count by a rate (per s) over dt with a fractional carry.
    @inline(__always) private func rate(_ a: inout Float, _ perSecond: Float, _ dt: Float) -> Int {
        a += perSecond * fxK * dt
        let n = Int(a)
        a -= Float(n)
        return n
    }

    private func gy(_ x: Float, _ z: Float) -> Float { level.groundY(x, z) }

    // ================================================================ lights / floor / heat
    /// A short grid light: `peak` like a three.js PointLight intensity, falling off (1 − t)² over `dur`.
    func flash(_ p: F3, _ color: F3, peak: Float, dur: Float, range: Float, priority: Float = 10) {
        if flashLights.count >= 24 {
            var worst = 0
            for k in 1..<flashLights.count where flashLights[k].t / flashLights[k].dur > flashLights[worst].t / flashLights[worst].dur { worst = k }
            flashLights[worst] = FlashLight(pos: p, color: color, peak: peak, t: 0, dur: dur, range: range, priority: priority)
            return
        }
        flashLights.append(FlashLight(pos: p, color: color, peak: peak, t: 0, dur: dur, range: range, priority: priority))
    }

    private func floorTimed(_ x: Float, _ z: Float, radius: Float, mode: FloorMode, color: F3, life: Float, thickness: Float = 0.08,
                            fade: Bool = true) {
        if timedFloor.count >= 40 { timedFloor.removeFirst() }
        let f = FloorFx(center: F4(x, gy(x, z) + 0.05, z, radius), color: F4(color.x, color.y, color.z, 1),
                        params: F4(mode.rawValue, 0, thickness, rnd()), axis: .zero)
        timedFloor.append(TimedFloor(fx: f, t: 0, life: life, fade: fade))
    }

    private func heatTimed(_ p: F3, radius: Float, strength: Float, mode: Float, life: Float) {
        if timedHeat.count >= 24 { timedHeat.removeFirst() }
        timedHeat.append(TimedHeat(h: HeatInstance(pos: F4(p.x, p.y, p.z, radius), params: F4(strength, mode, 0, rnd())), t: 0, life: life))
    }

    @inline(__always) private func heatNow(_ p: F3, radius: Float, strength: Float, mode: Float = 0) {
        if heat.count < 32 { heat.append(HeatInstance(pos: F4(p.x, p.y, p.z, radius), params: F4(strength, mode, 0.5, rnd()))) }
    }

    @inline(__always) private func floorNow(_ x: Float, _ y: Float, _ z: Float, radius: Float, mode: FloorMode, color: F3,
                                            seed: Float = 0) {
        if floorAdd.count < 64 {
            floorAdd.append(FloorFx(center: F4(x, y, z, radius), color: F4(color.x, color.y, color.z, 1), params: F4(mode.rawValue, 0.5, 0.1, seed),
                                    axis: .zero))
        }
    }

    /// The flame budget: how many of `n` new flame particles fit under the tier's cap (the GPU's count is three frames
    /// old: the spawns since then count too).
    private func flameBudget(_ n: Int) -> Int {
        let est = gpu.liveFlames + flameSpawns.reduce(0, +)
        let room = max(0, gpu.flameCap - est)
        let k = min(n, room)
        if k < n { flameThrottled += n - k }
        flameSpawns[flameSlot] += k
        return k
    }

    // ================================================================ events
    func handle(_ e: GameEvent, game: Game) {
        switch e {
        case .bugKilled(let type, let pos, let frozen, _, let heading, let scale, let height):
            bugDeath(type, pos.x, pos.y, frozen, heading, scale, height)
        case .bulletHit(let pos, let dir, let killed):
            bulletHit(game, pos.x, pos.y, dir.x, dir.y, killed)
        case .muzzle(let k):
            if k >= 0 && k < game.marines.count { muzzleShot(game.marines[k], k) }
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
            let p = F3(pos.x + ax * 0.75, gy(pos.x, pos.y) + 1.05, pos.y + az * 0.75)
            gpu.burst(.spark, 2, at: p, vel: F3(ax, 0, az) * 8, velJitter: F3(2, 1.2, 2), life: (0.05, 0.12), size: (0.03, 0.02),
                      color: F4(1.0, 1.2, 0.8, 1), gravity: 2, drag: 4)
            flash(p, F3(0.5, 1.0, 0.55), peak: 35, dur: 0.06, range: 5, priority: 5)
        case .bugFrozen(let pos):
            let p = F3(pos.x, gy(pos.x, pos.y) + 0.45, pos.y)
            gpu.burst(.ice, num(5), at: p, jitter: F3(0.25, 0.15, 0.25), sphere: 1.6, upper: true, life: (0.4, 0.8), size: (0.07, 0.03),
                      color: F4(0.75, 1.0, 1.4, 1), gravity: 2, drag: 2)
        case .beaconCompleted(let k):
            if k >= 0 && k < game.beacons.count {
                let b = game.beacons[k]
                let y = gy(b.x, b.z)
                flash(F3(b.x, y + 3, b.z), F3(0.25, 1.0, 0.88), peak: 260, dur: 1.0, range: 14, priority: 30)
                floorTimed(b.x, b.z, radius: 9, mode: .shock, color: F3(0.5, 2.4, 2.0), life: 0.8, thickness: 0.05)
                gpu.burst(.glow, num(30), at: F3(b.x, y + 0.4, b.z), ring: 1.2, vel: F3(0, 3, 0), velJitter: F3(0.4, 1.5, 0.4),
                          radial: 1.5, life: (0.8, 1.4), size: (0.22, 0.05), color: F4(0.4, 2.2, 1.8, 1), gravity: -0.5, drag: 0.8)
            }
        case .turretExpired(let pos):
            turretDrop(pos.x, pos.y)
        default:
            break
        }
    }

    // ---------------------------------------------------------------- bugs
    /// Ichor (albedo of the droplets) and the stain tint of each bug type.
    private static func ichor(_ t: Int) -> F3 { WorldSwarm.ichor[max(0, min(3, t))] }
    private static let chitin = F4(0.045, 0.04, 0.05, 1)

    private func bugDeath(_ type: BugType, _ x: Float, _ z: Float, _ frozen: Bool, _ hd: Float, _ sc: Float, _ y: Float) {
        let ty = type.rawValue
        let s = sc * WorldSwarm.sizeK[ty]
        let p = F3(x, gy(x, z) + max(-0.5, y) + 0.3 * s, z)
        if frozen {
            // the frozen bug shatters (no body): ice shards and chunks, a puff of frost, rime on the deck
            gpu.burst(.ice, num(16), at: p, jitter: F3(0.2, 0.15, 0.2) * s, sphere: 6, upper: true, life: (0.5, 1.0), size: (0.1, 0.05),
                      color: F4(0.8, 1.05, 1.4, 1), gravity: 12, drag: 0.6, bounce: 0.3)
            gpu.burst(.debris, num(6), at: p, sphere: 4.5, upper: true, life: (0.8, 1.4), size: (0.14 * s, 0.1 * s),
                      color: F4(0.5, 0.62, 0.75, 1), gravity: 13, drag: 0.3, spin: 8)
            gpu.burst(.steam, 2, at: p, jitter: F3(0.2, 0.1, 0.2), vel: F3(0, 0.6, 0), life: (0.7, 1.1), size: (0.5 * s, 1.4 * s),
                      color: F4(0.6, 0.72, 0.85, 0.45), drag: 1.2)
            decals.add(x, z, size: s * 0.9, cell: .frost, kind: .frost, tint: F3(0.72, 0.84, 0.98), opacity: 0.85)
            return
        }
        let ich = MetalEffects.ichor(ty)
        let big = type == .brute
        // ichor spray, chitin gibs, the pores' pink-white flecks, a wet puff
        gpu.burst(.ichor, num(big ? 16 : 7), at: p, jitter: F3(0.15, 0.1, 0.15) * s, vel: F3(0, 1.2, 0), sphere: big ? 5.5 : 4.2,
                  upper: true, life: (0.5, 0.9), size: (big ? 0.12 : 0.08, big ? 0.09 : 0.06), color: F4(ich.x * 0.55, ich.y * 0.55, ich.z * 0.55, 1),
                  gravity: 12)
        gpu.burst(.debris, num(big ? 10 : 3), at: p, sphere: 5, upper: true, life: (0.9, 1.6), size: (0.1 * s, 0.08 * s),
                  color: MetalEffects.chitin, gravity: 14, drag: 0.25, spin: 9)
        gpu.burst(.ember, num(big ? 10 : 4), at: p, sphere: 2.6, upper: true, life: (0.45, 0.9), size: (0.045, 0.02),
                  color: F4(2.4, 0.75, 1.45, 1), gravity: 4, drag: 1.5)
        gpu.burst(.steam, 1, at: p, vel: F3(0, 0.5, 0), life: (0.45, 0.7), size: (0.45 * s, 1.2 * s),
                  color: F4(ich.x * 0.35 + 0.08, ich.y * 0.35 + 0.06, ich.z * 0.35 + 0.07, 0.4), drag: 1.5)
        decals.add(x, z, size: s * rr(1.0, 1.45), cell: rnd() < 0.5 ? .splat : .streak, kind: .ichor, tint: ich, flecks: 1)
        if type != .boomer {
            corpses?.add(x, z, hd, sc, type, rnd: { [unowned self] in self.rnd() })
        } else {
            decals.add(x, z, size: 2.6, cell: .acid, kind: .acid, tint: F3(0.42, 0.6, 0.06))
        }
        if big { flash(p, F3(1.0, 0.35, 0.55), peak: 40, dur: 0.15, range: 5, priority: 8) }
    }

    /// One projectile hit at (x, z) along (dx, dz): sparks off the chitin, a hit flash, the bug's ichor, a wet splat.
    private func bulletHit(_ game: Game, _ x: Float, _ z: Float, _ dx: Float, _ dz: Float, _ killed: Bool) {
        if !killed && rnd() > 0.5 * fxK + 0.4 { return }
        var p = F3(x, gy(x, z) + 0.45, z)
        var n = F3(-dx, 0.35, -dz)
        var ich = MetalEffects.ichor(0)
        if let h = swarm?.impactPoint(x: x, z: z, dx: dx, dz: dz) {
            p = h.pos; n = h.normal; ich = h.ichor
        } else {
            // the bug the shot hit (core heights and scales): the hit point on its body, facing the shooter
            let B = game.bugs
            let hit = game.raycastBugs(origin: Vec2(x - dx * 0.9, z - dz * 0.9), dir: Vec2(dx, dz), maxDistance: 1.8)
            if hit.bug >= 0 && hit.bug < B.count {
                let t = Int(B.types[hit.bug])
                let s = B.scales[hit.bug] * WorldSwarm.sizeK[max(0, min(3, t))]
                p.y = gy(x, z) + max(-0.5, B.heights[hit.bug]) + (t == 2 ? 0.55 : 0.32) * s
                ich = MetalEffects.ichor(t)
            }
        }
        let l = max(1e-4, (n * n).sum().squareRoot())
        n /= l
        let d = F3(dx, 0, dz)
        // hot sparks off the chitin (bounce on the deck, cool white → orange), a four-ray hit flash
        gpu.burst(.spark, num(killed ? 9 : 5), at: p, vel: n * 4.5 + d * 1.5, velJitter: F3(2.4, 2.0, 2.4), sphere: 2.5,
                  life: (0.18, 0.45), size: (0.045, 0.03), color: F4(1.25, 1.05, 0.85, 1), gravity: 14, drag: 1.2)
        gpu.burst(.flash, 1, at: p + n * 0.08, life: (0.06, 0.08), size: (killed ? 0.8 : 0.55, killed ? 0.95 : 0.7),
                  color: F4(5.0, 3.6, 2.2, 1), sizeJitter: 0.2)
        // the bug's ichor: droplets along the shot that stick to the deck
        gpu.burst(.ichor, num(killed ? 6 : 3), at: p, vel: d * 2.4 + F3(0, 1.4, 0), velJitter: F3(1.6, 1.2, 1.6), life: (0.5, 0.9),
                  size: (0.07, 0.05), color: F4(ich.x * 0.55, ich.y * 0.55, ich.z * 0.55, 1), gravity: 12)
        if killed || rnd() < 0.18 {
            decals.add(x + dx * 0.5, z + dz * 0.5, size: rr(0.45, 0.8), cell: .small, kind: .ichor, tint: ich, opacity: 0.9, flecks: 0.6,
                       roll: atan2f(dx, dz))
        }
        if killed { flash(p, F3(1.0, 0.7, 0.45), peak: 22, dur: 0.07, range: 4, priority: 4) }
    }

    @inline(__always) func burningBug(_ x: Float, _ z: Float, _ sc: Float, dt: Float) {
        // one bug on fire (WorldSwarm): a lick of flame and an ember now and then
        if rnd() < 7 * dt * fxK {
            let p = F3(x + rr(-0.2, 0.2), gy(x, z) + 0.3 * sc, z + rr(-0.2, 0.2))
            if flameBudget(1) > 0 {
                gpu.burst(.fire, 1, at: p, vel: F3(0, 1.4, 0), velJitter: F3(0.3, 0.3, 0.3), life: (0.3, 0.45), size: (0.25 * sc, 0.6 * sc),
                          color: F4(1, 0.9, 0.8, 0.8), gravity: -1, drag: 1, spin: 2)
            }
            gpu.burst(.ember, 1, at: p, vel: F3(0, 1.6, 0), velJitter: F3(0.8, 0.6, 0.8), life: (0.6, 1.0), size: (0.04, 0.02),
                      color: F4(2.2, 0.7, 0.15, 1), gravity: 1, drag: 1)
        }
    }

    // ---------------------------------------------------------------- weapons
    /// Marine pose the effects attach to (interpolated feet).
    struct MarinePose { var x: Float, y: Float, z: Float }
    private var poses: [MarinePose] = []

    /// The muzzle of marine k (WorldSquad's socket when wired, else the core's muzzle point at the weapon's height).
    private func muzzle(_ m: Marine, _ k: Int) -> F3 {
        if let s = squad?.muzzle(k) { return s }
        let p = k < poses.count ? poses[k] : MarinePose(x: m.x, y: gy(m.x, m.z), z: m.z)
        return F3(p.x + m.ax * 0.95 + m.az * 0.22, p.y + 1.2, p.z + m.az * 0.95 - m.ax * 0.22)
    }

    /// One round fired (rifle / rotary): the muzzle pops a light, throws sparks and a casing; every third a wisp of smoke.
    private func muzzleShot(_ m: Marine, _ k: Int) {
        guard k < shots.count, !m.downed else { return }
        shots[k] &+= 1
        let o = muzzle(m, k)
        let d = F3(m.ax, 0, m.az)
        let rotary = m.cls == .gunner
        // the pop of light on the shooter and the deck (on top of the squad's continuous muzzle lights of LightGrid)
        let c = rotary ? F3(1.0, 0.78, 0.42) : F3(1.0, 0.5, 0.3)
        flash(o + d * 0.35, c, peak: m.isPlayer ? 60 : 38, dur: rotary ? 0.05 : 0.07, range: 7, priority: m.isPlayer ? 9 : 6)
        gpu.burst(.spark, rotary ? 1 : 2, at: o + d * 0.15, vel: d * 9, velJitter: F3(2.6, 1.6, 2.6), life: (0.05, 0.13), size: (0.03, 0.02),
                  color: F4(1.3, 1.0, 0.7, 1), gravity: 2, drag: 4)
        // spent casings to the right of the weapon (rotary: every other round)
        if !rotary || shots[k] % 2 == 0 {
            var e = F3(o.x - m.ax * 0.55 + m.az * 0.12, o.y - 0.06, o.z - m.az * 0.55 - m.ax * 0.12)
            if let s = squad?.socket(k, "eject") { e = s }
            let side = F3(m.az, 0, -m.ax)
            gpu.burst(.casing, 1, at: e, vel: side * rr(1.8, 2.8) + F3(0, 2.6, 0) - d * 0.4, velJitter: F3(0.5, 0.6, 0.5),
                      life: (1.0, 1.5), size: (0.055, 0.055), color: F4(0.62, 0.42, 0.13, 1), gravity: 13, drag: 0.4, sizeJitter: 0.1, spin: 14)
        }
        if shots[k] % 3 == 0 {
            gpu.burst(.smoke, 1, at: o + d * 0.3, vel: d * 0.8 + F3(0, 0.6, 0), velJitter: F3(0.2, 0.2, 0.2), life: (0.5, 0.8),
                      size: (0.25, 0.75), color: F4(0.45, 0.45, 0.47, 0.32), drag: 2, spin: 1)
        }
    }

    /// The flamer's jet from `o` along (ax, az) this frame: flipbook flames, a hot core at the nozzle, lit smoke off the
    /// tips, embers, scorch on the deck, heat haze, the ground glow.
    private func flameJet(_ o: F3, ax: Float, az: Float, vel: F3, dt: Float, k: Int) {
        let d = F3(ax, 0, az)
        let n = flameBudget(rate(&acc[k][0], 130, dt))
        if n > 0 {
            gpu.burst(.fire, n, at: o + d * 0.25, jitter: F3(0.05, 0.05, 0.05), vel: d * 13.5 + vel * 0.5 + F3(0, 0.3, 0),
                      velJitter: F3(2.1, 0.8, 2.1), life: (0.42, 0.58), size: (0.22, 1.75), color: F4(1, 0.95, 0.9, 0.78),
                      gravity: -1.2, drag: 1.6, sizeJitter: 0.3, spin: 2)
        }
        gpu.burst(.glow, 1, at: o + d * 0.35, life: (0.05, 0.07), size: (0.45, 0.7), color: F4(2.6, 1.4, 0.55, 1))
        let ns = rate(&acc[k][1], 14, dt)
        if ns > 0 {
            gpu.burst(.smoke, ns, at: o + d * rr(4.5, 6.5) + F3(0, 0.3, 0), jitter: F3(0.4, 0.2, 0.4), vel: d * 2 + F3(0, 1.4, 0),
                      life: (1.2, 1.8), size: (0.8, 2.3), color: F4(0.06, 0.055, 0.05, 0.7), gravity: -0.6, drag: 0.8, spin: 0.5)
        }
        let ne = rate(&acc[k][2], 26, dt)
        if ne > 0 {
            gpu.burst(.ember, ne, at: o + d * rr(1, 6), vel: d * 5 + F3(0, 1.5, 0), velJitter: F3(2, 1.5, 2), life: (0.6, 1.2),
                      size: (0.05, 0.025), color: F4(2.1, 0.7, 0.15, 1), gravity: 2, drag: 1.2)
        }
        scorchT[k] -= dt
        if scorchT[k] <= 0 {
            scorchT[k] = 0.3
            let t = rr(4.5, 6.8)
            decals.add(o.x + ax * t, o.z + az * t, size: rr(1.3, 2.0), cell: .scorch, kind: .scorch, tint: F3(0.25, 0.22, 0.2), opacity: 0.45,
                       flecks: 0)
        }
        for t: Float in [2.2, 4.4] { heatNow(o + d * t + F3(0, 0.2, 0), radius: 0.8 + t * 0.12, strength: 0.3, mode: 2) }
        let f = 0.2 + 0.06 * rnd()
        floorNow(o.x + ax * 3.6, gy(o.x + ax * 3.6, o.z + az * 3.6) + 0.05, o.z + az * 3.6, radius: 3.4, mode: .fire,
                 color: F3(1.4, 0.55, 0.12) * f, seed: Float(k))
    }

    /// The cryo beam from `o` over `len`: the ribbon, ice glints along it, frost mist and rime where it ends.
    private func cryoStream(_ o: F3, ax: Float, az: Float, len: Float, dt: Float, k: Int) {
        let d = F3(ax, 0, az)
        ribbons.cryoBeam(from: o, ax: ax, az: az, len: len, time: frameTime, seed: Float(k) * 1.7)
        let ni = rate(&acc[k][3], 55, dt)
        if ni > 0 {
            let t = rr(0.5, len)
            gpu.burst(.ice, ni, at: o + d * t - F3(0, t * t / max(len, 1) * 0.55, 0), jitter: F3(0.15, 0.1, 0.15), velJitter: F3(1, 0.8, 1),
                      life: (0.3, 0.6), size: (0.06, 0.03), color: F4(0.7, 1.0, 1.45, 1), gravity: 3, drag: 2)
        }
        let end = F3(o.x + ax * len, gy(o.x + ax * len, o.z + az * len) + 0.3, o.z + az * len)
        let nm = rate(&acc[k][4], 12, dt)
        if nm > 0 {
            gpu.burst(.steam, nm, at: end, jitter: F3(0.4, 0.1, 0.4), vel: F3(0, 0.5, 0), velJitter: F3(0.5, 0.3, 0.5), life: (0.8, 1.3),
                      size: (0.6, 1.7), color: F4(0.3, 0.42, 0.55, 0.3), drag: 1, spin: 0.6)
        }
        // frost vapour shed along the beam
        let nv = rate(&acc[k][5], 10, dt)
        if nv > 0 {
            let t = rr(0.8, len)
            gpu.burst(.steam, nv, at: o + d * t - F3(0, 0.3, 0), jitter: F3(0.2, 0.1, 0.2), vel: F3(0, 0.3, 0), velJitter: F3(0.3, 0.2, 0.3),
                      life: (0.5, 0.9), size: (0.35, 0.9), color: F4(0.25, 0.38, 0.5, 0.25), drag: 1.5, spin: 0.6)
        }
        scorchT[k] -= dt
        if scorchT[k] <= 0 {
            scorchT[k] = 0.35
            decals.add(end.x, end.z, size: rr(1.0, 1.6), cell: .frost, kind: .frost, tint: F3(0.8, 0.9, 1.0), opacity: 0.7)
        }
    }

    // ---------------------------------------------------------------- blasts
    private func explosion(_ x: Float, _ z: Float, _ r: Float, _ kind: ExplosionKind) {
        let g = gy(x, z)
        let p = F3(x, g + 0.6, z)
        switch kind {
        case .pulse:
            // the lift pulse: a teal shock ring, a ring of motes
            floorTimed(x, z, radius: r * 1.05, mode: .shock, color: F3(0.4, 2.6, 2.2), life: 0.5, thickness: 0.05)
            gpu.burst(.glow, num(60), at: F3(x, g + 0.3, z), ring: r * 0.95, vel: F3(0, 2.5, 0), velJitter: F3(0.5, 1.5, 0.5),
                      radial: 2, life: (0.25, 0.5), size: (0.3, 0.06), color: F4(0.4, 2.0, 1.8, 1), gravity: 4, drag: 1)
            flash(F3(x, g + 3, z), F3(0.25, 1.0, 0.88), peak: 260, dur: 0.4, range: r * 2.2, priority: 30)
            return
        case .frost:
            gpu.burst(.ice, num(24), at: p, sphere: 7, upper: true, life: (0.4, 0.9), size: (0.1, 0.04), color: F4(0.8, 1.05, 1.45, 1),
                      gravity: 10, drag: 0.8)
            gpu.burst(.steam, num(4), at: p, jitter: F3(0.4, 0.2, 0.4), radial: 1.5, life: (0.8, 1.3), size: (0.7, 2.0),
                      color: F4(0.6, 0.72, 0.85, 0.4), drag: 1.2)
            floorTimed(x, z, radius: r * 0.9, mode: .frost, color: F3(0.5, 1.3, 2.2), life: 0.45, thickness: 0.1)
            decals.add(x, z, size: r * 0.8, cell: .frost, kind: .frost, tint: F3(0.75, 0.86, 0.98), opacity: 0.8)
            return
        default:
            break
        }
        let big = kind.isBig
        let boomer = kind == .boomer
        // the cap counts explosions drawn in full (fireball and licks); the rest are drawn without them
        let full = blasts.count < blastCap
        if full { blasts.append(0) } else { blastsReduced += 1 }
        blastsPeak = max(blastsPeak, blasts.count)
        // light and the white-hot core
        flash(p + F3(0, 1.2, 0), boomer ? F3(1.0, 0.75, 0.3) : F3(1.0, 0.6, 0.3), peak: big ? 520 : 170, dur: big ? 0.55 : 0.3,
              range: r * 3.2, priority: 30)
        gpu.burst(.flash, 1, at: p + F3(0, 0.3, 0), life: (0.1, 0.12), size: (big ? 4.4 : 2.2, big ? 5.2 : 2.6), color: F4(8, 6, 4, 1), sizeJitter: 0)
        gpu.burst(.glow, 1, at: p, life: (0.16, 0.2), size: (r * 1.1, r * 1.6), color: F4(5, 2.8, 1.2, 1), sizeJitter: 0)
        if full {
            // the fireball and the licks of flame flung out of it
            let fb = flameBudget(big ? 7 : 3)
            if fb > 0 {
                gpu.burst(.blast, fb, at: p, jitter: F3(0.4, 0.25, 0.4), vel: F3(0, 1.4, 0), velJitter: F3(0.6, 0.5, 0.6),
                          radial: 1.3 * r.squareRoot(), life: (0.7, 1.0), size: (r * 0.55, r * 0.95),
                          color: boomer ? F4(1.0, 1.08, 0.62, 1) : F4(1, 1, 1, 1), gravity: -1, drag: 2.2, spin: 0.6)
            }
            let nl = flameBudget(num(big ? 12 : 5))
            if nl > 0 {
                gpu.burst(.fire, nl, at: p, vel: F3(0, 2, 0), velJitter: F3(1, 1.5, 1), radial: r * 2.2, radialJitter: 0.5, life: (0.35, 0.55),
                          size: (0.5, 1.3), color: F4(1, 1, 1, 0.9), gravity: -2, drag: 3.2, spin: 2)
            }
        }
        // sparks fanning out, embers drifting, gibs, then dark smoke
        gpu.burst(.spark, num(big ? (full ? 70 : 35) : 24), at: p + F3(0, 0.3, 0), sphere: big ? 17 : 11, upper: true, life: (0.45, 1.1),
                  size: (0.05, 0.035), color: F4(1.3, 1.1, 0.9, 1), gravity: 13, drag: 0.7)
        gpu.burst(.ember, num(big ? 26 : 8), at: p, delay: 0.1, sphere: 5, upper: true, life: (1.4, 2.6), size: (0.06, 0.03),
                  color: F4(2.2, 0.75, 0.16, 1), gravity: 1.2, drag: 1.4)
        gpu.burst(.debris, num(big ? 14 : 4), at: p, sphere: 9, upper: true, life: (1.2, 2.0), size: (0.12, 0.1),
                  color: boomer ? F4(0.2, 0.14, 0.04, 1) : F4(0.05, 0.045, 0.05, 1), gravity: 14, drag: 0.3, spin: 8)
        gpu.burst(.smoke, num(big ? 9 : 3), at: p + F3(0, 0.6, 0), jitter: F3(r * 0.4, 0.3, r * 0.4), delay: 0.18, vel: F3(0, 1.3, 0),
                  radial: 0.8, life: (2.0, 3.2), size: (r * 0.4, r * 1.15), color: F4(0.035, 0.032, 0.03, 0.9), gravity: -0.5, drag: 0.9,
                  spin: 0.4)
        // the deck: a shock ring, heat waves, a scorch with cooling embers
        floorTimed(x, z, radius: r * 1.7, mode: .shock, color: boomer ? F3(2.4, 2.6, 0.9) : F3(3.2, 2.0, 1.0), life: big ? 0.38 : 0.26,
                   thickness: 0.07)
        heatTimed(p, radius: r * 2.0, strength: 0.7, mode: 1, life: 0.4)
        heatTimed(p + F3(0, 0.6, 0), radius: r * 0.8, strength: 0.35, mode: 0, life: 1.0)
        decals.add(x, z, size: r * (big ? 1.15 : 0.85), cell: .scorch, kind: .scorch, tint: F3(0.08, 0.07, 0.07), flecks: 1)
        if boomer {
            gpu.burst(.ichor, num(18), at: p, sphere: 7, upper: true, life: (0.6, 1.0), size: (0.09, 0.06), color: F4(0.25, 0.32, 0.03, 1),
                      gravity: 12)
            decals.add(x, z, size: r * 0.9, cell: .acid, kind: .acid, tint: F3(0.42, 0.6, 0.06))
            floorTimed(x, z, radius: r * 0.8, mode: .acid, color: F3(0.35, 1.2, 0.15) * 0.16, life: 2.5, thickness: 0.1)
        }
    }

    private func acid(_ x: Float, _ z: Float) {
        let p = F3(x, gy(x, z) + 0.15, z)
        gpu.burst(.ichor, num(12), at: p, sphere: 4, upper: true, life: (0.4, 0.8), size: (0.07, 0.05), color: F4(0.28, 0.4, 0.04, 1), gravity: 12)
        gpu.burst(.glow, num(5), at: p, sphere: 2, upper: true, life: (0.3, 0.6), size: (0.15, 0.04), color: F4(0.4, 1.6, 0.2, 1), gravity: 3)
        gpu.burst(.steam, 2, at: p, jitter: F3(0.4, 0.1, 0.4), vel: F3(0, 0.8, 0), life: (1.0, 1.6), size: (0.6, 1.6),
                  color: F4(0.3, 0.45, 0.15, 0.4), drag: 1, spin: 0.5)
        decals.add(x, z, size: rr(1.6, 2.1), cell: .acid, kind: .acid, tint: F3(0.42, 0.6, 0.06))
        floorTimed(x, z, radius: 1.3, mode: .acid, color: F3(0.3, 1.0, 0.12) * 0.2, life: 2.5, thickness: 0.1)
        flash(F3(x, p.y + 0.6, z), F3(0.45, 1.0, 0.2), peak: 30, dur: 0.25, range: 4, priority: 6)
    }

    private func dash(_ m: Marine) {
        let c = linearRGB(m.spec.laser) * 1.6
        let p = F3(m.x, gy(m.x, m.z) + 0.9, m.z)
        gpu.burst(.glow, num(10), at: p, jitter: F3(0.25, 0.45, 0.25), vel: F3(-m.dashX, 0, -m.dashZ) * 3, velJitter: F3(0.6, 0.4, 0.6),
                  life: (0.2, 0.4), size: (0.35, 0.05), color: F4(c.x, c.y, c.z, 1), drag: 3)
        gpu.burst(.steam, num(4), at: F3(m.x, p.y - 0.8, m.z), radial: 1.5, life: (0.5, 0.9), size: (0.4, 1.3),
                  color: F4(0.35, 0.37, 0.4, 0.4), drag: 2)
    }

    private func napalmBurst(_ x: Float, _ z: Float, _ r: Float) {
        let p = F3(x, gy(x, z) + 0.4, z)
        let n = flameBudget(num(40))
        if n > 0 {
            gpu.burst(.fire, n, at: p, ring: r * 0.5, vel: F3(0, 0.6, 0), radial: r * 1.4, radialJitter: 0.4, life: (0.4, 0.8), size: (0.6, 2.0),
                      color: F4(1, 0.95, 0.9, 0.85), gravity: -1.5, drag: 2.4, spin: 2)
        }
        flash(p + F3(0, 1.1, 0), F3(1.0, 0.45, 0.15), peak: 220, dur: 0.6, range: r * 2.6, priority: 25)
        floorTimed(x, z, radius: r * 1.4, mode: .shock, color: F3(2.6, 1.0, 0.25), life: 0.4, thickness: 0.07)
        heatTimed(p, radius: r * 1.5, strength: 0.6, mode: 1, life: 0.45)
        decals.add(x, z, size: r * 1.8, cell: .scorch, kind: .scorch, tint: F3(0.12, 0.08, 0.06), flecks: 1)
    }

    /// A burning napalm field this frame: a ring of flames on its edge, smoke, embers, the ground glow, haze.
    private func napalmField(_ x: Float, _ z: Float, _ r: Float, dt: Float, k: Int) {
        let g = gy(x, z)
        let kk = k % napalmAcc.count
        napalmAcc[kk] += 120 * fxK * dt * (r / 5)
        let n0 = Int(napalmAcc[kk])
        napalmAcc[kk] -= Float(n0)
        let n = flameBudget(n0)
        if n > 0 {
            gpu.burst(.fire, n, at: F3(x, g + 0.15, z), jitter: F3(0.3, 0, 0.3), ring: r * 0.9, vel: F3(0, 1.3, 0), velJitter: F3(0.3, 0.4, 0.3),
                      life: (0.45, 0.75), size: (0.45, 1.35), color: F4(1, 0.95, 0.9, 0.8), gravity: -1.2, drag: 1, spin: 2)
        }
        if rnd() < 7 * fxK * dt {
            gpu.burst(.smoke, 1, at: F3(x, g + 1.2, z), jitter: F3(r * 0.6, 0.3, r * 0.6), vel: F3(0, 1.4, 0), life: (1.6, 2.4), size: (1.2, 3.2),
                      color: F4(0.05, 0.045, 0.04, 0.6), gravity: -0.4, drag: 0.6, spin: 0.3)
        }
        if rnd() < 16 * fxK * dt {
            gpu.burst(.ember, 1, at: F3(x, g + 0.3, z), jitter: F3(r * 0.8, 0.1, r * 0.8), vel: F3(0, 2.2, 0), velJitter: F3(0.8, 0.8, 0.8),
                      life: (0.8, 1.6), size: (0.05, 0.02), color: F4(2.2, 0.7, 0.15, 1), gravity: 0.6, drag: 1)
        }
        floorNow(x, g + 0.05, z, radius: r * 1.2, mode: .fire, color: F3(1.2, 0.42, 0.08) * (0.18 + 0.05 * rnd()), seed: Float(k))
        heatNow(F3(x, g + 0.8, z), radius: r * 0.8, strength: 0.28, mode: 2)
    }

    private func nova(_ x: Float, _ z: Float, _ r: Float) {
        let g = gy(x, z)
        floorTimed(x, z, radius: r * 1.1, mode: .frost, color: F3(0.6, 1.4, 2.4), life: 0.55, thickness: 0.09)
        gpu.burst(.ice, num(60), at: F3(x, g + 0.5, z), ring: r * 0.25, vel: F3(0, 1, 0), velJitter: F3(0.5, 1, 0.5), radial: r * 2.2,
                  life: (0.4, 0.8), size: (0.08, 0.04), color: F4(0.7, 1.0, 1.45, 1), gravity: 4, drag: 1.2)
        gpu.burst(.steam, num(12), at: F3(x, g + 0.3, z), ring: r * 0.7, radial: 2, life: (0.9, 1.5), size: (0.8, 2.2),
                  color: F4(0.6, 0.75, 0.9, 0.35), drag: 1.2, spin: 0.5)
        decals.add(x, z, size: r * 1.5, cell: .frost, kind: .frost, tint: F3(0.75, 0.86, 0.98), opacity: 0.8)
        flash(F3(x, g + 2, z), F3(0.45, 0.8, 1.0), peak: 150, dur: 0.45, range: r * 2.4, priority: 20)
    }

    private func turretDrop(_ x: Float, _ z: Float) {
        let p = F3(x, gy(x, z) + 0.5, z)
        gpu.burst(.spark, num(16), at: p, sphere: 6, upper: true, life: (0.2, 0.5), size: (0.04, 0.03), color: F4(1.1, 1.2, 0.9, 1), gravity: 14,
                  drag: 0.5)
        gpu.burst(.steam, num(6), at: F3(x, p.y - 0.3, z), radial: 1.2, life: (0.8, 1.4), size: (0.5, 1.6), color: F4(0.4, 0.42, 0.45, 0.4),
                  drag: 1.5)
    }

    private func heal(_ m: Marine) {
        let p = F3(m.x, gy(m.x, m.z) + 0.6, m.z)
        gpu.burst(.glow, 18, at: p, jitter: F3(0.5, 0.6, 0.5), vel: F3(0, 1.6, 0), velJitter: F3(0.2, 0.6, 0.2), life: (0.6, 1.0),
                  size: (0.2, 0.05), color: F4(0.4, 1.9, 0.9, 1), gravity: -0.3)
        floorTimed(m.x, m.z, radius: 1.4, mode: .glow, color: F3(0.2, 0.9, 0.45), life: 0.6)
        flash(p + F3(0, 0.8, 0), F3(0.4, 1.0, 0.6), peak: 25, dur: 0.5, range: 4, priority: 5)
    }

    // ================================================================ per frame (renderFx)
    func beginFrame() {
        floorAdd.removeAll(keepingCapacity: true)
        floorMax.removeAll(keepingCapacity: true)
        heat.removeAll(keepingCapacity: true)
        ribbons.begin()
    }

    func update(game: Game, dt dt0: Float, time: Float, poses ps: [MarinePose], focus: F3, liftRise rise: Float) {
        let c0 = FrameTimer.now()
        poses = ps
        frameTime = time
        liftRiseNow = rise
        if look.forceHigh, let r = renderer, r.quality.chosen != .high { r.quality.setChosen(fxK: 1) }
        applyTier()
        let dt = look.dt(dt0)
        lastDt = dt
        clock += dt
        decals.clock = clock
        flameSlot = (flameSlot + 1) % flameSpawns.count
        flameSpawns[flameSlot] = 0
        for k in blasts.indices { blasts[k] += dt }
        blasts.removeAll(where: { $0 > 1.1 })
        look.step(self, game: game, focus: focus, time: time)
        // the weapons' continuous effects
        for (k, m) in game.marines.enumerated() where !m.downed && k < 4 {
            if m.firing && m.cls == .pyro && dt > 0 {
                flameJet(muzzle(m, k), ax: m.ax, az: m.az, vel: F3(m.vx, 0, m.vz), dt: dt, k: k)
            }
            if m.firing && m.cls == .cryo {
                cryoStream(muzzle(m, k), ax: m.ax, az: m.az, len: m.beamLen, dt: dt, k: k)
            }
        }
        if dt > 0 {
            for (k, np) in game.napalms.enumerated() where np.active { napalmField(np.x, np.z, np.r, dt: dt, k: k) }
        }
        if game.stage == .extract && dt > 0 {
            // the platform tears loose: steam pours off the rim, sparks rain into the shaft
            let L = level.lift, ry = L.y + rise
            let ns = rate(&extractAcc[0], 140, dt), nk = rate(&extractAcc[1], 90, dt)
            gpu.burst(.steam, ns, at: F3(L.x, ry + 0.2, L.z), ring: L.r, vel: F3(0, -1.2, 0), velJitter: F3(0.3, 0.7, 0.3), radial: 0.6,
                      life: (1.0, 1.4), size: (0.6, 2.4), color: F4(0.7, 0.75, 0.8, 0.35), noFloor: true)
            gpu.burst(.spark, nk, at: F3(L.x, ry - 0.3, L.z), ring: L.r + 0.6, vel: F3(0, 0.2, 0), velJitter: F3(0.3, 1.2, 0.3),
                      radial: 1.2, life: (0.4, 0.8), size: (0.045, 0.03), color: F4(1.2, 1.0, 0.8, 1), gravity: 12, drag: 0.3, noFloor: true)
        }
        steamT -= dt
        if steamT <= 0 && dt > 0 {
            steamT = 0.12
            for v in level.layout.vents where abs(v.x - focus.x) < 30 && abs(v.y - focus.z) < 30 && rnd() < 0.6 {
                gpu.burst(.steam, 1, at: F3(v.x, gy(v.x, v.y) + 0.2, v.y), jitter: F3(0.4, 0, 0.4), vel: F3(0.4, 1.6, 0),
                          velJitter: F3(0.3, 0.4, 0.3), life: (2, 3), size: (0.6, 3.2), color: F4(0.55, 0.6, 0.65, 0.22), gravity: -0.15,
                          drag: 0.3, spin: 0.3)
            }
        }
        // timed floor fx and heat
        var i = 0
        while i < timedFloor.count {
            timedFloor[i].t += dt
            let e = timedFloor[i]
            if e.t >= e.life { timedFloor.remove(at: i); continue }
            var f = e.fx
            let u = e.t / e.life
            f.params.y = u
            if e.fade && f.params.x != FloorMode.shock.rawValue && f.params.x != FloorMode.frost.rawValue { f.color.w = (1 - u) * (1 - u) }
            floorAdd.append(f)
            i += 1
        }
        i = 0
        while i < timedHeat.count {
            timedHeat[i].t += dt
            let e = timedHeat[i]
            if e.t >= e.life { timedHeat.remove(at: i); continue }
            var h = e.h
            h.params.z = e.t / e.life
            if h.params.y < 0.5 { h.params.x *= 1 - h.params.z }
            heat.append(h)
            i += 1
        }
        decals.liftRise(rise)
        telegraphs(game: game, time: time)
        ribbons.tracers(game: game, level: level)
        sights(game: game, dt: dt, poses: ps)
        beaconBeams(game: game, time: time)
        pointLights(game: game, dt: dt, time: time, poses: ps)
        emitLights(dt: dt)
        cpuAcc += (FrameTimer.now() - c0) * 1000
    }

    // ---------------------------------------------------------------- telegraphs
    private func telegraphs(game: Game, time: Float) {
        let blink = 0.6 + 0.4 * sinf(time * 18)
        for e in game.telegraphs where e.active {
            if floorMax.count >= 96 { break }
            let u = e.progress
            let col = F3(e.r, e.g, e.b) * 1.25
            switch e.shape {
            case .lane:
                let wind = max(0.001, e.wind)
                var inten: Float = e.t < e.wind ? blink * min(1, e.t / wind * 4 + 0.3) * (0.8 + 0.4 * e.t / wind)
                    : 1.25 * (1 - (e.t - e.wind) / max(0.001, e.life - e.wind))
                inten = max(0, inten)
                let cx = e.x + e.dx * e.len / 2, cz = e.z + e.dz * e.len / 2
                let y0 = gy(e.x, e.z), y1 = gy(e.x + e.dx * e.len, e.z + e.dz * e.len)
                floorMax.append(FloorFx(center: F4(cx, (y0 + y1) * 0.5 + 0.06, cz, e.w / 2), color: F4(col.x, col.y, col.z, inten),
                                        params: F4(FloorMode.lane.rawValue, u, 0, 1), axis: F4(e.dx, e.dz, e.len / 2, (y1 - y0) / max(0.01, e.len))))
            case .fill:
                let y = gy(e.x, e.z) + 0.055
                floorMax.append(FloorFx(center: F4(e.x, y, e.z, e.r0), color: F4(col.x, col.y, col.z, 1),
                                        params: F4(FloorMode.fill.rawValue, u, 0, u > 0.75 ? blink : 1), axis: .zero))
            case .ring:
                let y = gy(e.x, e.z) + 0.05
                if e.pulse {
                    let inten = max(0, blink * min(1, u * 4 + 0.3))
                    floorMax.append(FloorFx(center: F4(e.x, y, e.z, e.radius), color: F4(col.x, col.y, col.z, 1),
                                            params: F4(FloorMode.ring.rawValue, u, 0, inten), axis: .zero))
                } else {
                    let rad = e.r0 + (e.r1 - e.r0) * smooth01f(u)
                    floorMax.append(FloorFx(center: F4(e.x, y, e.z, rad), color: F4(col.x, col.y, col.z, max(0, 1 - u)),
                                            params: F4(FloorMode.wave.rawValue, u, 0, 1), axis: .zero))
                }
            }
        }
    }

    // ---------------------------------------------------------------- sights (LAND: no laser lines)
    /// Sight level 0…1 of each marine (fades in while it fires, out after) and of the turret.
    private var sightLevel = [Float](repeating: 0, count: 4)
    private var turretSight: Float = 0
    /// Longest sight glint (m): no long laser line across the screen, only a short fading glint off the muzzle.
    static let sightGlintLength: Float = 1.2
    private static var sightLogged = false

    /// While a marine fires, a short class-coloured glint fades off its muzzle (≤ 1.2 m) and a small dot of the same hue
    /// sits on the bug it aims at; nothing while it does not fire. The turret gets the same in green.
    private func sights(game: Game, dt: Float, poses: [MarinePose]) {
        let B = game.bugs
        let L = MetalEffects.sightGlintLength
        let rdt = dt
        for (k, m) in game.marines.enumerated() where k < poses.count && k < sightLevel.count {
            let want: Float = m.firing && !m.downed ? 1 : 0
            let rt: Float = want > sightLevel[k] ? 14 : 5
            sightLevel[k] += (want - sightLevel[k]) * min(1, rt * rdt)
            if m.downed { sightLevel[k] = 0 }
            let lv = sightLevel[k]
            if lv < 0.02 { continue }
            let o = muzzle(m, k)
            let col = linearRGB(m.spec.laser)
            let e = F3(o.x + m.ax * L, o.y - 0.06, o.z + m.az * L)
            if !MetalEffects.sightLogged && lv > 0.9 {
                MetalEffects.sightLogged = true
                AppLog.info(String(format: "sights: glint %.1f m (no laser line), first on marine %d (%@)", L, k, m.cls.id))
            }
            ribbons.glint(o, e, width: 0.12, color: col, intensity: 0.9 * lv)
            ribbons.glint(o, e, width: 0.03, color: col, intensity: 1.9 * lv)
            if lv > 0.35 {
                let hit = game.raycastBugs(origin: Vec2(o.x, o.z), dir: Vec2(m.ax, m.az), maxDistance: 24)
                if hit.bug >= 0 && hit.bug < B.count {
                    let hx = o.x + m.ax * hit.distance, hz = o.z + m.az * hit.distance
                    let hy = gy(hx, hz) + max(-0.5, B.heights[hit.bug]) + 0.5
                    let c = col * (m.isPlayer ? 2.2 : 1.3) * lv
                    gpu.burst(.dot, 1, at: F3(hx, hy, hz), life: (0.04, 0.04), size: (m.isPlayer ? 1.25 : 0.9, m.isPlayer ? 1.25 : 0.9),
                              color: F4(c.x, c.y, c.z, 1), sizeJitter: 0)
                }
            }
        }
        let T = game.turret
        let tWant: Float = T.active ? 1 : 0
        turretSight += (tWant - turretSight) * min(1, (tWant > turretSight ? 14 : 5) * rdt)
        if T.active && turretSight > 0.02 {
            let ax = sinf(T.angle), az = cosf(T.angle)
            let ox = T.x + ax * 0.75, oz = T.z + az * 0.75
            let ty = gy(T.x, T.z) + 1.05
            let hit = game.raycastBugs(origin: Vec2(ox, oz), dir: Vec2(ax, az), maxDistance: game.turretLaserLength + 0.01)
            let on: Float = hit.bug >= 0 ? 1 : 0.4
            ribbons.glint(F3(ox, ty, oz), F3(ox + ax * L, ty - 0.08, oz + az * L), width: 0.016, color: F3(0.4, 2.2, 0.6),
                          intensity: 1.1 * on * turretSight)
            if hit.bug >= 0 && hit.bug < B.count {
                let hx = ox + ax * hit.distance, hz = oz + az * hit.distance
                let hy = gy(hx, hz) + max(-0.5, B.heights[hit.bug]) + 0.5
                gpu.burst(.dot, 1, at: F3(hx, hy, hz), life: (0.04, 0.04), size: (0.8, 0.8), color: F4(0.25, 1.4, 0.4, 1), sizeJitter: 0)
            }
        }
    }

    // ---------------------------------------------------------------- beacon beams
    private var camRightXZ = F3(1, 0, 0)
    func setCameraRight(_ r: F3) {
        let l = max(1e-4, (r.x * r.x + r.z * r.z).squareRoot())
        camRightXZ = F3(r.x / l, 0, r.z / l)
    }

    private func beaconBeams(game: Game, time: Float) {
        for b in game.beacons where b.state > 0 {
            let col: F3 = b.state == 2 ? F3(0.25, 1.0, 0.85) : F3(1.0, 0.7, 0.15)
            let i: Float = b.state == 2 ? 0.6 : 0.25 + 0.2 * sinf(time * 10)
            ribbons.column(base: F3(b.x, gy(b.x, b.z), b.z), height: 60, width: 0.35, color: col * 2, intensity: i)
        }
    }

    // ---------------------------------------------------------------- lights
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
            l0.pos = F3(n.x, gy(n.x, n.z) + 1.5, n.z)
            l0.color = linearRGB(0xff6a20)
            l0.intensity = 140 * (0.8 + 0.2 * sinf(time * 29))
        } else if let P = game.marines.first, !P.downed, P.muzzle > 0, P.cls == .assault || P.cls == .gunner, !poses.isEmpty {
            // the player's muzzle: a hard pop on each round (the core's muzzle value falls 1 → 0 in 0.1 s)
            let o = muzzle(P, 0)
            l0.pos = F3(o.x + P.ax * 0.4, o.y + 0.1, o.z + P.az * 0.4)
            l0.color = linearRGB(P.cls == .assault ? 0xff6040 : 0xffc060)
            let pop = P.muzzle * P.muzzle
            l0.intensity = 80 * pop * (0.85 + 0.15 * rnd())
        } else if let P = game.marines.first, !P.downed, P.firing, P.cls == .cryo, let p = poses.first {
            l0.pos = F3(p.x + P.ax * P.beamLen * 0.5, p.y + 1.2, p.z + P.az * P.beamLen * 0.5)
            l0.color = linearRGB(0x60c8ff)
            l0.intensity = 60 * (0.85 + 0.15 * sinf(time * 40))
        } else {
            l0.intensity = max(0, l0.intensity - dt * 600)
        }
        lights[0] = l0
    }

    /// The short flash lights into WP2's light grid for this frame.
    private func emitLights(dt: Float) {
        let hub = LightingHub.current
        var i = 0
        while i < flashLights.count {
            flashLights[i].t += dt
            let f = flashLights[i]
            if f.t >= f.dur { flashLights.remove(at: i); continue }
            let u = f.t / f.dur
            hub?.emit(f.pos, color: f.color, intensity: f.peak * (1 - u) * (1 - u), range: f.range, priority: f.priority)
            i += 1
        }
    }

    // ================================================================ drawing (FX.metal)
    /// Live particles (heartbeat `parts`): the GPU's count of three frames ago.
    var particleCount: Int { gpu.liveCount }

    /// Resolve pipelines, register the draw items (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        gpu.attach(r)
        decals.attach(r)
        ribbons.attach(r)
        psFloor = r.pipeline("floorFx")
        psTele = r.pipeline("telegraph")
        psHeat = r.pipeline("heat")
        r.register(.transparent, order: 120, "floor fx") { [unowned self] enc in self.encodeFloor(enc, self.rFloor, self.psFloor) }
        r.register(.transparent, order: 330, "telegraphs") { [unowned self] enc in self.encodeFloor(enc, self.rTele, self.psTele) }
        r.register(.distortion, order: 100, "heat") { [unowned self] enc in self.encodeHeat(enc) }
        look.attach(self, r)
        applyTier()
    }

    /// Upload this frame's stains, floor fx, telegraphs, heat, beams and the particle records. `teamRings`: GroundGlyphs'
    /// (empty since WP4: the HP arcs replace them).
    func upload(_ r: MetalRenderer, teamRings: [SpriteInstance], dt: Float) {
        let c0 = FrameTimer.now()
        decals.upload(r)
        rFloor = r.upload(floorAdd)
        rTele = r.upload(floorMax)
        rHeat = r.upload(heat)
        ribbons.upload(r)
        gpu.upload(r, dt: lastDt, time: frameTime, rise: liftRiseNow)
        cpuAcc += (FrameTimer.now() - c0) * 1000
        cpuFrames += 1
        heartbeat()
    }

    private func encodeFloor(_ enc: MTLRenderCommandEncoder, _ reg: Region, _ ps: MTLRenderPipelineState?) {
        guard let r = renderer, let ps = ps, reg.count > 0 else { return }
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: reg.offset, index: BufferIndex.instances)
        r.drawQuads(enc, reg.count)
    }

    /// Distortion stage (High): the heat sprites into the ¼-res offsets.
    private func encodeHeat(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer, let ps = psHeat, rHeat.count > 0 else { return }
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: rHeat.offset, index: BufferIndex.instances)
        if let n = r.store.noise { enc.setFragmentTexture(n, index: TextureIndex.noise) }
        r.drawQuads(enc, rHeat.count)
    }

    /// Once per second (diagnostics): `hb fx parts=live/ring peak=… fire=…/cap expl=…/cap spawn=…/s rec=…/s decals=…/ring
    /// beams=… tracer=…m lights=… cpu=…ms sim=on|off tier=…`.
    private func heartbeat() {
        guard AppLog.diagnostics else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        let (sp, rec) = gpu.takeRates()
        let (peak, fpeak) = gpu.takeMaxima()
        let (tl, tn) = ribbons.takeTracerStats()
        gpu.calibrate()
        let simMs = gpu.takeSimMs()
        let cpu = cpuFrames > 0 ? cpuAcc / Double(cpuFrames) : 0
        cpuAcc = 0; cpuFrames = 0
        AppLog.info("hb fx parts=\(gpu.liveCount)/\(gpu.ringCap) peak=\(peak) fire=\(gpu.liveFlames)/\(gpu.flameCap) peak=\(fpeak)"
                    + " expl=\(blasts.count)/\(blastCap) peak=\(blastsPeak) reduced=\(blastsReduced) throttled=\(flameThrottled) spawn=\(sp)/s rec=\(rec)/s"
                    + " decals=\(decals.items.count)/\(decals.ring) beams=\(ribbons.beams.count) tracers=\(tn) tracer=" + String(format: "%.1fm", tl)
                    + " lights=\(flashLights.count) floor=\(floorAdd.count)+\(floorMax.count) heat=\(heat.count)"
                    + String(format: " cpu=%.3fms", cpu) + " sim=" + (gpu.simOff ? "off" : "on")
                    + (simMs.map { String(format: " gpusim=%.3fms", $0) } ?? " gpusim=-")
                    + " tier=" + ((renderer?.frameTier ?? .efficient) == .high ? "high" : "efficient") + (look.mode.isEmpty ? "" : " look=" + look.mode))
        blastsPeak = blasts.count
        blastsReduced = 0
        flameThrottled = 0
    }

    // ================================================================ look-dev hooks (FXLookDev)
    fileprivate func lookExplosion(_ x: Float, _ z: Float, _ r: Float, _ kind: ExplosionKind) { explosion(x, z, r, kind) }
    fileprivate func lookAcid(_ x: Float, _ z: Float) { acid(x, z) }
    fileprivate func lookDeath(_ t: BugType, _ x: Float, _ z: Float, frozen: Bool) { bugDeath(t, x, z, frozen, rnd() * TAU, t.spec.scale, 0) }
    fileprivate func lookHit(_ game: Game, _ x: Float, _ z: Float, _ dx: Float, _ dz: Float) { bulletHit(game, x, z, dx, dz, rnd() < 0.3) }
    fileprivate func lookNapalm(_ x: Float, _ z: Float, _ r: Float, burst: Bool, dt: Float) {
        if burst { napalmBurst(x, z, r) } else { napalmField(x, z, r, dt: dt, k: 7) }
    }
    fileprivate func lookFlame(_ o: F3, _ ax: Float, _ az: Float, dt: Float) { flameJet(o, ax: ax, az: az, vel: .zero, dt: dt, k: 3) }
    fileprivate func lookCryo(_ o: F3, _ ax: Float, _ az: Float, len: Float, dt: Float) { cryoStream(o, ax: ax, az: az, len: len, dt: dt, k: 2) }
    fileprivate func lookNova(_ x: Float, _ z: Float, _ r: Float) { nova(x, z, r) }
    fileprivate func lookCryoBeam(_ o: F3, _ ax: Float, _ az: Float, len: Float) {
        ribbons.cryoBeam(from: o, ax: ax, az: az, len: len, time: frameTime, seed: 3.4)
    }
    fileprivate func lookShot(_ o: F3, _ ax: Float, _ az: Float, rotary: Bool, k: Int) {
        // a round without a core marine (look-dev): casing, sparks, light, a tracer from the muzzle
        let d = F3(ax, 0, az)
        flash(o + d * 0.35, rotary ? F3(1.0, 0.78, 0.42) : F3(1.0, 0.5, 0.3), peak: 50, dur: 0.07, range: 7, priority: 8)
        gpu.burst(.spark, 2, at: o + d * 0.15, vel: d * 9, velJitter: F3(2.6, 1.6, 2.6), life: (0.05, 0.13), size: (0.03, 0.02),
                  color: F4(1.3, 1.0, 0.7, 1), gravity: 2, drag: 4)
        let side = F3(az, 0, -ax)
        gpu.burst(.casing, 1, at: o - d * 0.55 + side * 0.12, vel: side * rr(1.8, 2.8) + F3(0, 2.6, 0), velJitter: F3(0.5, 0.6, 0.5),
                  life: (1.0, 1.5), size: (0.055, 0.055), color: F4(0.62, 0.42, 0.13, 1), gravity: 13, drag: 0.4, sizeJitter: 0.1, spin: 14)
    }
    fileprivate var lookDecals: Decals { decals }
}

// ================================================================
//  FX LOOK-DEV — `-fxSheet`: every effect staged around the camera's
//  focus (rows across the screen: frag and boomer blasts, the napalm
//  ring, the flamer jet and the cryo beam; hits, kills, a frozen
//  shatter, acid, a frost nova; a row of every stain kind), frozen
//  `-fxSheetT` s (default 0.35) after the last one fired, so a
//  screenshot catches them mid-air. `-fxPeak`: the plan's scripted
//  peak (three chained boomers 0.25 s apart + a napalm burst and field
//  + the cryo beam), repeated every 2.5 s — device GPU timing of the
//  worst case (`hb gpu`). `-fxHigh`: the High tier for both.
// ================================================================
final class FXLookDev {
    let sheet: Bool
    let peak: Bool
    let forceHigh: Bool
    let freezeAfter: Float
    var mode: String { sheet ? "sheet" : (peak ? "peak" : "") }
    private var start: Double = 0
    private var staged = false
    private var frozen = false
    private var lastPeak: Float = -100
    private var peakStep = -1
    private var focus = F3(0, 0, 0)

    init() {
        let u = LaunchOptions.current.unknown
        sheet = u.contains("-fxSheet")
        peak = u.contains("-fxPeak")
        forceHigh = u.contains("-fxHigh")
        freezeAfter = u.firstIndex(of: "-fxSheetT").flatMap { $0 + 1 < u.count ? Float(u[$0 + 1]) : nil } ?? 0.35
    }

    func attach(_ fx: MetalEffects, _ r: MetalRenderer) {
        if sheet || peak { AppLog.info("fx: look-dev " + mode + (forceHigh ? " (High)" : "")) }
        if forceHigh { r.quality.setChosen(fxK: 1) }
    }

    /// The effects' dt: frozen once the sheet has been staged.
    func dt(_ d: Float) -> Float { frozen ? 0 : d }

    /// The world was reset (the loading cover lifts, a new mission): stage again from the start.
    func restart() {
        start = 0
        staged = false
        frozen = false
        lastPeak = -100
        peakStep = -1
    }

    func step(_ fx: MetalEffects, game: Game, focus f: F3, time: Float) {
        guard sheet || peak else { return }
        if start == 0 { start = FrameTimer.now(); focus = f }
        let t = Float(FrameTimer.now() - start)
        if sheet { stepSheet(fx, game: game, t: t) } else { stepPeak(fx, game: game, t: t) }
    }

    /// World point `a` m to the screen's right and `b` m up the screen (into the view) from the focus.
    private func at(_ a: Float, _ b: Float) -> (Float, Float) {
        // camera yaw 45°: screen right = (1, 0, −1)/√2, into the screen = (−1, 0, −1)/√2
        let k: Float = 0.70710678
        return (focus.x + a * k - b * k, focus.z - a * k - b * k)
    }

    private func stepSheet(_ fx: MetalEffects, game: Game, t: Float) {
        let t0: Float = 1.5
        let s: Float = 0.70710678
        let (fx1, fz1) = at(2.5, 2.4)
        let flameO = F3(fx1, game.level.groundY(fx1, fz1) + 1.2, fz1)
        let (cx, cz) = at(2.5, -0.6)
        let cryoO = F3(cx, game.level.groundY(cx, cz) + 1.2, cz)
        if frozen {
            // the frozen frame keeps the beam (a ribbon, redrawn every frame)
            fx.lookCryoBeam(cryoO, s, -s, len: 7)
            return
        }
        // continuous ones (flamer, cryo, napalm field) run from t0 − 0.6 until the freeze
        if t > t0 - 0.6 {
            let dt: Float = 1.0 / 60
            fx.lookFlame(flameO, s, -s, dt: dt)
            fx.lookCryo(cryoO, s, -s, len: 7, dt: dt)
            let (nx, nz) = at(-7.5, -2.6)
            fx.lookNapalm(nx, nz, 2.2, burst: false, dt: dt)
        }
        guard !staged, t >= t0 else {
            if staged && t >= t0 + freezeAfter { frozen = true; AppLog.info("fx: look-dev sheet frozen") }
            return
        }
        staged = true
        let (ax, az) = at(-7.0, 2.8)
        fx.lookExplosion(ax, az, 4, .frag)
        let (bx, bz) = at(-1.5, 3.6)
        fx.lookExplosion(bx, bz, 3.2, .boomer)
        let (nx, nz) = at(-7.5, -2.6)
        fx.lookNapalm(nx, nz, 2.2, burst: true, dt: 0)
        // hits along a row below the squad
        for (i, a) in [Float(-4.5), -3.0, -1.5].enumerated() {
            let (hx, hz) = at(a, -2.4)
            for _ in 0..<3 { fx.lookHit(game, hx, hz, s * (i % 2 == 0 ? 1 : -1), s) }
        }
        let (rx, rz) = at(0.5, -3.0)
        fx.lookDeath(.runner, rx, rz, frozen: false)
        let (sx, sz) = at(2.6, -3.2)
        fx.lookDeath(.brute, sx, sz, frozen: false)
        let (ix, iz) = at(4.8, -3.0)
        fx.lookDeath(.spitter, ix, iz, frozen: true)
        let (qx, qz) = at(7.0, -3.4)
        fx.lookAcid(qx, qz)
        let (vx, vz) = at(6.5, 4.0)
        fx.lookNova(vx, vz, 2.4)
        // shots: muzzles in a row left of the squad, casings in the air
        for i in 0..<4 {
            let (mx, mz) = at(-4.8 + Float(i) * 0.8, 0.5)
            fx.lookShot(F3(mx, game.level.groundY(mx, mz) + 1.2, mz), s, -s, rotary: i % 2 == 1, k: i)
        }
        // a row of stains of every kind along the bottom
        let D = fx.lookDecals
        let row: [(Decals.Cell, Decals.Kind, F3)] = [(.splat, .ichor, MetalEffectsLook.ichor(0)), (.streak, .ichor, MetalEffectsLook.ichor(1)),
                                                      (.gore, .gore, MetalEffectsLook.ichor(2)), (.acid, .acid, F3(0.42, 0.6, 0.06)),
                                                      (.scorch, .scorch, F3(0.08, 0.07, 0.07)), (.frost, .frost, F3(0.75, 0.86, 0.98))]
        for (i, d) in row.enumerated() {
            let (dx, dz) = at(-8.0 + Float(i) * 3.2, -4.6)
            D.add(dx, dz, size: 2.0, cell: d.0, kind: d.1, tint: d.2, flecks: d.1 == .scorch || d.1 == .ichor ? 1 : 0)
        }
        AppLog.info("fx: look-dev sheet staged")
    }

    private func stepPeak(_ fx: MetalEffects, game: Game, t: Float) {
        let period: Float = 2.5
        let cycle = Int(t / period)
        let ph = t - Float(cycle) * period
        if cycle != peakStep { peakStep = cycle; lastPeak = -1 }
        let dt: Float = 1.0 / 60
        // three chained boomers 0.25 s apart, a napalm burst with its field, the cryo beam over the whole cycle
        for k in 0..<3 {
            let tk = Float(k) * 0.25
            if lastPeak < tk && ph >= tk {
                let (x, z) = at(-3.5 + Float(k) * 3.0, 3.0)
                fx.lookExplosion(x, z, 3.2, .boomer)
            }
        }
        if lastPeak < 0.1 && ph >= 0.1 {
            let (x, z) = at(-2, -3)
            fx.lookNapalm(x, z, 4, burst: true, dt: 0)
        }
        lastPeak = ph
        let (x, z) = at(-2, -3)
        fx.lookNapalm(x, z, 4, burst: false, dt: dt)
        let (cx, cz) = at(3.5, -1.0)
        fx.lookCryo(F3(cx, game.level.groundY(cx, cz) + 1.2, cz), -0.70710678, 0.70710678, len: 10, dt: dt)
    }
}

/// Ichor tints for the look-dev stain row.
private enum MetalEffectsLook {
    static func ichor(_ t: Int) -> F3 { WorldSwarm.ichor[max(0, min(3, t))] }
}
