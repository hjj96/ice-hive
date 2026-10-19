import Foundation
import Metal
import IceHiveCore

// ================================================================
//  LIGHT GRID — the lights of the world frame (owned by WP2 «Свет и
//  воздух»). Every frame (LightGrid.fill, from MetalWorld's frame
//  uniforms) it writes:
//   • the frame-only light block of FrameUniforms (Shaders/Lighting.h
//     frame-only API, read by every material written before WP2):
//     faint cold moonlight + hemisphere (the blend's deep darkness),
//     the four flashlights following each marine's aim (flattened
//     falloff and cookie live in the shader), and three point lights:
//     [0] the effects' pooled light (flame / napalm / the player's
//     muzzle), [1] a cool fill light over the squad (readability in
//     the dark), [2] the strongest other grid light;
//   • the LightBlock (Lighting.h full API): up to 32 grid lights —
//     every firing marine's muzzle, flames, the cryo beam, napalm
//     fires, the effects' blast / floor light pools, beacon lamps, the
//     station's sodium lamps near the camera and the squad fill —
//     binned on the CPU into a 16 × 16 grid of 3 m cells around the
//     camera target (a 32-bit light mask per cell), the four spots'
//     cone / cookie / beam parameters (VolumeCones), the shadow atlas
//     rects and matrices (ShadowAtlas), height fog, occupancy and probe
//     parameters. Uploaded into the frame arena and bound once per
//     frame for the whole world pass (opaque item 10: buffer 5, the
//     probe at texture 4, the occupancy map at texture 5).
//  Launch options (look-dev / device A/B timing): `-nolight` (no
//  flashlights, point or grid lights: ambient only — weather must
//  vanish), `-lights off` grid lights off.
//  The shared state of the WP2 modules lives in LightingHub (one per
//  MetalWorld): LightGrid makes it, Atmosphere / ShadowAtlas pick it
//  up when MetalWorld attaches them.
// ================================================================

/// One grid light (`struct GridLight` in Lighting.h).
struct GridLight {
    /// xyz position, w = range (m).
    var posRange: F4
    /// rgb colour × intensity / π, w = 1: also specular (High).
    var color: F4
}

/// The fixed part of `struct LightBlock` (Lighting.h); the cell masks and the lights follow it in the same buffer.
struct LightBlockHeader {
    var grid = F4(0, 0, 1, 0)
    var info = F4(0, 0, 0, 1)
    var spotRect: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var spotMatrix: (Mat4, Mat4, Mat4, Mat4) = (.identity, .identity, .identity, .identity)
    var spotCone: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var beam: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var shadow = F4(0, 0, 0, 0)
    var fog = F4(0, 0, 0, 0)
    var fogColor = F4(0, 0, 0, 0)
    var occ = F4(0, 0, 0, 0)
    var fill = F4(0, 0, 0, 0)
    var ambient = F4(0, 0, 0, 0)
}

/// State shared by the WP2 modules of one MetalWorld (lights, spots, atlas, occupancy, probe) and the per-frame
/// binding of the light block.
final class LightingHub {
    /// The hub of the MetalWorld being built (LightGrid.init sets it; Atmosphere / ShadowAtlas attach to it).
    static weak var current: LightingHub?

    static let gridN = 16
    static let cellSize: Float = 3
    static let maxLights = 32
    /// Bytes of the whole LightBlock: header + cell masks + lights.
    static let blockBytes = MemoryLayout<LightBlockHeader>.stride + gridN * gridN * 4 + maxLights * MemoryLayout<GridLight>.stride

