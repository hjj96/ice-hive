import Foundation
import Metal
import IceHiveCore

// ================================================================
//  VOLUME CONES / ATMOSPHERE — the air of the world frame (owned by
//  WP2 «Свет и воздух»; shaders: Shaders/Atmosphere.metal).
//  `Atmosphere` is the module MetalWorld talks to (pipelines, attach,
//  build); it owns the pieces:
//    VolumeCones    the four flashlights as analytic volumetric cones
//                   (transparent item 450, additive, back faces culled,
//                   one instanced draw): per-beam gain, length, the deck
//                   height under each marine, the player's shadowed
//                   march (High) — written into the LightBlock
//    fog decks      transparent items 90 / 102: 2 sheets of drifting dark
//                   fog under the decks (Efficient: 1), the deep one
//                   before the haze plane, the upper one after it
//    haze           transparent item 100: the old haze plane, now a
//                   faint navy lift of the abyss deep in the shaft
//    running lights transparent item 105: red / sodium lamps on the
//                   piers far below (static instance buffer)
//    weather        transparent item 700: snow and low mist lit only by
//                   the flashlights, pink motes out of the abyss
//    Occupancy      pre-pass 150 (Lighting/Occupancy.swift)
//    EnvProbe       the 64² environment cube (Lighting/EnvProbe.swift)
//  Weather counts by tier: High 5000 flakes / 10 mist banks / 420
//  motes, Efficient 1800 / 4 / 240, «низкая» 900 / 0 / 160.
//  Launch options: `-noweather`, `-nocones` (device A/B timing).
// ================================================================
final class VolumeCones {
    /// In-scatter gain per beam (× the spot's intensity / π) and the beam's visible length (m); the player's is a little
    /// denser. The saturation cap is LightBlock.fogColor.w (radiance a beam adds at most: ~0.13 shows about 95 of 255
    /// over the dark deck, 0.17 about 110 — a veil, never a white-out: four crossed beams stay under the tone curve's
    /// shoulder). CI 858bcdb at 0.017 / 0.13: the shafts only lifted their own pools (≤ 35 levels in the calm A/B) and
    /// vanished in the swarmshot's fire — horror's beams have to read as shafts at phone size, so 0.024 / 0.17.
    /// With the flashlights at half the web's intensity the beams, not the pools, carry the light (horror's discipline):
    /// the air's gentler falloff (Atmosphere.metal fs_cone) puts ~0.08 over the near pool (~0.2), ~0.05 at 9 m where the
    /// pool has dropped to ~0.04, and the shaft fades out from 7 to 16 m (CI 82f523c: with the pool's own falloff the
    /// in-scatter hid inside the pool).
    static let gain: Float = 0.024, playerGain: Float = 1.15
    static let length: Float = 16
    static let cap: Float = 0.17
    /// Cookie and cone of the spots (Lighting.h SPOT_COS_OUT / SPOT_COS_IN, 32 m range).
    static let cosOut: Float = 0.87758, cosIn: Float = 0.97479, range: Float = 32, cookie: Float = 1

    private var renderer: MetalRenderer!
    private var hub: LightingHub!
    private var tiered = TieredPipeline(high: nil, efficient: nil)
    private let off = LaunchOptions.current.unknown.contains("-nocones")

    func attach(_ r: MetalRenderer, hub h: LightingHub) {
        renderer = r
        hub = h
        tiered = r.tieredPipeline("cones")
        r.register(.transparent, order: 450, "flashlight cones") { [unowned self] enc in self.encode(enc) }
    }

