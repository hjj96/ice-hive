import Foundation
import Metal
import IceHiveCore

// ================================================================
//  WORLD SQUAD (owned by WP4 «Отряд») — the four marines: skinned
//  IHV1 models from the Blender pipeline (tools/blender/characters),
//  one per class, animated on the CPU by MarineRig (8-way locomotion
//  with planted feet, dash, fire / flinch layers, down → crawl →
//  revive → death, hands on the grips by IK) and drawn as one skinned
//  draw each (opaque item 205; shadow casters item 105, so the player's
//  and the squad's flashlights cast their silhouettes). Every frame:
//  the interpolated feet and the smoothed aim of each marine → its rig
//  → a 32-bone palette in the frame arena.
//  The flashlights start at each weapon's torch (`torches`, read by
//  `flashlight`); the poses (feet) feed the effects, lights, rings and
//  the HUD's nameplates.
//  Weapon flashes (transparent item 310, one additive instanced draw):
//  at each firing weapon's muzzle socket two flame planes along the
//  bore (rolled per shot), a camera-facing star and a disc across the
//  bore in the class's flash colour; the flash also lights the shooter
//  (MarineDraw.muzzle: a short-range light on his arms, chest and gun),
//  and barrels / nozzles glow with heat under sustained fire.
//  Look-dev (`-squadSheet`, optional `-closeup` / `-closeupTight`): the
//  squad lined up facing the game camera, each marine cycling through
//  its clips (idle, run, strafe, fire, dash, down, crawl, revive); with
//  -closeup the camera frames them (MetalWorld asks closeUpCamera).
//  `hb squad` (diagnostics, once a second): rig CPU per frame, the worst
//  planted-foot slide over one contact (stride), hand-to-grip error, states.
// ================================================================

/// Per-draw constants of a marine (`struct MarineDraw` in Characters.metal), 96 bytes.
struct MarineDraw {
    /// rgb class hue (linear), w = visor glow multiplier.
    var hue: F4
    /// rgb class paint (linear), w = texture layer (class index).
    var trim: F4
    /// rgb added emissive (hurt / invulnerable), w = downed dimming.
    var flash: F4
    /// x class rim strength, y visor / strip gain, z lamp gain, w = 1 on the High tier.
    var params: F4
    /// xyz the weapon's muzzle (world), w = its flash as a light on the marine (0 = none).
    var muzzle: F4 = .zero
    /// rgb the flash light's colour (linear), w = barrel / nozzle heat 0…1.
    var fx: F4 = .zero
}

/// One weapon flash (`struct FlashInstance` in Characters.metal), 64 bytes.
struct FlashInstance {
    /// xyz the muzzle (world), w = flame length (m).
    var pos: F4
    /// xyz the bore direction (unit, world), w = half width (m).
    var dir: F4
    /// rgb linear HDR flash colour, w = kind (0 rifle, 1 rotary, 2 flamer, 3 cryo).
    var color: F4
    /// x = roll about the bore (rad), y = intensity 0…1, z = seed, w = rays of the star.
    var params: F4
}

final class WorldSquad {
    /// The squad's pipelines (and the ground glyphs'): compiled with the world's behind the loading cover.
    static let pipelines: [PipelineSpec] = [
        .world("marine", "vs_marine", "fs_marine"),
        .depthOnly("marineShadow", "vs_marine_shadow"),
        .world("marineFlash", "vs_muzzle_flash", "fs_muzzle_flash", .add),
    ] + GroundGlyphs.pipelines

    /// Buffer / texture slots of the marine pipelines (Characters.metal MARINE_*).
    enum Slot {
        static let palette = 2
        static let draw = 4
        static let normal = 11
        static let orm = 12
    }

    /// Class paint (sRGB) — the same values the Blender build paints with (tools/blender/characters/marines.py TRIM).
    static let trim: [UInt32] = [0xb8322a, 0xd8901c, 0x3592c8, 0x47a538]

