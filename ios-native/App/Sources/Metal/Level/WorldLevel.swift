import Foundation
import Metal
import IceHiveCore

// ================================================================
//  WORLD LEVEL — the station (owned by WP6 «Станция и конвейер»).
//  Built once per Level from its layout (LevelLayout: rects, crates,
//  pillars, vents, pipes, beacons, lift — so a generated station gets
//  the same kit) out of KitStore's pieces and runtime extrusions, in
//  the user's blend of the concepts:
//    crisp «Кристалл»  bevelled hard surface, dark steel; a cyan light
//                      strip in the skirt groove outlines every abyss
//                      edge (only the walkable edge); one light colour
//                      per element (teal pillars / lamps, amber pad /
//                      beacon, orange vents, red warning lamps)
//    horror            deep darkness: dark steel, low metalness so the
//                      squad's flashlights (and WP2's grid lights from
//                      the lamps this module registers) are the light
//    frost             rime on grating bars and rims near the edges
//                      (world mask × trim receptivity, subtle), icicle
//                      fringes under the deck lips, LOW drifts inside
//                      the railings only (never past the rail line)
//  The deck stays dark (no snow fill: frost's silver deck is out).
//  Geometry: one KitMesh per 32 m cell of the XZ plane (frustum-culled
//  chunks of one vertex / index buffer, fs_level, one pipeline); the
//  visible chunks are drawn as a few contiguous index ranges (a small
//  hidden chunk between two visible ones is drawn with them rather
//  than split into another draw call); the lift deck is its own chunk
//  raised by the extraction rise; the beacon heads are in the buffer
//  too (vs_kit spins them, lens in the state colour). Dynamic props
//  (globs, grenades, medkits, the turret) stay IHM1 mesh batches.
//  Transparent: the landing-pad mark and the floor light pools.
// ================================================================

/// fs_level / vs_kit constants (`struct LevelParams` in Level.metal).
struct LevelParams {
    /// x = vertical offset of the draw (lift rise).
    var lift = F4(0, 0, 0, 0)
    /// x rime strength, y contact-AO strength, z chamfer wear, w snow albedo.
    var look = F4(1, 0.65, 0.55, 0.5)
    /// x = 1 on the High tier (wet trails, ice rim, grid-light specular).
    var misc = F4(0, 0, 0, 0)
    /// World mask: xy world origin, z 1 / size (m).
    var mask = F4(-GRID_HALF, -GRID_HALF, 1 / (2 * GRID_HALF), 0)
}

final class WorldLevel {
    static let pipelines: [PipelineSpec] = [
        .world("level", "vs_kit", "fs_level", .none, nil, required: true),
        .depthOnly("shadowKit", "vs_shadow_kit"),
        .world("pad", "vs_static", "fs_textured", .alpha, .ihm1),
        .world("glowQuads", "vs_static", "fs_basic_textured", .add, .ihm1),
    ]
    /// Fragment texture slots of fs_level (above the pass-wide ones).
    enum Slot {
        static let trimNormal = 8, trimORM = 9, ao = 10
    }
    /// Culling cell (m).
    static let chunkSize: Float = 32
    /// Hidden chunks between two visible ones are drawn with them (one draw call) below this many triangles.
    static let mergeGapTriangles = 6000
    /// Beacon heads vs_kit can spin (Level.metal LEVEL_HEADS).
    static let maxHeads = 8