    private(set) var renderer: MetalRenderer?
    /// Bound when the frame arena is full (no grid lights, no beams): a shader never reads an unbound buffer.
    private var fallback: MTLBuffer?
    var header = LightBlockHeader()
    var cells = [UInt32](repeating: 0, count: LightingHub.gridN * LightingHub.gridN)
    var lights: [GridLight] = []
    /// Textures bound with the block (EnvProbe, Occupancy); nil binds nothing.
    var envTexture: MTLTexture?
    var occTexture: MTLTexture?
    /// The level (deck heights under the spots, lamps, piers).
    var level: Level?
    /// The occupancy pre-pass (Atmosphere attaches it; LightGrid.fill hands it the frame's bugs and marines).
    var occupancy: Occupancy?
    /// Per-frame pieces of the block that need the final frame constants (Atmosphere: cones, probe), run before the
    /// upload.
    var prepare: ((FrameUniforms) -> Void)?
    /// Lights other modules emit for this frame (effects: blasts, muzzles, flames …), taken by the next LightGrid.fill.
    private(set) var emitted: [(GridLight, Float)] = []

    /// A light for this frame only (call before MetalWorld fills the frame uniforms, e.g. from the effects' update):
    /// `color` linear, `intensity` like a three.js PointLight's, `range` (m); `priority` weighs it against the other
    /// ≤ 32 lights near the camera (muzzle 6, flame 12, napalm 20, blast 30).
    func emit(_ pos: F3, color: F3, intensity: Float, range: Float, specular: Bool = true, priority: Float = 10) {
        let c = color * (intensity / Float.pi)
        emitted.append((GridLight(posRange: F4(pos.x, pos.y, pos.z, range), color: F4(c.x, c.y, c.z, specular ? 1 : 0)), priority))
    }

    func takeEmitted() -> [(GridLight, Float)] {
        let e = emitted
        emitted.removeAll(keepingCapacity: true)
        return e
    }

    init() {
        // the Swift mirror must match Lighting.h's LightBlock byte for byte
        assert(MemoryLayout<GridLight>.stride == 32, "GridLight is 32 bytes in Lighting.h")
        assert(MemoryLayout<LightBlockHeader>.stride == 576, "LightBlock header is 576 bytes in Lighting.h")
        lights.reserveCapacity(LightingHub.maxLights)
    }

    /// The renderer of this world: register the per-frame binding of the light block (opaque item 10, before every
    /// material). Called once (by the first module that attaches).
    func attach(_ r: MetalRenderer) {
        guard renderer == nil else { return }
        renderer = r
        fallback = r.device.makeBuffer(length: LightingHub.blockBytes, options: [])
        fallback?.label = "light block (fallback)"
        r.register(.opaque, order: 10, "light block") { [unowned self] enc in self.bind(enc) }
    }

    /// Opaque item 10: the light block into the frame arena, bound for the vertex and fragment stages of the whole world
    /// pass (buffer 5), with the probe (texture 4) and the occupancy map (texture 5).
    private func bind(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer else { return }
        prepare?(r.frame)
        if let t = envTexture { enc.setFragmentTexture(t, index: LightGrid.textureEnv) }
        if let t = occTexture { enc.setFragmentTexture(t, index: LightGrid.textureOcc) }
        guard let a = r.alloc(UInt8.self, LightingHub.blockBytes) else {
            enc.setVertexBuffer(fallback, offset: 0, index: LightGrid.bufferIndex)
            enc.setFragmentBuffer(fallback, offset: 0, index: LightGrid.bufferIndex)
            return
        }
        let base = UnsafeMutableRawPointer(a.0)
        var h = header
        h.info.x = Float(lights.count)
        withUnsafeBytes(of: &h) { base.copyMemory(from: $0.baseAddress!, byteCount: MemoryLayout<LightBlockHeader>.stride) }
        let cellsAt = base + MemoryLayout<LightBlockHeader>.stride
        cells.withUnsafeBytes { cellsAt.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let lightsAt = cellsAt + cells.count * 4
        let n = min(lights.count, LightingHub.maxLights)
        if n > 0 { lights.withUnsafeBytes { lightsAt.copyMemory(from: $0.baseAddress!, byteCount: n * MemoryLayout<GridLight>.stride) } }
        enc.setVertexBuffer(r.arena, offset: a.1, index: LightGrid.bufferIndex)
        enc.setFragmentBuffer(r.arena, offset: a.1, index: LightGrid.bufferIndex)
        heartbeat()
    }

    private var lastLog: Double = 0

    /// Once per second (diagnostics): `hb light` — grid lights, lit cells, shadow tiles, beams, occupancy blobs.
    private func heartbeat() {
        guard AppLog.diagnostics else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        let h = header
        let tiles = [h.spotRect.0.z, h.spotRect.1.z, h.spotRect.2.z, h.spotRect.3.z].filter { $0 > 0 }.count
        let beams = [h.beam.0, h.beam.1, h.beam.2, h.beam.3]
        let lit = cells.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        AppLog.info("hb light lights=\(lights.count) cells=\(lit) tiles=\(tiles) beams=\(beams.filter { $0.x > 0 }.count)"
                    + (beams[0].w > 0 ? " march" : "") + " occ=\(occupancy?.blobCount ?? 0) tier=" + (h.info.y > 0 ? "high" : "efficient"))
    }
}

final class LightGrid {
    /// Buffer / texture slots of the light block (Lighting.h LIGHT_BUFFER, TEX_ENV, TEX_OCC).
    static let bufferIndex = 5
    static let textureEnv = 4
    static let textureOcc = 5