    let level: Level
    /// Interpolated feet of each marine this frame (effects, rings, lights and the HUD attach here).
    private(set) var poses = [MetalEffects.MarinePose](repeating: MetalEffects.MarinePose(x: 0, y: 0, z: 0), count: 4)
    /// The weapon torch of each marine this frame (world; nil before its first frame): the flashlights start there.
    private(set) static var torches = [F3?](repeating: nil, count: 4)
    private var assets = [MarineAsset?](repeating: nil, count: 4)
    private let textures: MarineTextures
    private var rigs = [MarineRig?](repeating: nil, count: 4)
    private var rigCls = [Int](repeating: -1, count: 4)
    private var aimVis: [Float] = [0, 0, 0, 0]
    private var aimInit = false
    private var palettes = [Region](repeating: Region(), count: 4)
    private var draws = [MarineDraw](repeating: MarineDraw(hue: .zero, trim: .zero, flash: .zero, params: .zero), count: 4)
    private var drawn: [Int] = []
    private var renderer: MetalRenderer?
    private var ps: MTLRenderPipelineState?
    private var psShadow: MTLRenderPipelineState?
    private var psFlash: MTLRenderPipelineState?
    // weapon flashes: this frame's instances, and per marine the shot's roll / seed, the last muzzle value, the
    // flash's age and the barrel heat
    private var flashes: [FlashInstance] = []
    private var flashRegion = Region()
    private var shotRoll: [Float] = [0, 0, 0, 0]
    private var shotSeed: [Float] = [0, 0, 0, 0]
    private var prevMuzzle: [Float] = [0, 0, 0, 0]
    private var shotAge: [Float] = [9, 9, 9, 9]
    private var heat: [Float] = [0, 0, 0, 0]
    private var flashRng: UInt32 = 0x9e3779b9
    private var flashCount = 0
    let lookDev = SquadLookDev()
    private(set) var loadLine = ""
    // diagnostics
    private var cpuAcc: Double = 0
    private var cpuFrames = 0
    private var lastLog: Double = 0

    init(level: Level, store: MeshStore) {
        self.level = level
        let t0 = FrameTimer.now()
        var bytes = 0, n = 0
        for c in MarineClass.allCases {
            guard let u = MarineAsset.url(c), let d = try? Data(contentsOf: u, options: .alwaysMapped),
                  let a = MarineAsset(cls: c, device: store.device, data: d) else {
                AppLog.error("squad: marine_\(c.id).ihv missing or unreadable")
                continue
            }
            assets[c.rawValue] = a
            bytes += a.fileBytes
            n += 1
        }
        textures = MarineTextures(device: store.device)
        let tris = assets.compactMap { $0 }.map { String($0.indexCount / 3) }.joined(separator: "/")
        loadLine = String(format: "squad: %d marines (%@ triangles, %.2f MB, %d clips each) maps %@ in %.0f ms", n, tris,
                          Double(bytes) / 1_048_576, assets.compactMap { $0 }.first?.clips.count ?? 0, textures.note,
                          (FrameTimer.now() - t0) * 1000)
        AppLog.info(loadLine)
        if lookDev.on { AppLog.info("squad: look-dev lineup" + (lookDev.closeUp ? " (close-up \(lookDev.tight ? "tight" : "wide"))" : "")) }
    }

    func reset() {
        aimInit = false
        for r in rigs { r?.reset() }
    }

    /// Resolve the pipelines, register the draw items (MetalWorld, once) and the ground glyphs'.
    func attach(_ r: MetalRenderer) {
        renderer = r
        ps = r.pipeline("marine")
        psShadow = r.pipeline("marineShadow")
        psFlash = r.pipeline("marineFlash")
        r.register(.opaque, order: 205, "squad") { [unowned self] enc in self.encode(enc) }
        r.register(.shadowCasters, order: 105, "squad casters") { [unowned self] enc in self.encodeCasters(enc) }
        r.register(.transparent, order: 310, "squad flashes") { [unowned self] enc in self.encodeFlashes(enc) }
        if ps == nil { AppLog.error("squad: marine pipeline missing") }
    }

    /// Interpolated feet of marine k (world).
    func feet(_ k: Int) -> (Float, Float, Float) {
        k >= 0 && k < poses.count ? (poses[k].x, poses[k].y, poses[k].z) : (0, 0, 0)
    }

    /// Muzzle of marine k this frame (world), when its rig has run.
    func muzzle(_ k: Int) -> F3? { k >= 0 && k < rigs.count ? rigs[k]?.worldSocket("muzzle") : nil }

