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
//  Look-dev (`-squadSheet`, optional `-closeup` / `-closeupTight`): the
//  squad lined up facing the game camera, each marine cycling through
//  its clips (idle, run, strafe, fire, dash, down, crawl, revive); with
//  -closeup the camera frames them (MetalWorld asks closeUpCamera).
//  `hb squad` (diagnostics, once a second): rig CPU per frame, the worst
//  planted-foot slide over one contact (stride), hand-to-grip error, states.
// ================================================================

/// Per-draw constants of a marine (`struct MarineDraw` in Characters.metal), 64 bytes.
struct MarineDraw {
    /// rgb class hue (linear), w = visor glow multiplier.
    var hue: F4
    /// rgb class paint (linear), w = texture layer (class index).
    var trim: F4
    /// rgb added emissive (hurt / invulnerable), w = downed dimming.
    var flash: F4
    /// x class rim strength, y visor / strip gain, z lamp gain, w = 1 on the High tier.
    var params: F4
}

final class WorldSquad {
    /// The squad's pipelines (and the ground glyphs'): compiled with the world's behind the loading cover.
    static let pipelines: [PipelineSpec] = [
        .world("marine", "vs_marine", "fs_marine"),
        .depthOnly("marineShadow", "vs_marine_shadow"),
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
        r.register(.opaque, order: 205, "squad") { [unowned self] enc in self.encode(enc) }
        r.register(.shadowCasters, order: 105, "squad casters") { [unowned self] enc in self.encodeCasters(enc) }
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
            drawn.append(k)
        }
        let ms = (FrameTimer.now() - c0) * 1000
        cpuAcc += ms
        cpuFrames += 1
        heartbeat(game: game)
    }

    /// The palettes into the frame arena.
    func upload(_ r: MetalRenderer) {
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
        var st: [String] = []
        for r in rigs {
            guard let r = r else { continue }
            slide = max(slide, r.slideMax)
            grip = max(grip, r.gripErrMax)
            r.slideMax = 0
            r.gripErrMax = 0
            st.append(r.state)
        }
        AppLog.info(String(format: "hb squad cpu=%.3fms slide=%.1fcm grip=%.1fmm draws=%d ", cpuAcc / Double(max(1, cpuFrames)), slide * 100,
                           grip * 1000, drawn.count) + "states=" + st.joined(separator: ","))
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