    // ---- the look (the blend: crisp's readability, horror's light discipline) ----
    /// Hemisphere sky / ground and moon: faint cold moonlight (the web rig had 0.42 / 0.5).
    static let skyColor: UInt32 = 0x4a5f86, groundColor: UInt32 = 0x030509
    static let hemiIntensity: Float = 0.2
    static let moonColor: UInt32 = 0x7d98c8
    static let moonIntensity: Float = 0.24
    /// Flashlight intensity: about half the web's LDR-tuned 62 player / 42 squad (horror's light discipline — in linear
    /// HDR the old values put the pool on the tone curve's shoulder, a flat pale wedge). The shader's flattened falloff
    /// is normalised to the web's d^-1.35 at 5 m, so the near field (a bug at the barrel, a marine in a squadmate's
    /// beam) gets about 0.6 of the web's light: the pool reads as a gradient (hot near the lens, the cookie's core and
    /// reflector ring), nothing in front of the lens blows out, and the beams in the air (VolumeCones) carry the light.
    static let spotPlayer: Float = 34, spotSquad: Float = 23, spotDowned: Float = 4
    /// Cool fill light over the squad (readability in the dark): height above the squad's centre, range, intensity.
    static let fillHeight: Float = 4.5, fillRange: Float = 10, fillIntensity: Float = 7
    static let fillColor = F3(0.62, 0.76, 1.0)
    /// Fog colour of the frame (display value at 0 EV before the grade) and the void the world pass clears to: a deep
    /// navy between crisp's (16, 29, 45) and horror's near-black (2, 6, 19) — after the grade's toe the void shows
    /// about (5, 14, 30), the distance fog (6, 15, 32), so the walkway edges still read against it.
    static let fogDisplay = displayRGB(0x0f1828)
    static let voidDisplay = displayRGB(0x0e1726)
    /// Height fog of the abyss: below the lowest deck (the lift, −6 m) the piers sink into this (display) colour.
    static let abyssDisplay = displayRGB(0x0c1422)
    static let abyssTop: Float = -6.5, abyssDepth: Float = 9, abyssDensity: Float = 0.92

    let hub = LightingHub()
    private var spotPos = [F4](repeating: .zero, count: 4), spotDir = [F4](repeating: .zero, count: 4)
    private var pointPos = [F4](repeating: .zero, count: 3), pointCol = [F4](repeating: .zero, count: 3)
    /// `-nolight` or `-demo nolight` (look check: without the flashlights the weather must vanish).
    private let noLight = LaunchOptions.current.unknown.contains("-nolight") || LaunchOptions.current.demo == "nolight"
    private let gridOff: Bool = {
        let a = LaunchOptions.current.unknown
        return a.firstIndex(of: "-lights").map { $0 + 1 < a.count && a[$0 + 1] == "off" } ?? false
    }()
    /// Static lamps of the station (from the level's floor light pools): position, unit colour.
    private var lamps: [(F3, F3)] = []
    private var lampsFor: ObjectIdentifier?
    private var candidates: [(GridLight, Float)] = []
    private var fogRadiance = F3(0, 0, 0)
    private var abyssRadiance = F3(0, 0, 0)