    // ---------------------------------------------------------------- per frame
    /// Pose the squad for this frame.
    func build(game: Game, alpha: Float, dt: Float, time: Float, rise: Float) {
        let c0 = FrameTimer.now()
        let liftOn = game.stage == .extract
        if !aimInit {
            aimInit = true
            for (k, m) in game.marines.enumerated() where k < 4 { aimVis[k] = m.aim }
        }
        drawn.removeAll(keepingCapacity: true)
        flashes.removeAll(keepingCapacity: true)
        let lost = game.phase == .lost
        let high = renderer?.frameTier == .high
        if lookDev.on { lookDev.anchorOnce(game: game, level: level) }
        for (k, m) in game.marines.enumerated() where k < 4 {
            let x = m.px + (m.x - m.px) * alpha, z = m.pz + (m.z - m.pz) * alpha
            let y = level.groundY(x, z) + (liftOn && level.onLift(m.x, m.z) ? rise : 0)
            var d = m.aim - aimVis[k]
            while d > Float.pi { d -= TAU }
            while d < -Float.pi { d += TAU }
            aimVis[k] += d * min(1, 22 * dt)
            var I = RigInput()
            I.pos = F3(x, y, z)
            I.yaw = aimVis[k]
            I.vel = SIMD2<Float>(m.vx, m.vz)
            I.firing = m.firing
            I.muzzle = m.muzzle
            I.spin = m.spin
            I.dashT = m.dashT
            I.dashDir = SIMD2<Float>(m.dashX, m.dashZ)
            I.hurtT = m.hurtT
            I.knock = SIMD2<Float>(m.kx, m.kz)
            I.downed = m.downed
            I.revive = m.revive
            I.dead = lost && m.downed
            I.invulnerable = m.invulnerable
            if lookDev.on { lookDev.script(&I, k, time: time, level: level) }
            poses[k] = MetalEffects.MarinePose(x: I.pos.x, y: I.pos.y, z: I.pos.z)
            guard let a = assets[m.cls.rawValue] else { continue }
            if rigs[k] == nil || rigCls[k] != m.cls.rawValue {
                rigs[k] = MarineRig(asset: a)
                rigCls[k] = m.cls.rawValue
            }
            guard let rig = rigs[k] else { continue }
            rig.update(I, dt: dt)
            WorldSquad.torches[k] = rig.worldSocket("torch")
            // hurt flash (red, fading), the invulnerable shimmer (after a revive), downed dimming
            let hurt = max(0, min(1, m.hurtT / 0.22))
            let inv: Float = I.invulnerable ? 0.035 + 0.03 * sinf(time * 20) : 0
            let visor = rig.visor * (1 - 0.5 * hurt) * (m.downed ? 0.75 + 0.25 * sinf(time * 7 + Float(k)) : 1)
            let hue = linearRGB(m.spec.laser)
            let tr = linearRGB(WorldSquad.trim[m.cls.rawValue])
            draws[k] = MarineDraw(hue: F4(hue.x, hue.y, hue.z, visor),
                                  trim: F4(tr.x, tr.y, tr.z, Float(m.cls.rawValue)),
                                  flash: F4(0.55 * hurt + inv * 0.4, 0.04 * hurt + inv * 0.9, 0.03 * hurt + inv, m.downed && !I.dead ? 0.6 : (I.dead ? 1 : 0)),
                                  params: F4(m.isPlayer ? 0.16 : 0.12, 5.5, 3.5, high ? 1 : 0))
            weaponFx(k, m, I, rig, dt: dt, coreHeat: lookDev.on ? -1 : m.heat)
            drawn.append(k)
        }
        let ms = (FrameTimer.now() - c0) * 1000
        cpuAcc += ms
        cpuFrames += 1
        heartbeat(game: game)
    }

    // ---------------------------------------------------------------- weapon flashes
    @inline(__always) private func frand() -> Float {
        flashRng ^= flashRng << 13
        flashRng ^= flashRng >> 17
        flashRng ^= flashRng << 5
        return Float(flashRng & 0xffffff) / Float(0x1000000)
    }

