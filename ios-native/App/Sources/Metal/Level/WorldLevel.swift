import Foundation
import Metal
import IceHiveCore

// ================================================================
//  WORLD LEVEL — the station (owned by WP6 «Станция и конвейер»): the
//  static level meshes (floors with the snow mask, merged props, the
//  lift deck and its props riding up during the extraction, hazard
//  strips, the landing-pad mark, the unlit floor light pools) and the
//  dynamic props (globs, grenades, medkits, the turret, beacon tips)
//  as mesh batches (MetalRenderer's batch service). Shaders:
//  Level.metal (fs_props also shades the squad's batches).
// ================================================================
final class WorldLevel {
    static let pipelines: [PipelineSpec] = [
        .world("props", "vs_static", "fs_props", .none, .ihm1, required: true),
        .world("floor", "vs_static", "fs_floor", .none, .ihm1, required: true),
        .world("hazard", "vs_static", "fs_textured", .none, .ihm1), .world("pad", "vs_static", "fs_textured", .alpha, .ihm1),
        .world("glowQuads", "vs_static", "fs_basic_textured", .add, .ihm1),
    ]

    let level: Level
    private var renderer: MetalRenderer!
    private let matProps = MaterialUniforms(pbr: F4(0.62, 0.45, 1, 2.2), floor: F4(0, 0, 0, 1))
    // static level meshes and their materials
    private var levelDraws: [(GPUMesh, MaterialUniforms, Int)] = []   // kind: 0 props, 1 floor grating, 2 floor slab, 3 lift floor, 4 lift props
    private var meshHazard: GPUMesh!, meshPad: GPUMesh!, meshGlow: GPUMesh!
    private var texGrating: MTLTexture!, texSlab: MTLTexture!, texHazard: MTLTexture!, texPad: MTLTexture!, texGlow: MTLTexture!
    private var psProps: MTLRenderPipelineState?, psFloor: MTLRenderPipelineState?, psHazard: MTLRenderPipelineState?
    private var psPad: MTLRenderPipelineState?, psGlowQuads: MTLRenderPipelineState?
    // dynamic props (mesh batches)
    private let turretBase: MeshBatch, turretHead: MeshBatch, medkit: MeshBatch
    private let glob: MeshBatch, grenade: MeshBatch, beaconTop: MeshBatch
    private let propBatches: [MeshBatch]
    /// The lift deck's rise this frame (the extraction).
    private var liftRise: Float = 0

    init(level: Level, store: MeshStore) {
        self.level = level
        func b(_ n: String, _ pass: MeshPass, snow: Bool = true) -> MeshBatch {
            MeshBatch(mesh: store.mesh(n), pass: pass, roughness: 0.62, metalness: 0.45, glow: 2.2, snow: snow, castsShadow: false,
                      receivesShadow: false)
        }
        turretBase = b("turret_base", .props)
        turretHead = b("turret_head", .props)
        medkit = b("medkit", .props)
        glob = b("glob", .unlit, snow: false)
        grenade = b("grenade", .unlit, snow: false)
        beaconTop = b("beacon_top", .unlit, snow: false)
        propBatches = [turretBase, turretHead, medkit, glob, grenade, beaconTop]
    }