    init() {
        LightingHub.current = hub
        candidates.reserveCapacity(64)
        fogRadiance = LightGrid.radiance(display: LightGrid.fogDisplay)
        abyssRadiance = LightGrid.radiance(display: LightGrid.abyssDisplay)
    }

    /// The void colour the world pass clears to (linear radiance).
    static var voidRadiance: F3 { radiance(display: voidDisplay) }

    /// The linear radiance that shows as display value `d` at 0 EV before the grade: PostChain.display inverted per
    /// channel by bisection (Gauss–Seidel over the three channels, which the tone curve's matrices couple). Monotonic, so
    /// it converges for every value — PostChain.radiance(forDisplay:)'s Newton steps diverge where the curve's toe is
    /// flat (display ≲ 0.03: 0x070b12 came back as (27, 43, 70), a white void).
    static func radiance(display d: F3) -> F3 {
        var x = F3(0, 0, 0)
        for _ in 0..<4 {
            for c in 0..<3 {
                var lo: Float = 0, hi: Float = 16
                for _ in 0..<32 {
                    let mid = 0.5 * (lo + hi)
                    var t = x
                    t[c] = mid
                    if PostChain.display(t)[c] < d[c] { lo = mid } else { hi = mid }
                }
                x[c] = 0.5 * (lo + hi)
            }
        }
        return x
    }

    /// Fill the light block of `F` and the hub's LightBlock for this frame.
    func fill(_ F: inout FrameUniforms, game: Game, time: Float, poses: [MetalEffects.MarinePose], fx: MetalEffects) {
        let invPi: Float = 1 / Float.pi
        let level = game.level
        hub.level = level
        // ambient: faint cold moonlight
        let hemiK: Float = LightGrid.hemiIntensity * invPi, moonK: Float = LightGrid.moonIntensity * invPi
        let sky: F3 = linearRGB(LightGrid.skyColor) * hemiK
        let ground: F3 = linearRGB(LightGrid.groundColor) * hemiK
        F.hemiSky = F4(sky.x, sky.y, sky.z, 0)
        F.hemiGround = F4(ground.x, ground.y, ground.z, 0)
        let md = F3(-25, 60, 35) / (F3(-25, 60, 35) * F3(-25, 60, 35)).sum().squareRoot()
        F.moonDir = F4(md.x, md.y, md.z, 0)
        let mc: F3 = linearRGB(LightGrid.moonColor) * moonK
        F.moonColor = F4(mc.x, mc.y, mc.z, 0)
        // the fog of the frame (MetalWorld wrote the distance density; the colour is the light discipline's)
        F.fog = F4(fogRadiance.x, fogRadiance.y, fogRadiance.z, F.fog.w)

        // flashlights follow the aim
        var squadC = F3(0, 0, 0), squadN: Float = 0
        for k in 0..<4 { spotPos[k] = .zero; spotDir[k] = .zero }
        for (k, m) in game.marines.enumerated() where k < 4 {
            let (pos, dir) = WorldSquad.flashlight(m, poses[k])
            let i: Float = m.downed ? LightGrid.spotDowned * (0.6 + 0.4 * sinf(time * 9 + Float(k)))
                : (m.isPlayer ? LightGrid.spotPlayer : LightGrid.spotSquad) * (m.firing ? 1.08 : 1) * (m.hurtT > 0 ? 0.6 + 0.4 * sinf(time * 60) : 1)
            spotPos[k] = F4(pos.x, pos.y, pos.z, noLight ? 0 : i * invPi)
            spotDir[k] = F4(dir.x, dir.y, dir.z, 0)
            if !m.downed || squadN == 0 { squadC += F3(poses[k].x, poses[k].y, poses[k].z); squadN += 1 }
        }
        F.spotPos = (spotPos[0], spotPos[1], spotPos[2], spotPos[3])
        F.spotDir = (spotDir[0], spotDir[1], spotDir[2], spotDir[3])
        let fillAt = squadN > 0 ? squadC / squadN + F3(0, LightGrid.fillHeight, 0) : F3(0, -60, 0)

        // grid lights: collect, keep the 32 that matter most near the camera target, bin
        let focus = gridFocus(game: game, poses: poses)
        collect(game: game, time: time, poses: poses, fx: fx, fillAt: fillAt, focus: focus)
        bin(focus: focus)
        hub.occupancy?.collect(game: game, poses: poses)

        // the frame-only API's three point lights: the effects' pooled light, the squad fill, the strongest other
        for k in 0..<3 { pointPos[k] = .zero; pointCol[k] = .zero }
        if !noLight {
            let l = fx.lights[0]
            if l.intensity > 0.01 {
                pointPos[0] = F4(l.pos.x, l.pos.y, l.pos.z, 18)
                let c = l.color * (l.intensity * invPi)
                pointCol[0] = F4(c.x, c.y, c.z, 0)
            }
            if squadN > 0 {
                pointPos[1] = F4(fillAt.x, fillAt.y, fillAt.z, LightGrid.fillRange)
                let c = LightGrid.fillColor * (LightGrid.fillIntensity * invPi)
                pointCol[1] = F4(c.x, c.y, c.z, 0)
            }
            if let best = strongestOther {
                pointPos[2] = best.posRange
                pointCol[2] = F4(best.color.x, best.color.y, best.color.z, 0)
            }
        }
        F.pointPos = (pointPos[0], pointPos[1], pointPos[2])
        F.pointColor = (pointCol[0], pointCol[1], pointCol[2])

        // the rest of the light block (spots' cones / beams: VolumeCones; atlas: ShadowAtlas)
        var h = hub.header
        let n = Float(LightingHub.gridN)
        h.grid = F4(gridOrigin.x, gridOrigin.y, 1 / LightingHub.cellSize, n)
        h.info.y = hub.renderer?.frameTier == .high ? 1 : 0
        h.fog = F4(LightGrid.abyssTop, LightGrid.abyssDepth, LightGrid.abyssDensity, time)
        h.fogColor = F4(abyssRadiance.x, abyssRadiance.y, abyssRadiance.z, h.fogColor.w)
        h.fill = F4(fillAt.x, fillAt.y, fillAt.z, LightGrid.fillRange)
        hub.header = h
    }