    /// Marine k's weapon this frame: its flash instance (when it fires), the flash as a light on the marine and the
    /// heat of its barrels. `coreHeat`: the core's weapon heat (gunner / pyro), −1 in look-dev (scripted fire).
    private func weaponFx(_ k: Int, _ m: Marine, _ I: RigInput, _ rig: MarineRig, dt: Float, coreHeat: Float) {
        let mzOpt = rig.worldSocket("muzzle")
        let down = I.downed || I.dead
        // a new shot (the core's muzzle jumps back to 1): a new roll and seed, the flash restarts
        let newShot = I.muzzle > prevMuzzle[k] + 0.3
        prevMuzzle[k] = I.muzzle
        if newShot { shotRoll[k] = frand() * TAU; shotSeed[k] = frand(); shotAge[k] = 0 } else { shotAge[k] += dt }
        var h = heat[k]
        var inten: Float = 0, len: Float = 0, wid: Float = 0, kind: Float = 0, rays: Float = 4
        var col = F3(0, 0, 0), light: Float = 0, lcol = F3(0, 0, 0)
        var roll = shotRoll[k]
        switch m.cls {
        case .assault:
            // a short hard kick per round: bright for ~3 frames, a red-orange X star off the muzzle brake
            if newShot { h = min(0.8, h + 0.035) }
            h = max(0, h - 0.3 * dt)
            let a = max(0, 1 - shotAge[k] / 0.075)
            inten = a * a * (0.8 + 0.2 * shotSeed[k])
            len = 0.5 * (0.85 + 0.35 * shotSeed[k]); wid = 0.13; kind = 0; rays = 4
            col = F3(2.6, 0.78, 0.32); lcol = F3(1.0, 0.5, 0.28); light = 3.2 * a
        case .gunner:
            // the rotary's continuous six-ray flicker, a new roll every frame; the barrels heat with the core's heat
            let on = I.firing && I.spin > 0.35 && I.muzzle > 0.05
            if on { roll = frand() * TAU }
            let fl: Float = on ? 0.6 + 0.4 * frand() : 0
            inten = fl
            len = 0.66 * (0.8 + 0.3 * frand()); wid = 0.17; kind = 1; rays = 6
            col = F3(2.5, 1.65, 0.55); lcol = F3(1.0, 0.75, 0.35); light = 2.8 * fl
            h = coreHeat >= 0 ? h + (coreHeat - h) * min(1, 6 * dt) : (on ? min(1, h + 0.16 * dt) : max(0, h - 0.3 * dt))
        case .pyro:
            // the blue pilot flame always burns; firing: a hot orange cone at the nozzle (the jet itself is the
            // effects' particles)
            if I.firing && !down {
                inten = 0.75 + 0.25 * frand()
                len = 0.42 * (0.85 + 0.3 * frand()); wid = 0.15; kind = 2; rays = 0
                col = F3(2.6, 1.05, 0.28); lcol = F3(1.0, 0.55, 0.2); light = 3.6 * inten
                roll = frand() * TAU
            } else {
                inten = 0.55 + 0.15 * sinf(Float(k) + Float(flashCount) * 0.9)
                len = 0.09; wid = 0.022; kind = 2; rays = 0
                col = F3(0.45, 0.75, 2.2)
            }
            h = coreHeat >= 0 ? h + (coreHeat * 0.85 - h) * min(1, 6 * dt) : (I.firing ? min(0.85, h + 0.22 * dt) : max(0, h - 0.4 * dt))
        case .cryo:
            // the projector's emitter: a pulsing six-pointed ice star while the beam runs
            if I.firing && !down {
                inten = 0.7 + 0.3 * sinf(Float(flashCount) * 0.7 + Float(k))
                len = 0.3; wid = 0.13; kind = 3; rays = 6
                col = F3(0.75, 1.65, 2.6); lcol = F3(0.45, 0.8, 1.0); light = 2.0 * inten
                roll += dt * 2.5
                shotRoll[k] = roll
            }
            h = 0
        }
        heat[k] = h
        if down { inten = 0; light = 0 }
        guard let mz = mzOpt else { return }
        draws[k].muzzle = F4(mz.x, mz.y, mz.z, light)
        draws[k].fx = F4(lcol.x, lcol.y, lcol.z, h)
        if inten > 0.02, let b = rig.asset.sockets["muzzle"]?.bone {
            let d = rig.worldAxis(b, F3(0, 0, 1))
            flashes.append(FlashInstance(pos: F4(mz.x, mz.y, mz.z, len), dir: F4(d.x, d.y, d.z, wid),
                                         color: F4(col.x, col.y, col.z, kind), params: F4(roll, min(1, inten), shotSeed[k], rays)))
        }
    }