    /// Cone / beam parameters of this frame into the light block (from the spots LightGrid wrote into the frame).
    func prepare(_ F: FrameUniforms, level: Level?, high: Bool, playerTile: Bool) {
        var h = hub.header
        let sp = [F.spotPos.0, F.spotPos.1, F.spotPos.2, F.spotPos.3]
        let rise = F.misc.z
        var beams = [F4](repeating: .zero, count: 4)
        for k in 0..<4 where sp[k].w > 0 && !off {
            var deck = sp[k].y - 1.75
            if let L = level {
                deck = L.groundY(sp[k].x, sp[k].z) + (rise > 0 && L.onLift(sp[k].x, sp[k].z) ? rise : 0)
            }
            let g = VolumeCones.gain * (k == 0 ? VolumeCones.playerGain : 1)
            beams[k] = F4(g, VolumeCones.length, deck, k == 0 && high && playerTile ? 1 : 0)
        }
        let cone = F4(VolumeCones.cosOut, VolumeCones.cosIn, VolumeCones.range, VolumeCones.cookie)
        h.spotCone = (cone, cone, cone, cone)
        h.beam = (beams[0], beams[1], beams[2], beams[3])
        h.fogColor.w = VolumeCones.cap
        hub.header = h
    }

    /// Transparent item 450: the four cone hulls (96 vertices each, back faces culled), additive.
    private func encode(_ enc: MTLRenderCommandEncoder) {
        guard !off, let ps = tiered(renderer.frameTier) else { return }
        let r = renderer!
        r.use(enc, ps)
        enc.setCullMode(.back)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 96, instanceCount: 4)
        r.count(draws: 1, instances: 4, triangles: 128)
        enc.setCullMode(.none)
    }
}

/// One fog sheet (`struct FogDeck` in Atmosphere.metal).
struct FogDeckParams {
    var plane: F4
    var color: F4
    var center: F4
}

/// One lamp far below (`struct RunLight` in Atmosphere.metal).
struct RunLightInstance {
    var pos: F4
    var color: F4
}

final class Atmosphere {
    static let pipelines: [PipelineSpec] = [
        .world("haze", "vs_haze", "fs_haze", .alpha, .ihm1),
        .world("fogDeck", "vs_fogdeck", "fs_fogdeck", .alpha),
        .world("runLights", "vs_runlight", "fs_runlight", .add),
        .world("cones", "vs_cone", "fs_cone", .add, tiered: true),
        .world("weather", "vs_weather", "fs_weather", .add),
    ] + Occupancy.pipelines

    // ---- the look
    /// Fog sheets under the decks: height (m), opacity, noise scale (1/m), drift (m/s), display colour.
    static let decks: [(Float, Float, Float, Float, UInt32)] = [(-9, 0.5, 0.045, 0.35, 0x111a28), (-21, 0.7, 0.03, 0.22, 0x0c1420)]
    /// Gains of the weather: snow / mist (× the flashlight in-scatter), motes (× their pink).
    static let snowGain: Float = 0.16, mistGain: Float = 0.15, moteGain: Float = 0.55
    /// Height of the haze plane (level_haze, m): fog decks below it draw before it, the ones above after it.
    static let hazeY: Float = -16

    private var renderer: MetalRenderer!
    private var hub: LightingHub!
    let cones = VolumeCones()
    let occupancy = Occupancy()
    let probe = EnvProbe()
    private var meshHaze: GPUMesh!
    private var texHaze: MTLTexture!
    private var psHaze: MTLRenderPipelineState?, psWeather: MTLRenderPipelineState?
    private var psFog: MTLRenderPipelineState?, psRun: MTLRenderPipelineState?
    private var runLights: MTLBuffer?
    private var runCount = 0
    private var runFor: ObjectIdentifier?
    // this frame's weather around the camera target
    private var snow = 0, mist = 0, motes = 0
    /// Snow box around the camera target: half extent, height (m) — dense where the squad's beams are (5000 flakes:
    /// ~2 a m³), nothing is spent on flakes far outside them.
    private var snowBox = F3(12, 6, 0)
    private var center = F4(0, 0, 0, 0)
    private var deckCount = 2
    /// The fog decks' colours as linear radiance (from their display values, once).
    private lazy var deckColors: [F3] = Atmosphere.decks.map { LightGrid.radiance(display: displayRGB($0.4)) }
    private let weatherOff = LaunchOptions.current.unknown.contains("-noweather")