    // ---------------------------------------------------------------- light collection
    private var gridOrigin = SIMD2<Float>(0, 0)
    private var strongestOther: GridLight?

    /// The grid follows the player (the camera target), snapped to whole cells so lights do not swim between cells.
    private func gridFocus(game: Game, poses: [MetalEffects.MarinePose]) -> F3 {
        if let p = poses.first, !game.marines.isEmpty { return F3(p.x, p.y, p.z) }
        return F3(0, 0, 0)
    }

    private func add(_ pos: F3, _ color: F3, intensity: Float, range: Float, spec: Bool = true, priority: Float = 1) {
        let c = color * (intensity / Float.pi)
        candidates.append((GridLight(posRange: F4(pos.x, pos.y, pos.z, range), color: F4(c.x, c.y, c.z, spec ? 1 : 0)), priority))
    }

    private func collect(game: Game, time: Float, poses: [MetalEffects.MarinePose], fx: MetalEffects, fillAt: F3, focus: F3) {
        candidates.removeAll(keepingCapacity: true)
        lightsFromLevel(game.level)
        let emitted = hub.takeEmitted()
        guard !noLight && !gridOff else { hub.lights.removeAll(keepingCapacity: true); strongestOther = nil; return }
        candidates.append(contentsOf: emitted)
        // the squad fill (also the frame-only point light 1)
        add(fillAt, LightGrid.fillColor, intensity: LightGrid.fillIntensity, range: LightGrid.fillRange, spec: false, priority: 50)
        // the effects' pooled light (flame / napalm / the player's muzzle; also the frame-only point light 0)
        let l0 = fx.lights[0]
        if l0.intensity > 0.01 { add(l0.pos, l0.color, intensity: l0.intensity, range: 18, priority: 40) }
        // every firing marine's muzzle (squad muzzles are not in the effects' pool), flames and the cryo beam
        for (k, m) in game.marines.enumerated() where k < 4 && k < poses.count && !m.downed {
            let p = poses[k]
            if m.muzzle > 0 && !m.isPlayer && (m.cls == .assault || m.cls == .gunner) {
                let col = linearRGB(m.cls == .assault ? 0xff6040 : 0xffc060)
                add(F3(p.x + m.ax * 1.0, p.y + 1.3, p.z + m.az * 1.0), col, intensity: 45 * min(1, m.muzzle + 0.3), range: 9, priority: 6)
            }
            if m.firing && m.cls == .pyro && !m.isPlayer {
                add(F3(p.x + m.ax * 3.5, p.y + 1.4, p.z + m.az * 3.5), linearRGB(0xff7a28), intensity: 80 * (0.8 + 0.2 * sinf(time * 37 + Float(k))), range: 14, priority: 12)
            }
            if m.firing && m.cls == .cryo {
                add(F3(p.x + m.ax * m.beamLen * 0.5, p.y + 1.2, p.z + m.az * m.beamLen * 0.5), linearRGB(0x60c8ff), intensity: 40, range: 12, priority: 10)
            }
        }
        // napalm fires
        for nap in game.napalms where nap.active {
            add(F3(nap.x, game.level.groundY(nap.x, nap.z) + 1.5, nap.z), linearRGB(0xff6a20), intensity: 110 * (0.8 + 0.2 * sinf(time * 29 + nap.x)), range: 16, priority: 20)
        }
        // the effects' floor light pools (blasts, muzzle pools, acid): the brightest become real lights
        for s in fx.glowSprites where s.center.w < 0.5 {
            let size = max(abs(s.axisU.x), abs(s.axisU.z), abs(s.axisV.x), abs(s.axisV.z))
            let c = F3(s.color.x, s.color.y, s.color.z) * s.color.w
            let e = max(c.x, max(c.y, c.z))
            if e < 0.06 || size < 1.5 { continue }
            add(F3(s.center.x, s.center.y + 1.2, s.center.z), c / e, intensity: e * 160, range: min(14, size * 1.6), priority: 4 + e * 10)
        }
        // beacon lamps: amber while charging, teal when lit
        for (k, b) in game.beacons.enumerated() where b.state >= 1 {
            let gy = game.level.groundY(b.x, b.z)
            let col: F3 = b.state == 2 ? F3(0.25, 1.0, 0.85) : F3(1.0, 0.7, 0.15)
            let pulse: Float = b.state == 1 ? 0.7 + 0.3 * sinf(time * 6 + Float(k)) : 1
            add(F3(b.x, gy + 3.0, b.z), col, intensity: 30 * pulse, range: 10, priority: 8)
        }
        // the station's lamps near the grid
        for (p, c) in lamps where abs(p.x - focus.x) < 30 && abs(p.z - focus.z) < 30 {
            add(p, c, intensity: 9, range: 7, spec: false, priority: 1)
        }
        // keep the 32 that matter most: priority × intensity, falling off with the distance to the grid centre
        if candidates.count > LightingHub.maxLights {
            for i in candidates.indices {
                let p = candidates[i].0.posRange
                let dx = p.x - focus.x, dz = p.z - focus.z
                let e = max(candidates[i].0.color.x, max(candidates[i].0.color.y, candidates[i].0.color.z))
                candidates[i].1 *= e / (1 + (dx * dx + dz * dz) / 400)
            }
            candidates.sort { $0.1 > $1.1 }
            candidates.removeLast(candidates.count - LightingHub.maxLights)
        }
        hub.lights.removeAll(keepingCapacity: true)
        strongestOther = nil
        var best: Float = 0
        for (gl, _) in candidates {
            hub.lights.append(gl)
            // the frame-only point 2: the strongest light that is not the fill or the pooled fx light
            let e = max(gl.color.x, max(gl.color.y, gl.color.z)) * gl.posRange.w
            let isFill = gl.color.w == 0 && abs(gl.posRange.y - fillAt.y) < 0.01 && abs(gl.posRange.x - fillAt.x) < 0.01
            let isPool = l0.intensity > 0.01 && abs(gl.posRange.x - l0.pos.x) < 0.01 && abs(gl.posRange.z - l0.pos.z) < 0.01
            if !isFill && !isPool && e > best { best = e; strongestOther = gl }
        }
    }