    private func encodeFlashes(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer, let ps = psFlash, flashRegion.count > 0 else { return }
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: flashRegion.offset, index: BufferIndex.instances)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 24, instanceCount: flashRegion.count)
        r.count(draws: 1, instances: flashRegion.count, triangles: 8 * flashRegion.count)
    }

    /// The palettes into the frame arena.
    func upload(_ r: MetalRenderer) {
        flashCount &+= 1
        flashRegion = flashes.isEmpty ? Region() : r.upload(flashes)
        for k in drawn {
            guard let rig = rigs[k], let a = r.alloc(SIMD4<Float>.self, rig.asset.bones * 3) else { palettes[k] = Region(); continue }
            rig.writePalette(a.0)
            palettes[k] = Region(offset: a.1, count: rig.asset.bones * 3)
        }
    }

    private func encode(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer, let ps = ps, !drawn.isEmpty else { return }
        r.use(enc, ps)
        if let t = textures.normal { enc.setFragmentTexture(t, index: Slot.normal) }
        if let t = textures.orm { enc.setFragmentTexture(t, index: Slot.orm) }
        for k in drawn {
            guard let rig = rigs[k], palettes[k].count > 0 else { continue }
            let a = rig.asset
            var D = draws[k]
            enc.setVertexBuffer(a.buffer, offset: a.vertexOffset, index: BufferIndex.vertices)
            enc.setVertexBuffer(r.arena, offset: palettes[k].offset, index: Slot.palette)
            enc.setVertexBytes(&D, length: MemoryLayout<MarineDraw>.stride, index: Slot.draw)
            enc.setFragmentBytes(&D, length: MemoryLayout<MarineDraw>.stride, index: Slot.draw)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: a.indexCount, indexType: a.indexType, indexBuffer: a.buffer,
                                      indexBufferOffset: a.indexOffset)
            r.count(draws: 1, instances: 1, triangles: a.indexCount / 3)
        }
    }

    /// Shadow caster item 105 (inside ShadowAtlas's depth pass, once per tile): the plates are single-sided shells, so
    /// both faces cast (the pass culls front faces; restored after).
    private func encodeCasters(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer, let ps = psShadow, !drawn.isEmpty else { return }
        enc.setRenderPipelineState(ps)
        enc.setCullMode(.none)
        for k in drawn {
            guard let rig = rigs[k], palettes[k].count > 0 else { continue }
            let a = rig.asset
            enc.setVertexBuffer(a.buffer, offset: a.vertexOffset, index: BufferIndex.vertices)
            enc.setVertexBuffer(r.arena, offset: palettes[k].offset, index: Slot.palette)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: a.indexCount, indexType: a.indexType, indexBuffer: a.buffer,
                                      indexBufferOffset: a.indexOffset)
            r.count(draws: 1, instances: 1, triangles: a.indexCount / 3)
        }
        enc.setCullMode(.front)
    }

    /// Look-dev close-up camera (eye, target, vertical fov in degrees), nil in normal play.
    func closeUpCamera() -> (F3, F3, Float)? { lookDev.camera(poses: poses) }

    private func heartbeat(game: Game) {
        guard AppLog.diagnostics else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        var slide: Float = 0, grip: Float = 0
        var steps = 0
        var st: [String] = []
        for r in rigs {
            guard let r = r else { continue }
            slide = max(slide, r.slideMax)
            grip = max(grip, r.gripErrMax)
            steps += r.restepCount
            r.slideMax = 0
            r.gripErrMax = 0
            r.restepCount = 0
            st.append(r.state)
        }
        AppLog.info(String(format: "hb squad cpu=%.3fms slide=%.1fcm grip=%.1fmm draws=%d restep=%d flashes=%d ", cpuAcc / Double(max(1, cpuFrames)),
                           slide * 100, grip * 1000, drawn.count, steps, flashes.count) + "states=" + st.joined(separator: ","))
        cpuAcc = 0
        cpuFrames = 0
    }

    /// A marine's flashlight: from its weapon torch (the squad's rig) — or the chest before the first frame — along the
    /// aim to a point 9 m ahead on the floor; a downed marine's lies on the deck pointing 2 m ahead. Position, unit
    /// direction.
    static func flashlight(_ m: Marine, _ p: MetalEffects.MarinePose) -> (F3, F3) {
        let pos: F3, target: F3
        let torch = m.index >= 0 && m.index < torches.count ? torches[m.index] : nil
        if m.downed {
            pos = torch ?? F3(p.x, p.y + 0.6, p.z)
            target = F3(p.x + m.ax * 2.4, p.y, p.z + m.az * 2.4)
        } else {
            pos = torch ?? F3(p.x + m.ax * 0.3, p.y + 1.75, p.z + m.az * 0.3)
            target = F3(p.x + m.ax * 9, p.y, p.z + m.az * 9)
        }
        let d = target - pos
        return (pos, d / max(1e-4, (d * d).sum().squareRoot()))
    }
}