    /// Meshes, textures, pipelines; the snow mask for the whole world pass; register the level's items (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        let store = r.store
        // static level: floors (grating / slab + snow mask), merged props, the lift deck and its props (they rise)
        func floorMat(_ bias: Float) -> MaterialUniforms { MaterialUniforms(pbr: F4(0.72, 0.42, 0, 0), floor: F4(bias, 1, 0, 1)) }
        levelDraws = [
            (store.mesh("level_floor_grating"), floorMat(0), 1),
            (store.mesh("level_floor_slab"), floorMat(0.18), 2),
            (store.mesh("lift_floor"), floorMat(0), 3),
            (store.mesh("level_props"), matProps, 0),
            (store.mesh("lift_props"), matProps, 4),
        ]
        meshHazard = store.mesh("level_hazard"); meshPad = store.mesh("level_pad_mark"); meshGlow = store.mesh("level_glow")
        texGrating = store.texture("grating"); texSlab = store.texture("slab"); texHazard = store.texture("hazard")
        texPad = store.texture("pad"); texGlow = store.texture("glow")
        r.passTextures[TextureIndex.snow] = store.texture("snow")
        psProps = r.pipeline("props"); psFloor = r.pipeline("floor"); psHazard = r.pipeline("hazard")
        psPad = r.pipeline("pad"); psGlowQuads = r.pipeline("glowQuads")
        r.register(.opaque, order: 100, "floors") { [unowned self] enc in self.encodeFloors(enc) }
        r.register(.opaque, order: 110, "level props") { [unowned self] enc in self.encodeProps(enc) }
        r.register(.opaque, order: 120, "hazard strips") { [unowned self] enc in self.encodeHazard(enc) }
        r.register(.transparent, order: 110, "pad mark") { [unowned self] enc in self.encodePad(enc) }
        r.register(.transparent, order: 120, "floor glows") { [unowned self] enc in self.encodeGlows(enc) }
    }

    // ---------------------------------------------------------------- props (globs, grenades, medkits, turret, beacon tips)
    /// This frame's dynamic props (glob and grenade trails emit into `fx`).
    func build(game: Game, time: Float, dt: Float, rise: Float, fx: MetalEffects) {
        liftRise = rise
        for b in propBatches { b.instances.removeAll(keepingCapacity: true) }
        let one = F4(1, 1, 1, 0), none = F4(0, 0, 0, 0)
        let G = game.globs
        for k in 0..<G.count {
            let u = G.progress(k), a = G.from(k), b = G.to(k)
            let gx = a.x + (b.x - a.x) * u, gz = a.y + (b.y - a.y) * u
            let gy = level.groundY(a.x, a.y) + (level.groundY(b.x, b.y) - level.groundY(a.x, a.y)) * u + 0.6 + sinf(u * Float.pi) * 3.2
            glob.instances.append(MeshInstance(model: Mat4.translation(gx, gy, gz), tint: one, emissive: none))
            if dt > 0 && Float.random(in: 0..<1) < 0.5 { fx.pa.emit(gx, gy, gz, 0, 0, 0, 0.25, 0.3, 0.05, 0.6, 1, 0.15, 0.8, 1, 0, 0, absolute: true) }
        }
        for g in game.grenades where g.active {
            let u = g.progress
            let x = g.sx + (g.tx - g.sx) * u, z = g.sz + (g.tz - g.sz) * u
            let y = level.groundY(g.sx, g.sz) + (level.groundY(g.tx, g.tz) - level.groundY(g.sx, g.sz)) * u + 1.2 + sinf(u * Float.pi) * (g.big ? 3 : 1.2) - u
            grenade.instances.append(MeshInstance(model: Mat4.translation(x, y, z) * Mat4.scale(g.big ? 1 : 0.7), tint: one, emissive: none))
            if dt > 0 { fx.pa.emit(x, y, z, 0, 0, 0, 0.12, 0.25, 0.05, 1, 0.7, 0.3, 0.7, 0, 0, 0, absolute: true) }
        }
        for m in game.medkits where m.active && (m.t > 5 || sinf(time * 14) > 0) {
            let y = level.groundY(m.x, m.z) + 0.12 + sinf(time * 3 + m.x) * 0.06
            medkit.instances.append(MeshInstance(model: Mat4.translation(m.x, y, m.z) * Mat4.rotationY(time * 1.5), tint: one, emissive: none))
        }
        let T = game.turret
        if T.active {
            let ty = level.groundY(T.x, T.z)
            turretBase.instances.append(MeshInstance(model: Mat4.translation(T.x, ty, T.z), tint: one, emissive: none))
            turretHead.instances.append(MeshInstance(model: Mat4.translation(T.x, ty + 0.95, T.z) * Mat4.rotationY(T.angle), tint: one, emissive: none))
        }
        for (k, b) in game.beacons.enumerated() {
            let gy = level.groundY(b.x, b.z)
            let col: F3 = b.state == 2 ? F3(0.25, 1.0, 0.85) : (b.state == 1 ? F3(1.0, 0.7, 0.15) : F3(1.0, 0.25, 0.15))
            let m = Mat4.translation(b.x, gy + 2.9 + sinf(time * 2 + Float(k)) * 0.12, b.z) * Mat4.rotationY(time * (b.state == 1 ? 4 : 1.2))
            beaconTop.instances.append(MeshInstance(model: m, tint: F4(col.x * 1.6, col.y * 1.6, col.z * 1.6, 0), emissive: F4(0, 0, 0, 1)))
        }
    }

    /// The dynamic props into the batch service.
    func upload(_ r: MetalRenderer) {
        for b in propBatches where !b.instances.isEmpty {
            b.region = r.upload(b.instances)
            r.list.batches.append(b)
        }
    }

    // ---------------------------------------------------------------- static level draws
    /// Opaque item 100: the floors (one pipeline; the lift deck rises).
    private func encodeFloors(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psFloor else { return }
        let r = renderer!
        r.use(enc, ps)
        for (mesh, mat0, kind) in levelDraws where kind >= 1 && kind <= 3 {
            var mat = mat0
            if kind == 3 { mat.floor.z = liftRise }
            r.bindMain(enc, kind == 2 ? texSlab : texGrating)
            r.drawStatic(enc, mesh, &mat)
        }
    }

    /// Opaque item 110: the merged level props and the lift's props.
    private func encodeProps(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psProps else { return }
        let r = renderer!
        r.use(enc, ps)
        for (mesh, mat0, kind) in levelDraws where kind == 0 || kind == 4 {
            var mat = mat0
            if kind == 4 { mat.floor.z = liftRise }
            r.drawStatic(enc, mesh, &mat)
        }
    }

    /// Opaque item 120: hazard strips just above the floor.
    private func encodeHazard(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psHazard else { return }
        let r = renderer!
        r.use(enc, ps)
        r.bindMain(enc, texHazard)
        var mat = MaterialUniforms(pbr: F4(0.8, 0.1, 0, 0), floor: F4(0, 0, 0, 1))
        enc.setDepthBias(-1, slopeScale: -1, clamp: 0)
        r.drawStatic(enc, meshHazard, &mat)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    /// Transparent item 110: the landing-pad mark (alpha).
    private func encodePad(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psPad else { return }
        let r = renderer!
        r.use(enc, ps)
        r.bindMain(enc, texPad)
        var mat = MaterialUniforms(pbr: F4(0.85, 0, 0, 0), floor: .zero)
        enc.setDepthBias(-2, slopeScale: -2, clamp: 0)
        r.drawStatic(enc, meshPad, &mat)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    /// Transparent item 120: the unlit floor light pools (additive).
    private func encodeGlows(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psGlowQuads else { return }
        let r = renderer!
        r.use(enc, ps)
        r.bindMain(enc, texGlow)
        var mat = MaterialUniforms(pbr: .zero, floor: .zero)
        r.drawStatic(enc, meshGlow, &mat)
    }
}