    let level: Level
    private var renderer: MetalRenderer!
    private var kit: KitStore!
    // merged station
    private struct Chunk {
        let start: Int; let count: Int; let lo: F3; let hi: F3; let lift: Bool
        /// The chunk's shadow casters in `cbuf` (same chunk order).
        let casterStart: Int; let casterCount: Int
    }
    private var chunks: [Chunk] = []
    private var vbuf: MTLBuffer?, ibuf: MTLBuffer?, cbuf: MTLBuffer?
    private var psShadow: MTLRenderPipelineState?
    /// Casters are drawn for chunks within this margin (m) of the camera frustum (a crate just off screen still throws
    /// its shadow into view).
    static let casterMargin: Float = 8
    private var glowV: MTLBuffer?, glowI: MTLBuffer?, glowCount = 0
    private var padV: MTLBuffer?, padI: MTLBuffer?
    private var worldMask: MTLTexture?
    private var texPad: MTLTexture!, texGlow: MTLTexture!
    private var psLevel: MTLRenderPipelineState?
    private var psPad: MTLRenderPipelineState?, psGlowQuads: MTLRenderPipelineState?
    var params = LevelParams()
    // dynamic props (mesh batches) and the beacon heads
    private let turretBase: MeshBatch, turretHead: MeshBatch, medkit: MeshBatch
    private let glob: MeshBatch, grenade: MeshBatch
    private let propBatches: [MeshBatch]
    /// vs_kit's head table (Level.metal LevelHeads): pivot + yaw ×8, then the lens colours ×8.
    private var headTable = [F4](repeating: F4(0, 0, 0, 0), count: 2 * WorldLevel.maxHeads)
    /// The lift deck's rise this frame (the extraction).
    private var liftRise: Float = 0
    /// Built station: vertices / triangles / chunks / build ms (log).
    private(set) var summary = ""
    /// Draw calls of the station in the last frame (runs of visible chunks + the lift).
    private(set) var stationDraws = 0
    /// The station's fixed light sources as built (for LightGrid's grid lights, WP2): lamp lenses, pillar strips, vent
    /// slats and beacon heads — world position (m) and linear colour (× nominal intensity 1).
    struct StationLight { let kind: Kind; let pos: F3; let color: F3; enum Kind { case lamp, pillar, vent, beacon } }
    private(set) var lights: [StationLight] = []

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
        propBatches = [turretBase, turretHead, medkit, glob, grenade]
    }

    /// Kit, pipelines, the station geometry, the world mask; register the level's items (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        kit = r.store.kit
        texPad = r.store.texture("pad")
        texGlow = r.store.texture("glow")
        psLevel = r.pipeline("level")
        psShadow = r.pipeline("shadowKit")
        psPad = r.pipeline("pad")
        psGlowQuads = r.pipeline("glowQuads")
        let t0 = FrameTimer.now()
        worldMask = buildWorldMask(r.device)
        r.passTextures[TextureIndex.snow] = worldMask
        if kit.ready {
            buildStation(r.device)
            // WP2's grid lights: the station's lamp lenses, pillar strips and vent slats (the beacons: LightGrid's own)
            LightingHub.current?.setStationLamps(lights.filter { $0.kind != .beacon }.map { ($0.pos, $0.color) })
        } else {
            summary = "station: kit not loaded — nothing to draw"
        }
        summary += String(format: " (%.0f ms)", (FrameTimer.now() - t0) * 1000)
        AppLog.info("metal: " + summary)
        r.register(.opaque, order: 100, "station") { [unowned self] enc in self.encodeStation(enc) }
        r.register(.shadowCasters, order: 50, "station casters") { [unowned self] enc in self.encodeCasters(enc) }
        r.register(.transparent, order: 110, "pad mark") { [unowned self] enc in self.encodePad(enc) }
        r.register(.transparent, order: 120, "floor glows") { [unowned self] enc in self.encodeGlows(enc) }
    }

    // ================================================================ per frame
    /// This frame's dynamic props (glob and grenade trails emit into `fx`) and the beacon heads.
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
        // beacon heads: on the mast top, rotating, lens in the state colour (idle red, charging amber, done teal)
        for (k, b) in game.beacons.enumerated() where k < WorldLevel.maxHeads {
            let gy = level.groundY(b.x, b.z)
            let col: F3 = b.state == 2 ? linearRGB(0x2af5e0) : (b.state == 1 ? linearRGB(0xffa21a) : linearRGB(0xff2a3a))
            headTable[k] = F4(b.x, gy + WorldLevel.mastTop, b.z, time * (b.state == 1 ? 4 : 1.2) + Float(k))
            headTable[WorldLevel.maxHeads + k] = F4(col.x, col.y, col.z, 0)
        }
    }

    /// The dynamic props into the batch service.
    func upload(_ r: MetalRenderer) {
        for b in propBatches where !b.instances.isEmpty {
            b.region = r.upload(b.instances)
            r.list.batches.append(b)
        }
    }

    // ================================================================ draw items
    private func bindLevel(_ enc: MTLRenderCommandEncoder) {
        enc.setFragmentTexture(kit.trimNormal, index: Slot.trimNormal)
        enc.setFragmentTexture(kit.trimORM, index: Slot.trimORM)
        enc.setFragmentTexture(kit.aoAtlas, index: Slot.ao)
    }

    /// Opaque item 100: the visible chunks of the station as a few contiguous index ranges, then the lift (raised by
    /// the extraction).
    private func encodeStation(_ enc: MTLRenderCommandEncoder) {
        let r = renderer!
        stationDraws = 0
        guard let ps = psLevel, let vb = vbuf, let ib = ibuf, !chunks.isEmpty else { return }
        r.use(enc, ps)
        bindLevel(enc)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        headTable.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: BufferIndex.instances) }
        let planes = WorldLevel.frustumPlanes(r.frame.viewProj)
        var p = params
        p.misc.x = r.frameTier == .high ? 1 : 0
        p.lift.x = 0
        enc.setVertexBytes(&p, length: MemoryLayout<LevelParams>.stride, index: BufferIndex.material)
        enc.setFragmentBytes(&p, length: MemoryLayout<LevelParams>.stride, index: BufferIndex.material)
        for (start, count) in WorldLevel.drawRuns(chunks.lazy.filter { !$0.lift }.map {
            (start: $0.start, count: $0.count, visible: WorldLevel.visible(planes, $0.lo, $0.hi))
        }, mergeGap: WorldLevel.mergeGapTriangles * 3) {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: start * 4)
            r.count(triangles: count / 3)
            stationDraws += 1
        }
        for c in chunks where c.lift {
            let rise = liftRise
            if !WorldLevel.visible(planes, c.lo + F3(0, rise, 0), c.hi + F3(0, rise, 0)) { continue }
            p.lift.x = rise
            enc.setVertexBytes(&p, length: MemoryLayout<LevelParams>.stride, index: BufferIndex.material)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: c.count, indexType: .uint32, indexBuffer: ib,
                                      indexBufferOffset: c.start * 4)
            r.count(triangles: c.count / 3)
            stationDraws += 1
        }
    }

    /// Shadow-caster item: the casters (crates, pillars, beacon masts, lamp posts) of the chunks near the view, into the
    /// spot tile the pass has bound (its matrix is F.shadowMatrix); a slope-scaled bias keeps their lit tops clean.
    private func encodeCasters(_ enc: MTLRenderCommandEncoder) {
        let r = renderer!
        guard let ps = psShadow, let vb = vbuf, let cb = cbuf else { return }
        let planes = WorldLevel.frustumPlanes(r.frame.viewProj)
        let m = F3(repeating: WorldLevel.casterMargin)
        let runs = WorldLevel.drawRuns(chunks.lazy.filter { !$0.lift && $0.casterCount > 0 }.map {
            (start: $0.casterStart, count: $0.casterCount, visible: WorldLevel.visible(planes, $0.lo - m, $0.hi + m))
        }, mergeGap: 1500 * 3)
        if runs.isEmpty { return }
        enc.setRenderPipelineState(ps)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        enc.setDepthBias(0, slopeScale: 1.5, clamp: 0.002)
        for (start, count) in runs {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: cb, indexBufferOffset: start * 4)
            r.count(triangles: count / 3)
        }
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    /// Contiguous index ranges to draw for chunks laid out back to back in the index buffer (in order): runs of
    /// visible chunks, a hidden stretch inside a run kept when it has at most `mergeGap` indices (cheaper than another
    /// draw call: the GPU clips it).
    static func drawRuns<S: Sequence>(_ chunks: S, mergeGap: Int) -> [(Int, Int)] where S.Element == (start: Int, count: Int, visible: Bool) {
        var out: [(Int, Int)] = []
        var runStart = -1, runEnd = 0, gap = 0
        for c in chunks {
            if c.visible {
                if runStart >= 0 && gap <= mergeGap && c.start == runEnd + gap {
                    runEnd = c.start + c.count
                } else {
                    if runStart >= 0 { out.append((runStart, runEnd - runStart)) }
                    runStart = c.start
                    runEnd = c.start + c.count
                }
                gap = 0
            } else if runStart >= 0 {
                gap += c.count
            }
        }
        if runStart >= 0 { out.append((runStart, runEnd - runStart)) }
        return out
    }

    /// Transparent item 110: the landing-pad mark (alpha).
    private func encodePad(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psPad, let vb = padV, let ib = padI else { return }
        let r = renderer!
        r.use(enc, ps)
        r.bindMain(enc, texPad)
        var mat = MaterialUniforms(pbr: F4(0.85, 0, 0, 0), floor: .zero)
        enc.setDepthBias(-2, slopeScale: -2, clamp: 0)
        enc.setVertexBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
        r.count(triangles: 2)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    /// Transparent item 120: the unlit floor light pools (additive).
    private func encodeGlows(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psGlowQuads, let vb = glowV, let ib = glowI, glowCount > 0 else { return }
        let r = renderer!
        r.use(enc, ps)
        r.bindMain(enc, texGlow)
        var mat = MaterialUniforms(pbr: .zero, floor: .zero)
        enc.setVertexBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: glowCount * 6, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
        r.count(triangles: glowCount * 2)
    }

    // ================================================================ culling
    static func frustumPlanes(_ m: Mat4) -> [F4] {
        let r0 = F4(m.c0.x, m.c1.x, m.c2.x, m.c3.x), r1 = F4(m.c0.y, m.c1.y, m.c2.y, m.c3.y)
        let r2 = F4(m.c0.z, m.c1.z, m.c2.z, m.c3.z), r3 = F4(m.c0.w, m.c1.w, m.c2.w, m.c3.w)
        return [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
    }

    static func visible(_ planes: [F4], _ lo: F3, _ hi: F3) -> Bool {
        for p in planes {
            let x = p.x >= 0 ? hi.x : lo.x, y = p.y >= 0 ? hi.y : lo.y, z = p.z >= 0 ? hi.z : lo.z
            if p.x * x + p.y * y + p.z * z + p.w < 0 { return false }
        }
        return true
    }

    // ================================================================ station assembly
    /// Height of the beacon mast's top deck (the head sits there).
    static let mastTop: Float = 3.46

    // palette (sRGB), kitgeo.py C
    private enum Col {
        static let steel: UInt32 = 0x46515c, steelD: UInt32 = 0x29313a, steelL: UInt32 = 0x6a7784, rail: UInt32 = 0x73808c
        static let girder: UInt32 = 0x1f262e, support: UInt32 = 0x1a2129, deck: UInt32 = 0x3d4651, plate: UInt32 = 0x434c57
        static let teal: UInt32 = 0x2af5e0, cyan: UInt32 = 0x38d8ff, amber: UInt32 = 0xffa21a, red: UInt32 = 0xff2a3a
        static let green: UInt32 = 0x3dff9a, orange: UInt32 = 0xff5a1a, dark: UInt32 = 0x0d1115, nosing: UInt32 = 0x8d99a6
        static let crate: [UInt32] = [0x6f7d58, 0x4f6b92, 0x9a6530]
        static let tower: UInt32 = 0x10161d
    }

    private var cells: [Int: KitMesh] = [:]
    private var edgeStats = (posts: 0, icicles: 0, drifts: 0, lamps: 0)
    private var liftMesh = KitMesh()
    private var glowQuads: [(F3, Float, UInt32, Float)] = []    // centre, size, colour, strength

    private func cell(_ x: Float, _ z: Float) -> KitMesh {
        let n = Int(256 / WorldLevel.chunkSize)
        let i = max(0, min(n - 1, Int(((x + 128) / WorldLevel.chunkSize).rounded(.down))))
        let j = max(0, min(n - 1, Int(((z + 128) / WorldLevel.chunkSize).rounded(.down))))
        let key = j * n + i
        if let m = cells[key] { return m }
        let m = KitMesh(reserve: 4096)
        cells[key] = m
        return m
    }

    private func piece(_ name: String) -> KitPiece? { kit.pieces[name] }

    private func buildStation(_ device: MTLDevice) {
        cells.removeAll()
        liftMesh = KitMesh(reserve: 8192)
        glowQuads.removeAll()
        lights.removeAll()
        let t0 = FrameTimer.now()
        func tris() -> Int { cells.values.reduce(liftMesh.triangles) { $0 + $1.triangles } }
        var parts: [(String, Int)] = []
        func step(_ name: String, _ f: () -> Void) { let a = tris(); f(); parts.append((name, tris() - a)) }
        step("decks") { buildDecks() }
        step("edges") { buildEdges(); buildCornerDrifts() }
        step("supports") { buildSupports() }
        step("props") { buildProps() }
        step("lift") { buildLift() }
        let tBuild = (FrameTimer.now() - t0) * 1000
        // one vertex / index stream: the cells (sorted), then the lift
        var verts: [KitVertex] = []
        var idx: [UInt32] = []
        var cidx: [UInt32] = []
        let total = cells.values.reduce(liftMesh.vertices.count) { $0 + $1.vertices.count }
        verts.reserveCapacity(total)
        idx.reserveCapacity(cells.values.reduce(liftMesh.indices.count) { $0 + $1.indices.count })
        chunks.removeAll()
        func append(_ m: KitMesh, lift: Bool) {
            guard !m.isEmpty else { return }
            let base = UInt32(verts.count)
            let start = idx.count, cstart = cidx.count
            verts += m.vertices
            for i in m.indices { idx.append(base + i) }
            for i in m.casterIndices { cidx.append(base + i) }
            chunks.append(Chunk(start: start, count: m.indices.count, lo: m.lo, hi: m.hi, lift: lift, casterStart: cstart,
                                casterCount: m.casterIndices.count))
        }
        for k in cells.keys.sorted() { append(cells[k]!, lift: false) }
        append(liftMesh, lift: true)
        vbuf = verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count), options: []) }
        ibuf = idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(16, $0.count), options: []) }
        cbuf = cidx.isEmpty ? nil : cidx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
        vbuf?.label = "station.v"
        ibuf?.label = "station.i"
        cbuf?.label = "station.casters"
        buildGlowQuads(device)
        buildPadQuad(device)
        cells.removeAll()
        let mb = Double(verts.count * MemoryLayout<KitVertex>.stride + (idx.count + cidx.count) * 4) / 1_048_576
        summary = String(format: "station: %d vertices, %d triangles in %d chunks (%.1f MB; assembled in %.0f ms) glows %d",
                         verts.count, idx.count / 3, chunks.count, mb, tBuild, glowCount)
            + String(format: " | casters %d triangles", cidx.count / 3)
            + " | triangles " + parts.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            + " | edges: \(edgeStats.posts) posts, \(edgeStats.icicles) icicle fringes, \(edgeStats.drifts) drifts, \(edgeStats.lamps) lamps"
        liftMesh = KitMesh()
    }

    // ---------------------------------------------------------------- decks
    private func deckMat(_ kind: FloorKind) -> KitMat {
        // painted / galvanised steel: low metalness (× the trim's metal mask) so the flashlight pools read as light on
        // the deck, not as a dark mirror
        kind == .slab ? KitMat(tint: Col.plate, metal: 0.35, layer: Trim.panels, flags: KitFlag.frost)
            : KitMat(tint: Col.deck, metal: 0.5, layer: Trim.gratings, flags: KitFlag.frost)
    }

    /// Top quad x0..x1 × z0..z1 at height y (counter-clockwise seen from above).
    private func top(_ m: KitMesh, _ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float, _ y: Float, _ mat: KitMat) {
        m.face([F3(x0, y, z0), F3(x0, y, z1), F3(x1, y, z1), F3(x1, y, z0)], mat)
    }

    private func buildDecks() {
        let stepD = level.layout.stepDepth
        for r in level.layout.rects {
            let mat = deckMat(r.kind)
            switch r.height {
            case .flat(let h):
                // split big decks per chunk cell so culling stays effective
                var x = r.x0
                while x < r.x1 {
                    let xn = min(r.x1, (((x + 128) / WorldLevel.chunkSize).rounded(.down) + 1) * WorldLevel.chunkSize - 128)
                    var z = r.z0
                    while z < r.z1 {
                        let zn = min(r.z1, (((z + 128) / WorldLevel.chunkSize).rounded(.down) + 1) * WorldLevel.chunkSize - 128)
                        top(cell((x + xn) / 2, (z + zn) / 2), x, z, xn, zn, h, mat)
                        z = zn
                    }
                    x = xn
                }
            case .ramp(let a, let ha, let b, let hb, let stairs):
                let m = cell((r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2)
                if a > r.z0 { top(m, r.x0, r.z0, r.x1, a, ha, mat) }
                if b < r.z1 { top(m, r.x0, b, r.x1, r.z1, hb, mat) }
                if stairs {
                    let n = max(1, Int(((b - a) / stepD).rounded()))
                    let bot = min(ha, hb) - 0.5
                    let tread = KitMat(tint: Col.plate, metal: 0.35, layer: Trim.panels, flags: KitFlag.frost)
                    let side = KitMat(tint: Col.steelD, metal: 0.7, layer: Trim.panels)
                    for s in 0..<n {
                        let za = a + Float(s) * stepD, zb = za + stepD
                        let tp = ha + (hb - ha) * (Float(s) + 0.5) / Float(n)
                        let mm = cell((r.x0 + r.x1) / 2, (za + zb) / 2)
                        top(mm, r.x0, za, r.x1, zb, tp, tread)
                        // risers (front and back) and sides, down to the stair's bottom
                        mm.face([F3(r.x0, bot, za), F3(r.x0, tp, za), F3(r.x1, tp, za), F3(r.x1, bot, za)], side)
                        mm.face([F3(r.x1, bot, zb), F3(r.x1, tp, zb), F3(r.x0, tp, zb), F3(r.x0, bot, zb)], side)
                        mm.face([F3(r.x0, bot, zb), F3(r.x0, tp, zb), F3(r.x0, tp, za), F3(r.x0, bot, za)], side)
                        mm.face([F3(r.x1, bot, za), F3(r.x1, tp, za), F3(r.x1, tp, zb), F3(r.x1, bot, zb)], side)
                        // nosing: pale edge on every tread, amber on the first and the last
                        let edge = s == 0 || s == n - 1
                        let zN = hb > ha ? zb - 0.06 : za + 0.06
                        mm.beam(F3(r.x0 + 0.15, tp + 0.012, zN), F3(r.x1 - 0.15, tp + 0.012, zN), w: 0.1, h: 0.03, c: 0.01,
                                KitMat(tint: edge ? Col.amber : Col.nosing, metal: 0.4, emis: edge ? 1.6 : 0.25, layer: Trim.rails,
                                       uv: .strip(Trim.nosing, F3(1, 0, 0))), bottom: false)
                    }
                    // stringers with a thin cyan strip, both sides
                    for sx in [r.x0 - 0.12, r.x1 + 0.12] {
                        m.beam(F3(sx, ha - 0.25, a), F3(sx, hb - 0.25, b), w: 0.22, h: 0.6, c: 0.04,
                               KitMat(tint: Col.steelD, metal: 0.75, layer: Trim.rails, uv: .strip(Trim.girder, F3(0, 0, 1))))
                        let o: Float = sx < r.x0 ? -0.115 : 0.115
                        m.beam(F3(sx + o, ha - 0.1, a), F3(sx + o, hb - 0.1, b), w: 0.02, h: 0.04, c: 0,
                               KitMat(tint: Col.cyan, metal: 0, emis: 2.4, layer: Trim.none, flags: KitFlag.strip, uv: .none))
                    }
                } else {
                    // sloped catwalk: sloped top, side walls, a centre girder
                    m.face([F3(r.x0, ha, a), F3(r.x0, hb, b), F3(r.x1, hb, b), F3(r.x1, ha, a)], mat)
                    let side = KitMat(tint: Col.steelD, metal: 0.75, layer: Trim.rails, uv: .strip(Trim.skirt, F3(0, 0, 1)))
                    m.face(orient([F3(r.x0, ha - 0.5, a), F3(r.x0, hb - 0.5, b), F3(r.x0, hb, b), F3(r.x0, ha, a)], up: F3(-1, 0, 0)), side)
                    m.face(orient([F3(r.x1, ha - 0.5, a), F3(r.x1, hb - 0.5, b), F3(r.x1, hb, b), F3(r.x1, ha, a)], up: F3(1, 0, 0)), side)
                    m.beam(F3((r.x0 + r.x1) / 2, ha - 0.3, a), F3((r.x0 + r.x1) / 2, hb - 0.3, b), w: r.x1 - r.x0 - 0.3, h: 0.5, c: 0.04,
                           KitMat(tint: Col.girder, metal: 0.6, layer: Trim.rails, uv: .strip(Trim.girder, F3(0, 0, 1))))
                }
            }
        }
    }

    // ---------------------------------------------------------------- abyss edges: lips, skirts, strips, rails, girders
    private struct Run { let horiz: Bool; let a: Float; let b: Float; let line: Float; let inward: Float; let haz: Bool }

    /// The web's railing runs: abyss-adjacent floor cell sides merged per line (the lift ring has its own rail).
    private func runs() -> [Run] {
        let G = GRID
        var h: [String: [(Int, Float, Float, Bool)]] = [:], v: [String: [(Int, Float, Float, Bool)]] = [:]
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if level.walkValue(c) == 0 || level.isLiftCell(c) { continue }
                let x = Float(i) - GRID_HALF, z = Float(j) - GRID_HALF
                let haz = level.isHazardCell(c)
                if level.walkValue(c - G) == 0 { h["n\(j)", default: []].append((i, z + 0.12, 1, haz)) }
                if level.walkValue(c + G) == 0 { h["s\(j)", default: []].append((i, z + 1 - 0.12, -1, haz)) }
                if level.walkValue(c - 1) == 0 { v["w\(i)", default: []].append((j, x + 0.12, 1, haz)) }
                if level.walkValue(c + 1) == 0 { v["e\(i)", default: []].append((j, x + 1 - 0.12, -1, haz)) }
            }
        }
        var out: [Run] = []
        for (map, horiz) in [(h, true), (v, false)] {
            for key in map.keys.sorted() {
                let segs = map[key]!.sorted { $0.0 < $1.0 }
                var s0 = segs[0].0, prev = s0
                for k in 1...segs.count {
                    if k < segs.count && segs[k].0 == prev + 1 { prev = segs[k].0; continue }
                    let last = segs[k - 1]
                    out.append(Run(horiz: horiz, a: Float(s0) - GRID_HALF, b: Float(prev + 1) - GRID_HALF, line: last.1, inward: last.2, haz: last.3))
                    if k < segs.count { s0 = segs[k].0; prev = s0 }
                }
            }
        }
        return out
    }

    private func buildEdges() {
        var rng = StationRNG(seed: 31)
        var lampN = 0
        edgeStats = (0, 0, 0, 0)
        let railMat = KitMat(tint: Col.rail, metal: 0.7, layer: Trim.rails, uv: .strip(Trim.railbar, F3(1, 0, 0)))
        let kickMat = KitMat(tint: Col.steelD, metal: 0.7, layer: Trim.rails, uv: .strip(Trim.chequer, F3(1, 0, 0)))
        let lipMat = KitMat(tint: Col.steelL, metal: 0.55, layer: Trim.rails, flags: KitFlag.chamfer | KitFlag.frost,
                            uv: .strip(Trim.brushed, F3(1, 0, 0)))
        let skirtMat = KitMat(tint: Col.steelD, metal: 0.75, layer: Trim.rails, uv: .strip(Trim.skirt, F3(1, 0, 0)))
        let underMat = KitMat(tint: Col.girder, metal: 0.6, layer: Trim.rails, uv: .strip(Trim.brushed, F3(1, 0, 0)))
        let stripMat = KitMat(tint: Col.cyan, metal: 0, emis: 3.0, layer: Trim.none, flags: KitFlag.strip, uv: .none)
        let girderMat = KitMat(tint: Col.girder, metal: 0.7, layer: Trim.rails, uv: .strip(Trim.girder, F3(1, 0, 0)))
        let hazMat = KitMat(tint: Col.amber, metal: 0.1, layer: Trim.rails, flags: KitFlag.hazard, uv: .strip(Trim.hazard, F3(1, 0, 0)))
        let icicles = ["icicles_a", "icicles_b", "icicles_c"].compactMap { piece($0) }
        let drifts = ["drift_a", "drift_b", "drift_c"].compactMap { piece($0) }
        let post = piece("rail_post"), lamp = piece("lamp_post")
        for r in runs() {
            let len = r.b - r.a
            // point along the run at t, `off` metres inward from the rail line
            func P(_ t: Float, _ off: Float = 0) -> (Float, Float) {
                r.horiz ? (r.a + t, r.line + off * r.inward) : (r.line + off * r.inward, r.a + t)
            }
            func H(_ t: Float) -> Float {
                let (x, z) = P(clampf(t, 0.02, len - 0.02), 0.3)
                return level.groundY(x, z)
            }
            let dir = r.horiz ? F3(1, 0, 0) : F3(0, 0, 1)
            let inw = r.horiz ? F3(0, 0, r.inward) : F3(r.inward, 0, 0)
            // yaw that turns a piece's +x along the run and its +z inward
            let yawAlong: Float = r.horiz ? (r.inward > 0 ? 0 : Float.pi) : (r.inward > 0 ? Float.pi / 2 : -Float.pi / 2)
            var knots: [Float] = [0]
            if len > 1 {
                for t in 1..<Int(len) {
                    let s0 = H(Float(t)) - H(Float(t - 1)), s1 = H(Float(t + 1)) - H(Float(t))
                    if abs(s0 - s1) > 1e-3 { knots.append(Float(t)) }
                }
            }
            knots.append(len)
            let (mx, mz) = P(len / 2)
            let m = cell(mx, mz)
            for k in 0..<(knots.count - 1) {
                let ta = knots[k], tb = knots[k + 1], ya = H(ta), yb = H(tb)
                let (xa, za) = P(ta), (xb, zb) = P(tb)
                let A = F3(xa, ya, za), B = F3(xb, yb, zb)
                // rails: top (round), mid (round), kick plate
                m.tube(A + F3(0, 1.05, 0), B + F3(0, 1.05, 0), r: 0.035, seg: 8, railMat)
                m.tube(A + F3(0, 0.6, 0), B + F3(0, 0.6, 0), r: 0.022, seg: 6, railMat, caps: false)
                let (ka, kza) = P(ta, -0.02), (kb, kzb) = P(tb, -0.02)
                m.beam(F3(ka, ya + 0.09, kza), F3(kb, yb + 0.09, kzb), w: 0.04, h: 0.18, c: 0.01, kickMat, bottom: false)
                // edge profile at the cell edge (0.12 outward of the rail line): chamfered lip, riveted skirt with the
                // cyan strip in its groove, underside
                let e = -inw * 0.12
                let o = -inw * 0.06
                let a0 = A + e, b0 = B + e
                m.face(orient([a0, b0, b0 + o + F3(0, -0.06, 0), a0 + o + F3(0, -0.06, 0)], up: -inw + F3(0, 1, 0)), lipMat)
                let sa = a0 + o + F3(0, -0.06, 0), sb = b0 + o + F3(0, -0.06, 0)
                m.face(orient([sa, sb, sb + F3(0, -0.5, 0), sa + F3(0, -0.5, 0)], up: -inw), skirtMat)
                m.face(orient([sa + F3(0, -0.5, 0), sb + F3(0, -0.5, 0), sb + F3(0, -0.5, 0) + inw * 0.36, sa + F3(0, -0.5, 0) + inw * 0.36],
                              up: F3(0, -1, 0)), underMat)
                m.beam(sa + F3(0, -0.2, 0) - inw * 0.012, sb + F3(0, -0.2, 0) - inw * 0.012, w: 0.024, h: 0.03, c: 0, stripMat)
                // I-beam girder under the edge
                let (ga, gza) = P(ta, 0.3), (gb, gzb) = P(tb, 0.3)
                let G0 = F3(ga, ya, gza), G1 = F3(gb, yb, gzb)
                m.beam(G0 + F3(0, -0.62, 0), G1 + F3(0, -0.62, 0), w: 0.36, h: 0.06, c: 0.01, girderMat)
                m.beam(G0 + F3(0, -1.25, 0), G1 + F3(0, -1.25, 0), w: 0.36, h: 0.06, c: 0.01, girderMat)
                m.beam(G0 + F3(0, -0.94, 0), G1 + F3(0, -0.94, 0), w: 0.06, h: 0.6, c: 0, girderMat)
                // icicle fringes under the lip (frost), never on the lift — only on the edges that face the gameplay
                // camera (outward +x / +z: the camera sits at yaw 45° on that side); under a far edge the deck hides them
                if !icicles.isEmpty && r.inward < 0 {
                    var t = ta + 0.5
                    while t < tb - 0.4 {
                        if rng.next() < 0.72 {
                            let (ix, iz) = P(t, -0.12 - 0.06)
                            let iy = (ya + (yb - ya) * (t - ta) / max(tb - ta, 1e-3)) - 0.56
                            let pc = icicles[Int(rng.next() * Float(icicles.count)) % icicles.count]
                            m.place(pc, at: F3(ix, iy, iz), yaw: yawAlong)
                            edgeStats.icicles += 1
                        }
                        t += 1.05
                    }
                }
            }
            // posts every ~2 m
            if let pp = post {
                let n = max(1, Int((len / 2).rounded()))
                for k in 0...n {
                    let t = Float(k) * len / Float(n)
                    let (x, z) = P(t)
                    m.place(pp, at: F3(x, H(t), z))
                    edgeStats.posts += 1
                }
            }
            // hazard stripe inside the edge (flat hazard platforms)
            if r.haz {
                let (x, z) = P(len / 2, 0.42)
                let y = level.groundY(x, z) + 0.012
                let c = F3(x, y, z)
                m.cbox(o: c, ax: dir, ay: F3(0, 1, 0), az: Mat4.cross(dir, F3(0, 1, 0)), w: len - 0.3, h: 0.024, d: 0.42, c: 0, hazMat,
                       bottom: false)
            }
            // lamps every 12 m along long runs: post on the rail line, arm inward, lens teal / green
            if len >= 6, let lp = lamp {
                var t: Float = 3
                while t < len - 1 {
                    let (x, z) = P(t)
                    let y = H(t)
                    let lc: UInt32 = (lampN % 3 == 2) ? Col.green : Col.teal
                    lampN += 1
                    m.place(lp, at: F3(x, y, z), yaw: yawAlong, paint: lc, caster: true)
                    edgeStats.lamps += 1
                    lights.append(StationLight(kind: .lamp, pos: F3(x, y + 2.95, z) + inw * 0.85, color: linearRGB(lc)))
                    let (gx, gz) = P(t, 1.4)
                    glowQuads.append((F3(gx, level.groundY(gx, gz), gz), 3.8, lc, 0.15))
                    t += 12
                }
            }
            // low drifts INSIDE the railing (never past the rail line), not on hazard platforms
            if !r.haz && !drifts.isEmpty && len >= 3 {
                var t: Float = 1.2
                while t < len - 1.2 {
                    if rng.next() < 0.62 {
                        let (x, z) = P(t, 0.48)
                        let c = level.cellOf(x, z)
                        if c >= 0 && level.walkValue(c) == 1 && !level.isLiftCell(c) && !level.isStairCell(c) {
                            let pc = drifts[Int(rng.next() * Float(drifts.count)) % drifts.count]
                            // the piece's ridge leans to its -z side, i.e. against the rail
                            m.place(pc, at: F3(x, level.groundY(x, z), z), yaw: yawAlong)
                            edgeStats.drifts += 1
                        }
                        t += 2.8
                    } else {
                        t += 1.6
                    }
                }
            }
        }
    }

    /// Low drifts banked into the inside corners of the decks (a walkable cell with the abyss on two adjacent sides):
    /// the wind packs snow there first. The piece's ridge (its -z side) faces the corner; never on the lift, stairs or
    /// hazard platforms, always inside the rail lines.
    private func buildCornerDrifts() {
        // the short drift only: 1.4 m across the corner, centred 0.25 m in from the cell centre, keeps both ends ≥ 0.1 m
        // inside the two rail lines (the rail line is 0.38 m from the cell centre)
        guard let pc = piece("drift_c") else { return }
        var rng = StationRNG(seed: 77)
        let G = GRID
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if level.walkValue(c) != 1 || level.isLiftCell(c) || level.isStairCell(c) || level.isHazardCell(c) { continue }
                let n = level.walkValue(c - G) == 0, s = level.walkValue(c + G) == 0
                let w = level.walkValue(c - 1) == 0, e = level.walkValue(c + 1) == 0
                // the corner's outward diagonal (sx, sz)
                var corner: (Float, Float)?
                if n && w { corner = (-1, -1) } else if n && e { corner = (1, -1) } else if s && w { corner = (-1, 1) } else if s && e { corner = (1, 1) }
                guard let (sx, sz) = corner, rng.next() < 0.75 else { continue }
                // the two inward neighbours must be deck (no drift on a one-cell-wide spur)
                if level.walkValue(c - Int(sx)) == 0 || level.walkValue(c - Int(sz) * G) == 0 { continue }
                let x = Float(i) - GRID_HALF + 0.5 - sx * 0.25, z = Float(j) - GRID_HALF + 0.5 - sz * 0.25
                // place() maps the piece's -z (its ridge) to (-sin yaw, -cos yaw): point it along (sx, sz)
                cell(x, z).place(pc, at: F3(x, level.groundY(x, z), z), yaw: atan2f(-sx, -sz))
                edgeStats.drifts += 1
            }
        }
    }

    /// Polygon ordered counter-clockwise seen from `up` (its facing direction).
    private func orient(_ p: [F3], up: F3) -> [F3] {
        let n = Mat4.cross(p[1] - p[0], p[2] - p[0])
        return Mat4.dot(n, up) >= 0 ? p : p.reversed()
    }

    // ---------------------------------------------------------------- supports, bracing, lift shaft, distant towers
    private func buildSupports() {
        var rng = StationRNG(seed: 31)
        let colMat = KitMat(tint: Col.support, metal: 0.6, layer: Trim.rails, uv: .strip(Trim.column, F3(0, 1, 0)))
        let braceMat = KitMat(tint: Col.girder, metal: 0.6, layer: Trim.rails, uv: .strip(Trim.girder, F3(1, 0, 0)))
        let cap = piece("support_cap")
        for r in level.layout.rects {
            let w = r.x1 - r.x0, d = r.z1 - r.z0
            let nx = max(1, Int((w / 9).rounded())), nz = max(1, Int((d / 9).rounded()))
            var cols: [(Float, Float)] = []
            for a in 0...nx {
                for b in 0...nz where a == 0 || a == nx || b == 0 || b == nz {
                    cols.append((r.x0 + 1 + (w - 2) * Float(a) / Float(nx), r.z0 + 1 + (d - 2) * Float(b) / Float(nz)))
                }
            }
            for (x, z) in cols {
                let top = r.height.height(atZ: z) - 0.5
                let h = 46 + rng.next() * 10
                let m = cell(x, z)
                m.beam(F3(x, top - h, z), F3(x, top, z), w: 0.72, h: 0.72, c: 0.08, colMat)
                if let cp = cap { m.place(cp, at: F3(x, top, z)) }
                if rng.next() < 0.35 {
                    m.cbox(o: F3(x + 0.4, top - 3.5 - rng.next() * 6, z), w: 0.08, h: 0.5, d: 0.08, c: 0,
                           KitMat(tint: Col.red, metal: 0, emis: 3, layer: Trim.none, flags: KitFlag.strip, uv: .none))
                }
            }
            if w > 10 && d > 10 {
                let y = r.height.minHeight - 6
                let m = cell((r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2)
                m.beam(F3(r.x0 + 1, y, r.z0 + 1), F3(r.x1 - 1, y, r.z0 + 1), w: 0.4, h: 0.4, c: 0.05, braceMat)
                m.beam(F3(r.x0 + 1, y, r.z1 - 1), F3(r.x1 - 1, y, r.z1 - 1), w: 0.4, h: 0.4, c: 0.05, braceMat)
            }
        }
        // lift shaft: ring, columns, teal studs (static: the deck rises out of it)
        let L = level.layout.lift
        let m = cell(L.x, L.z)
        m.lathe(o: F3(L.x, L.y, L.z), [(L.r + 0.6, -5), (L.r + 0.6, -0.9), (L.r + 0.3, -0.75)], seg: 40,
                KitMat(tint: Col.girder, metal: 0.6, layer: Trim.rails, uv: .strip(Trim.skirt, F3(0, 1, 0))))
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi
            let x = L.x + cosf(a) * (L.r + 0.9), z = L.z + sinf(a) * (L.r + 0.9)
            m.beam(F3(x, L.y - 51, z), F3(x, L.y - 1, z), w: 0.8, h: 0.8, c: 0.08, colMat)
        }
        for k in 0..<16 {
            let a = Float(k) / 16 * 2 * .pi
            m.cbox(o: F3(L.x + cosf(a) * (L.r + 1.0), L.y - 3.6, L.z + sinf(a) * (L.r + 1.0)), w: 0.25, h: 0.25, d: 0.25, c: 0,
                   KitMat(tint: Col.teal, metal: 0, emis: 2.4, layer: Trim.none, flags: KitFlag.strip, uv: .none))
        }
        // distant towers fading into the fog, a few lit window bands
        for k in 0..<14 {
            let a = Float(k) / 14 * 2 * .pi + rng.next() * 0.3, d = 74 + rng.next() * 26
            let x = cosf(a) * d, z = -5 + sinf(a) * d
            let top = -8 + rng.next() * 30, w = 5 + rng.next() * 9, h = top + 90
            let ry = rng.next() * 3
            let ax = F3(cosf(ry), 0, -sinf(ry)), az = F3(sinf(ry), 0, cosf(ry))
            let dd = w * (0.6 + rng.next() * 0.6)
            let tm = cell(x, z)
            tm.cbox(o: F3(x, top - h / 2, z), ax: ax, ay: F3(0, 1, 0), az: az, w: w, h: h, d: dd, c: 0.4,
                    KitMat(tint: Col.tower, metal: 0.4, layer: Trim.rails, uv: .strip(Trim.column, F3(0, 1, 0))), bottom: false)
            for _ in 0..<3 {
                let yy = top - 2 - rng.next() * 24
                let col: UInt32 = rng.next() < 0.3 ? Col.red : (rng.next() < 0.5 ? Col.teal : Col.amber)
                tm.cbox(o: F3(x, yy, z), ax: ax, ay: F3(0, 1, 0), az: az, w: w * 0.7, h: 0.18, d: dd + 0.06, c: 0,
                        KitMat(tint: col, metal: 0, emis: 1.6 + rng.next() * 1.6, layer: Trim.none, flags: KitFlag.strip, uv: .none))
            }
        }
    }

    // ---------------------------------------------------------------- props: crates, pillars, pipes, vents, beacons, pad
    private func buildProps() {
        var rng = StationRNG(seed: 57)
        for c in level.layout.crates {
            let cx = c.x0 + Float(c.w) / 2, cz = c.z0 + Float(c.d) / 2
            let y = level.groundY(cx, cz)
            let col = Col.crate[Int(rng.next() * 3) % 3]
            let yaw = (rng.next() - 0.5) * 0.08
            let name: String, rot: Float
            switch (c.w, c.d) {
            case (2, 2): name = "crate_2x2"; rot = 0
            case (2, 1): name = "crate_2x1"; rot = 0
            case (1, 2): name = "crate_2x1"; rot = Float.pi / 2
            default: name = "crate_1x1"; rot = 0
            }
            if let p = piece(name) { cell(cx, cz).place(p, at: F3(cx, y, cz), yaw: rot + yaw, scaleY: c.h, paint: col, caster: true) }
        }
        if let p = piece("pillar") {
            for q in level.layout.pillars {
                let y = level.groundY(q.x, q.y)
                cell(q.x, q.y).place(p, at: F3(q.x, y, q.y), caster: true)
                glowQuads.append((F3(q.x, y, q.y), 3.2, Col.teal, 0.14))
                lights.append(StationLight(kind: .pillar, pos: F3(q.x, y + 1.9, q.y), color: linearRGB(Col.teal)))
            }
        }
        // pipe bundles hanging off platform sides (brackets every 2 m)
        let pipeMats: [(Float, Float, UInt32, Int)] = [(-0.25, 0.16, 0x6a5a44, Trim.pipe), (-0.62, 0.12, Col.girder, Trim.pipe),
                                                       (-0.42, 0.06, Col.steelL, Trim.cables)]
        let bracket = piece("pipe_bracket")
        for pr in level.layout.pipes {
            let a = F3(pr.x0, pr.h, pr.z0), b = F3(pr.x1, pr.h, pr.z1)
            let m = cell((pr.x0 + pr.x1) / 2, (pr.z0 + pr.z1) / 2)
            for (dy, rad, col, strip) in pipeMats {
                m.tube(a + F3(0, dy, 0), b + F3(0, dy, 0), r: rad, seg: 10,
                       KitMat(tint: col, metal: 0.8, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(strip, F3(1, 0, 0))))
            }
            if let br = bracket {
                let d = b - a
                let L = (d * d).sum().squareRoot()
                let yaw = atan2f(-d.z, d.x)
                var t: Float = 1
                while t < L {
                    let p = a + d * (t / L)
                    m.place(br, at: p, yaw: yaw)
                    t += 2
                }
            }
        }
        if let p = piece("vent") {
            for v in level.layout.vents {
                let y = level.groundY(v.x, v.y)
                cell(v.x, v.y).place(p, at: F3(v.x, y, v.y))
                glowQuads.append((F3(v.x, y, v.y), 2.8, Col.orange, 0.18))
                lights.append(StationLight(kind: .vent, pos: F3(v.x, y + 0.3, v.y), color: linearRGB(Col.orange)))
            }
        }
        let head = piece("beacon_head")
        if let p = piece("beacon_mast") {
            for (k, b) in level.layout.beacons.enumerated() {
                let y = level.groundY(b.x, b.z)
                cell(b.x, b.z).place(p, at: F3(b.x, y, b.z), yaw: Float.pi / 4, caster: true)
                // the head rides on the mast top; vs_kit spins it about this pivot (headTable[k])
                if let h = head, k < WorldLevel.maxHeads {
                    cell(b.x, b.z).place(h, at: F3(b.x, y + WorldLevel.mastTop, b.z), headIndex: UInt32(k))
                }
                glowQuads.append((F3(b.x, y, b.z), 4.6, Col.amber, 0.15))
                lights.append(StationLight(kind: .beacon, pos: F3(b.x, y + WorldLevel.mastTop + 0.16, b.z), color: linearRGB(Col.red)))
            }
        }
        // landing-pad edge lights (around the start pad)
        if let p = piece("pad_light") {
            let s = level.layout.start
            for k in 0..<8 {
                let o = Float(k) * 2 - 7.4
                for (x, z) in [(s.x + o, s.y - 7.4), (s.x + o, s.y + 7.4), (s.x - 7.4, s.y + o), (s.x + 7.4, s.y + o)] {
                    let c = level.cellOf(x, z)
                    if c >= 0 && level.walkValue(c) != 0 { cell(x, z).place(p, at: F3(x, level.groundY(x, z), z)) }
                }
            }
        }
    }

    // ---------------------------------------------------------------- the lift (one chunk, raised at the extraction)
    private func buildLift() {
        let L = level.layout.lift, Y = L.y, m = liftMesh
        let deck = KitMat(tint: Col.deck, metal: 0.5, layer: Trim.gratings, flags: KitFlag.frost)
        m.disc(o: F3(L.x, 0, L.z), r: L.r, y: Y + 0.03, seg: 64, deck)
        // rim: chamfered lip + skirt, teal ring under it
        m.lathe(o: F3(L.x, Y, L.z), [(L.r, -0.7), (L.r + 0.15, -0.55), (L.r + 0.15, -0.05), (L.r, 0.03)], seg: 64,
                KitMat(tint: Col.steelD, metal: 0.8, layer: Trim.rails, flags: KitFlag.frost, uv: .strip(Trim.skirt, F3(0, 1, 0))))
        m.lathe(o: F3(L.x, Y - 0.3, L.z), [(L.r + 0.2, -0.025), (L.r + 0.2, 0.025)], seg: 96,
                KitMat(tint: Col.teal, metal: 0, emis: 3, layer: Trim.none, flags: KitFlag.strip, uv: .none))
        // ring railing (opening toward the stairs at +z)
        let railMat = KitMat(tint: Col.rail, metal: 0.9, layer: Trim.rails, uv: .strip(Trim.railbar, F3(1, 0, 0)))
        let post = piece("rail_post")
        for k in 0..<36 {
            let a0 = Float(k) / 36 * 2 * .pi, a1 = Float(k + 1) / 36 * 2 * .pi, r = L.r - 0.15, mid = (a0 + a1) / 2
            if abs(stationAngleDiff(mid, Float.pi / 2)) < 0.33 { continue }
            let p0 = F3(L.x + cosf(a0) * r, Y, L.z + sinf(a0) * r), p1 = F3(L.x + cosf(a1) * r, Y, L.z + sinf(a1) * r)
            m.tube(p0 + F3(0, 1.05, 0), p1 + F3(0, 1.05, 0), r: 0.035, seg: 6, railMat, caps: false)
            m.tube(p0 + F3(0, 0.6, 0), p1 + F3(0, 0.6, 0), r: 0.022, seg: 6, railMat, caps: false)
            if let pp = post { m.place(pp, at: p0) }
        }
        if let pad = piece("lift_pad") {
            for k in 0..<4 {
                let a = Float.pi / 4 + Float(k) * Float.pi / 2
                m.place(pad, at: F3(L.x + cosf(a) * 5.2, Y + 0.03, L.z + sinf(a) * 5.2), yaw: a)
            }
        }
        if let hub = piece("lift_hub") { m.place(hub, at: F3(L.x, Y + 0.03, L.z)) }
        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * .pi
            m.cbox(o: F3(L.x + cosf(a) * (L.r - 0.6), Y + 0.05, L.z + sinf(a) * (L.r - 0.6)), w: 0.16, h: 0.04, d: 0.16, c: 0,
                   KitMat(tint: Col.teal, metal: 0, emis: 2.6, layer: Trim.none, flags: KitFlag.strip, uv: .none), bottom: false)
        }
    }

    // ---------------------------------------------------------------- transparent quads (IHM1 layout)
    /// Floor light pools (additive): pillars, lamps, vents, beacons; colours pre-scaled like the web (× strength). The
    /// lamps, pillars and vents are real grid lights now (WP2, setStationLamps): the fake pools stay at ~40 % of the web's
    /// as a soft halo.
    private func buildGlowQuads(_ device: MTLDevice) {
        var v: [Float] = []
        var idx: [UInt32] = []
        for (c, s, col, k) in glowQuads {
            let lc = linearRGB(col) * k
            let h = s / 2, y = c.y + 0.03
            let base = UInt32(v.count / 13)
            for (dx, dz, u, w) in [(-h, h, Float(0), Float(0)), (h, h, 1, 0), (h, -h, 1, 1), (-h, -h, 0, 1)] {
                v += [c.x + dx, y, c.z + dz, 0, 1, 0, lc.x, lc.y, lc.z, 0, u, w, 0]
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        glowCount = glowQuads.count
        guard glowCount > 0 else { return }
        glowV = v.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
        glowI = idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
    }

    /// The landing-pad marking: an 11 × 11 m quad at the start point.
    private func buildPadQuad(_ device: MTLDevice) {
        let s = level.layout.start
        let y = level.groundY(s.x, s.y) + 0.01, h: Float = 5.5
        var v: [Float] = []
        for (dx, dz, u, w) in [(-h, h, Float(0), Float(1)), (h, h, 1, 1), (h, -h, 1, 0), (-h, -h, 0, 0)] {
            // worn paint on the dark deck: 0.6 of the texture's albedo (full strength read as a pale overlay)
            v += [s.x + dx, y, s.y + dz, 0, 1, 0, 0.6, 0.6, 0.6, 0, u, w, 0]
        }
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3]
        padV = v.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
        padI = idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
    }

    // ---------------------------------------------------------------- world mask (frost / contact AO)
    /// 256² RGBA8 over the 128 m grid (0.5 m texels): R frost — value noise plus a ramp toward railings and props,
    /// G contact AO — darker beside blocked cells (crates, pillars, beacons) and along the railings.
    private func buildWorldMask(_ device: MTLDevice) -> MTLTexture? {
        let G = GRID, S = 256
        var dist = [Float](repeating: 99, count: G * G), distBlocked = [Float](repeating: 99, count: G * G)
        var q: [Int] = [], qb: [Int] = []
        for c in 0..<(G * G) where level.walkValue(c) != 0 {
            let i = c % G, j = c / G
            var edge = false
            for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let ni = i + di, nj = j + dj
                if ni < 0 || nj < 0 || ni >= G || nj >= G || level.walkValue(nj * G + ni) == 0 { edge = true }
            }
            if level.walkValue(c) == 2 { distBlocked[c] = 0; qb.append(c); edge = true }
            if edge { dist[c] = 0; q.append(c) }
        }
        func bfs(_ d: inout [Float], _ queue: [Int]) {
            var qq = queue, h = 0
            while h < qq.count {
                let c = qq[h]; h += 1
                let i = c % G, j = c / G, nd = d[c] + 1
                for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let ni = i + di, nj = j + dj
                    if ni < 0 || nj < 0 || ni >= G || nj >= G { continue }
                    let n = nj * G + ni
                    if level.walkValue(n) == 0 || d[n] <= nd { continue }
                    d[n] = nd
                    qq.append(n)
                }
            }
        }
        bfs(&dist, q)
        bfs(&distBlocked, qb)
        var px = [UInt8](repeating: 0, count: S * S * 4)
        let n1 = StationNoise(seed: 4), n2 = StationNoise(seed: 9)
        for py in 0..<S {
            for pxi in 0..<S {
                let x = Float(pxi) * 0.5 - GRID_HALF + 0.25, z = Float(py) * 0.5 - GRID_HALF + 0.25
                let c = level.cellOf(x, z)
                let d = c >= 0 ? min(dist[c] + 0.5, 12) : 0
                var v = n1.at(x * 0.16, z * 0.16) * 0.55 + n2.at(x * 0.6, z * 0.6) * 0.25 - 0.12
                v += (1 - smooth01f(d / 3.2)) * 0.5
                if c >= 0 && level.isLiftCell(c) { v -= 0.25 }
                var ao: Float = 1
                if c >= 0 && level.walkValue(c) != 0 {
                    let db = distBlocked[c] + 0.5
                    ao -= 0.42 * expf(-db / 0.7)
                    ao -= 0.18 * expf(-(dist[c] + 0.5) / 0.6)
                }
                let o = (py * S + pxi) * 4
                px[o] = UInt8(clampf(v, 0, 1) * 255)
                px[o + 1] = UInt8(clampf(ao, 0, 1) * 255)
                px[o + 2] = 0
                px[o + 3] = 255
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: S, height: S, mipmapped: false)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, S, S), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: S * 4) }
        t.label = "world mask"
        return t
    }

    static func makeTexture(_ device: MTLDevice, _ size: Int, _ v: [UInt8]) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        let px = [UInt8]((0..<(size * size)).flatMap { _ in v })
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * 4) }
        return t
    }
}