// ================================================================ look-dev
/// `-squadSheet`: the squad lined up across the game camera's view, facing it, each marine cycling through its clips
/// (offset per marine, so one frame shows several); `-closeup` frames the line, `-closeupTight` the player's marine.
final class SquadLookDev {
    let on: Bool
    let closeUp: Bool
    let tight: Bool
    private var anchor = F3(0, 0, 0)
    private var anchored = false

    init() {
        let u = LaunchOptions.current.unknown
        on = u.contains("-squadSheet")
        tight = u.contains("-closeupTight")
        closeUp = on && (u.contains("-closeup") || tight)
    }

    func anchorOnce(game: Game, level: Level) {
        if anchored { return }
        anchored = true
        let p = game.player
        anchor = F3(p.x, level.groundY(p.x, p.z), p.z)
    }

    /// Spot k on the line (across the screen: the camera's right axis).
    private func spot(_ k: Int) -> SIMD2<Float> {
        let o = (Float(k) - 1.5) * 1.55
        return SIMD2<Float>(anchor.x + RIGHT_X * o, anchor.z + RIGHT_Z * o)
    }

    /// Override marine k's input with its script at `time`.
    func script(_ I: inout RigInput, _ k: Int, time: Float, level: Level) {
        let s = spot(k)
        I.pos = F3(s.x, level.groundY(s.x, s.y), s.y)
        // facing the camera (it looks along FWD from behind-right), turned a little per marine
        let face = atan2f(-FWD_X, -FWD_Z) + [0.35, -0.2, 0.25, -0.3][k % 4]
        I.yaw = face
        let fwd = SIMD2<Float>(sinf(face), cosf(face)), left = SIMD2<Float>(cosf(face), -sinf(face))
        I.vel = .zero
        I.firing = false
        I.muzzle = 0
        I.spin = 0
        I.dashT = 0
        I.hurtT = 0
        I.downed = false
        I.revive = 0
        I.dead = false
        I.invulnerable = false
        let cyc: Float = 12
        let t = fmodf(time + Float(k) * 3.1, cyc)
        switch t {
        case ..<2.0:
            break                                                // idle
        case ..<4.5:
            I.vel = fwd * 5.3                                    // run toward the camera, firing
            I.firing = true
            I.spin = 1
            I.muzzle = fmodf(t * 9, 1) < 0.5 ? 1 - fmodf(t * 9, 1) * 2 : 0
        case ..<6.0:
            I.vel = left * 4.5                                   // strafe
            I.firing = true
            I.spin = 1
            I.muzzle = fmodf(t * 9, 1) < 0.5 ? 1 - fmodf(t * 9, 1) * 2 : 0
        case ..<6.25:
            I.dashT = 0.22 - (t - 6.0)                           // dash forward
            I.dashDir = fwd
            I.vel = fwd * 17
        case ..<7.2:
            if t > 6.6 && t < 6.85 { I.hurtT = 0.22 - (t - 6.6); I.knock = -fwd * 3 }   // hit from the front
        case ..<10.5:
            I.downed = true                                      // down, crawl, revived from 9.0
            I.revive = max(0, (t - 9.0) / 1.5)
        default:
            I.invulnerable = true                                // getting up, then idle
        }
    }

    /// The close-up camera: the whole line (wide) or the player's marine (tight), 14° above, from the game's yaw.
    func camera(poses: [MetalEffects.MarinePose]) -> (F3, F3, Float)? {
        guard closeUp, poses.count == 4 else { return nil }
        let target: F3
        let dist: Float
        if tight {
            target = F3(poses[0].x, poses[0].y + 1.05, poses[0].z)
            dist = 3.4
        } else {
            target = F3(anchor.x, anchor.y + 1.0, anchor.z)
            dist = 8.2
        }
        let pitch: Float = 14 * Float.pi / 180
        let eye = target + F3(-FWD_X * cosf(pitch), sinf(pitch), -FWD_Z * cosf(pitch)) * dist
        return (eye, target, 40)
    }
}