    /// Station lamps from the level's floor light pools (the IHM1 mesh `level_glow`: quads under lamps, pillars, vents):
    /// teal walkway lamps 2.6 m above their pool, red vent glows just above the grate. Read once per level.
    private func lightsFromLevel(_ level: Level) {
        let id = ObjectIdentifier(level)
        if lampsFor == id { return }
        lampsFor = id
        lamps = LightGrid.readLamps()
    }

    /// Quad centres and colours of Meshes/level_glow.mesh (IHM1: 16-byte header + counts, 52-byte vertices).
    static func readLamps() -> [(F3, F3)] {
        guard let u = Bundle.main.url(forResource: "level_glow", withExtension: "mesh"), let d = try? Data(contentsOf: u), d.count > 16 else { return [] }
        return d.withUnsafeBytes { raw -> [(F3, F3)] in
            guard raw.count >= 16, String(bytes: raw[0..<4], encoding: .ascii) == "IHM1" else { return [] }
            let nv = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let start = 16
            guard nv > 0, start + nv * 52 <= raw.count else { return [] }
            var out: [(F3, F3)] = []
            var q = 0
            while q + 3 < nv {
                var c = F3(0, 0, 0), col = F3(0, 0, 0)
                for v in 0..<4 {
                    let o = start + (q + v) * 52
                    c += F3(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                            raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self))
                    col += F3(raw.loadUnaligned(fromByteOffset: o + 24, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 28, as: Float.self),
                              raw.loadUnaligned(fromByteOffset: o + 32, as: Float.self))
                }
                c /= 4; col /= 4
                let e = max(col.x, max(col.y, col.z))
                let vent = col.x > col.y * 3
                if e > 0.02 { out.append((c + F3(0, vent ? 0.4 : 2.6, 0), col / e)) }
                q += 4
            }
            return out
        }
    }