// ================================================================ helpers
/// mulberry32 (the web game's seeded generator), floats in [0, 1) — station layout decoration only.
struct StationRNG {
    var a: UInt32
    init(seed: UInt32) { a = seed }
    mutating func next() -> Float {
        a = a &+ 0x6D2B_79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Float(t ^ (t >> 14)) / 4_294_967_296
    }
}

/// Smooth value noise over a 256² lattice of seeded values (the web's valueNoise).
struct StationNoise {
    private var p: [Float]
    init(seed: UInt32) {
        var r = StationRNG(seed: seed)
        p = (0..<(256 * 256)).map { _ in r.next() }
    }
    func at(_ x: Float, _ z: Float) -> Float {
        let xf = floorf(x), zf = floorf(z)
        let xi = Int(xf) & 255, zi = Int(zf) & 255
        let fx = x - xf, fz = z - zf
        let u = fx * fx * (3 - 2 * fx), v = fz * fz * (3 - 2 * fz)
        let a = p[zi * 256 + xi], b = p[zi * 256 + ((xi + 1) & 255)]
        let c = p[((zi + 1) & 255) * 256 + xi], d = p[((zi + 1) & 255) * 256 + ((xi + 1) & 255)]
        return lerpf(lerpf(a, b, u), lerpf(c, d, u), v)
    }
}

/// Shortest signed angle from a to b.
@inline(__always) func stationAngleDiff(_ a: Float, _ b: Float) -> Float {
    var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d <= -.pi { d += 2 * .pi }
    return d
}