    /// Resolve meshes / pipelines, register the atmosphere's items and the light block binding (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        hub = LightingHub.current ?? LightingHub()
        hub.attach(r)
        meshHaze = r.store.mesh("level_haze")
        texHaze = r.store.texture("haze")
        psHaze = r.pipeline("haze"); psWeather = r.pipeline("weather"); psFog = r.pipeline("fogDeck"); psRun = r.pipeline("runLights")
        // the void behind everything: deeper than the fog (the abyss is not a flat colour)
        r.targets.setClearColor(LightGrid.voidRadiance)
        cones.attach(r, hub: hub)
        occupancy.attach(r, hub: hub)
        hub.envTexture = probe.load(device: r.device)
        hub.prepare = { [unowned self] F in self.prepare(F) }
        AppLog.info(String(format: "metal: lighting: shadow atlas %dx%d %@ (%.1f MB), occupancy 2x%d² RG8, probe %d mips, %d grid lights / %d² cells of %.0f m",
                           ShadowAtlas.width, ShadowAtlas.height, ShadowAtlas.format == .depth32Float ? "D32F" : "D16",
                           Double(ShadowAtlas.width * ShadowAtlas.height * (ShadowAtlas.format == .depth32Float ? 4 : 2)) / 1_048_576,
                           Occupancy.size, probe.mipCount, LightingHub.maxLights, LightingHub.gridN, LightingHub.cellSize))
        r.register(.transparent, order: 90, "fog decks (deep)") { [unowned self] enc in self.encodeFogDecks(enc, above: false) }
        r.register(.transparent, order: 100, "haze") { [unowned self] enc in self.encodeHaze(enc) }
        r.register(.transparent, order: 102, "fog decks") { [unowned self] enc in self.encodeFogDecks(enc, above: true) }
        r.register(.transparent, order: 105, "running lights") { [unowned self] enc in self.encodeRunLights(enc) }
        r.register(.transparent, order: 700, "weather") { [unowned self] enc in self.encodeWeather(enc) }
    }

    /// This frame's weather around `focus` for the effects tier `fxK` (and the tier's fog decks).
    func build(focus: F3, fxK k: Float) {
        let high = renderer?.frameTier == .high
        if weatherOff {
            snow = 0; mist = 0; motes = 0
        } else if k < 0.5 {
            snow = 900; mist = 0; motes = 160
        } else if high && k >= 0.85 {
            snow = 5000; mist = 10; motes = 420
        } else {
            snow = 1800; mist = 4; motes = 240
        }
        deckCount = high ? 2 : 1
        center = F4(focus.x, focus.y, focus.z, 0)
    }

    /// The light block's per-frame pieces that need the final frame constants (the hub calls this before uploading).
    private func prepare(_ F: FrameUniforms) {
        let high = renderer.frameTier == .high
        cones.prepare(F, level: hub.level, high: high, playerTile: hub.header.spotRect.0.z > 0)
        var h = hub.header
        h.info.z = 1
        h.info.w = Float(probe.mipCount)
        h.ambient = F4(EnvProbe.diffuseWeight, EnvProbe.specularWeight, Occupancy.contactStrength, 0)
        hub.header = h
    }

    // ---------------------------------------------------------------- draw items
    /// Transparent items 90 / 102: the fog decks (alpha) below / above the haze plane (back to front from the game
    /// camera), centred on the camera target, snapped to 8 m.
    private func encodeFogDecks(_ enc: MTLRenderCommandEncoder, above: Bool) {
        guard let ps = psFog else { return }
        let r = renderer!
        var decks: [FogDeckParams] = []
        let cx = (center.x / 8).rounded() * 8, cz = (center.z / 8).rounded() * 8
        for (i, d) in Atmosphere.decks.prefix(deckCount).enumerated() where (d.0 > Atmosphere.hazeY) == above {
            let c = deckColors[i]
            decks.append(FogDeckParams(plane: F4(d.0, d.1, d.2, d.3), color: F4(c.x, c.y, c.z, Float(i) * 7.31 + 0.5),
                                       center: F4(cx, 120, cz, 110)))
        }
        if decks.isEmpty { return }
        r.use(enc, ps)
        decks.withUnsafeBytes { b in
            enc.setVertexBytes(b.baseAddress!, length: b.count, index: BufferIndex.instances)
            enc.setFragmentBytes(b.baseAddress!, length: b.count, index: BufferIndex.instances)
        }
        r.drawQuads(enc, decks.count)
    }

    /// Transparent item 100: the abyss haze plane.
    private func encodeHaze(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psHaze else { return }
        let r = renderer!
        r.use(enc, ps)
        r.bindMain(enc, texHaze)
        var mat = MaterialUniforms(pbr: .zero, floor: .zero)
        r.drawStatic(enc, meshHaze, &mat)
    }

    /// Transparent item 105: the running lights on the piers far below.
    private func encodeRunLights(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psRun else { return }
        let r = renderer!
        if let L = hub.level, runFor != ObjectIdentifier(L) { buildRunLights(L) }
        guard let b = runLights, runCount > 0 else { return }
        r.use(enc, ps)
        enc.setVertexBuffer(b, offset: 0, index: BufferIndex.instances)
        r.drawQuads(enc, runCount)
    }

    /// Lamps on every pier (one shallow, one deep), a ring around the lift shaft and a few deep in open abyss: 60 %
    /// aviation red (a third of them blinking), 40 % sodium.
    private func buildRunLights(_ L: Level) {
        runFor = ObjectIdentifier(L)
        var out: [RunLightInstance] = []
        var seed: UInt32 = 0x9e3779b9
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }
        func lamp(_ x: Float, _ y: Float, _ z: Float) {
            let red = rnd() < 0.6
            let c = red ? F3(2.6, 0.12, 0.05) : F3(2.3, 0.85, 0.22)
            let blink: Float = red && rnd() < 0.35 ? rnd() : -1
            out.append(RunLightInstance(pos: F4(x, y, z, red ? 0.22 : 0.3), color: F4(c.x, c.y, c.z, blink)))
        }
        for p in L.layout.pillars {
            let top = L.groundY(p.x, p.y)
            lamp(p.x + 0.45, top - 5 - rnd() * 6, p.y + 0.45)
            lamp(p.x - 0.45, top - 16 - rnd() * 18, p.y - 0.45)
        }
        let lf = L.lift
        for k in 0..<10 {
            let a = Float(k) / 10 * 2 * Float.pi
            lamp(lf.x + cosf(a) * (lf.r + 1.2), lf.y - 4 - Float(k % 3) * 6, lf.z + sinf(a) * (lf.r + 1.2))
        }
        var tries = 0
        while out.count < 64 && tries < 400 {
            tries += 1
            let x = rnd() * 110 - 55, z = rnd() * 110 - 55
            if L.solid(x, z) { continue }
            lamp(x, -14 - rnd() * 30, z)
        }
        runCount = out.count
        runLights = out.withUnsafeBytes { renderer.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
        runLights?.label = "running lights"
    }

    /// Transparent item 700: snow and mist lit by the flashlights, motes rising from the abyss (all additive).
    private func encodeWeather(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psWeather, snow + mist + motes > 0 else { return }
        renderer.use(enc, ps)
        if snow > 0 { weather(enc, kind: 0, count: snow, gain: Atmosphere.snowGain) }
        if mist > 0 { weather(enc, kind: 2, count: mist, gain: Atmosphere.mistGain) }
        if motes > 0 { weather(enc, kind: 1, count: motes, gain: Atmosphere.moteGain) }
    }

    private func weather(_ enc: MTLRenderCommandEncoder, kind: Float, count: Int, gain: Float) {
        var w = (F4(center.x, center.y, center.z, kind), F4(Float(count), snowBox.x, snowBox.y, gain))
        enc.setVertexBytes(&w, length: MemoryLayout<F4>.stride * 2, index: BufferIndex.instances)
        renderer.drawQuads(enc, count)
    }
}