    /// Bin the lights into the 16 × 16 cells around `focus` (bit i of a cell = light i reaches it).
    private func bin(focus: F3) {
        let n = LightingHub.gridN, cs = LightingHub.cellSize
        let half = Float(n) * cs * 0.5
        let ox = (focus.x / cs).rounded(.down) * cs - half, oz = (focus.z / cs).rounded(.down) * cs - half
        gridOrigin = SIMD2(ox, oz)
        for i in hub.cells.indices { hub.cells[i] = 0 }
        for (i, l) in hub.lights.enumerated() where i < 32 {
            let r = l.posRange.w
            let x0 = max(0, Int(((l.posRange.x - r - ox) / cs).rounded(.down))), x1 = min(n - 1, Int(((l.posRange.x + r - ox) / cs).rounded(.down)))
            let z0 = max(0, Int(((l.posRange.z - r - oz) / cs).rounded(.down))), z1 = min(n - 1, Int(((l.posRange.z + r - oz) / cs).rounded(.down)))
            if x0 > x1 || z0 > z1 { continue }
            let bit = UInt32(1) << UInt32(i)
            for z in z0...z1 {
                // only cells the light's sphere touches (closest point of the cell within the range)
                let cz = oz + Float(z) * cs
                let dz = max(0, max(cz - l.posRange.z, l.posRange.z - (cz + cs)))
                for x in x0...x1 {
                    let cx = ox + Float(x) * cs
                    let dx = max(0, max(cx - l.posRange.x, l.posRange.x - (cx + cs)))
                    if dx * dx + dz * dz <= r * r { hub.cells[z * n + x] |= bit }
                }
            }
        }
    }
}
