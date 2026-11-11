import Foundation
import Metal
import IceHiveCore

// ================================================================
//  WORLD OVERHEAD — the overhead layer as the squad sees it (Stage 1
//  R3 «Overhead render»; design.md §1.1.1–1.1.4, §1.1.7; tech.md
//  §2.4–2.7; the concept-station proof). Owned by this package; it
//  replaces R2's debug stand-in.
//  Geometry: OverheadKit.swift extrudes every route of
//  `level.layout.overhead` (racks, cables, trays, catwalks, ducts,
//  cantilever arms, their supports, the upper truss) into 16 m chunks
//  of one KitVertex / index buffer, trims and kit pieces like the
//  station. Per frame:
//    · the cutaway: the four marines' chests and the live drop
//      warnings projected to the screen (half-heights) — every chunk
//      whose screen box comes within reach of one, or of the eye, is
//      «near»; the rest are «far»;
//    · far chunks: ONE opaque, dark-graded draw (Level.metal
//      `overhead`, opaque item 105: the deck pixels it covers are never
//      shaded); near chunks: the cutaway draw (`overheadCut`, opaque
//      item 350, after the swarm) — the material with its alpha written
//      as MSAA sample coverage (Bayer-dithered): ≈ 25 % ghost within
//      0.22 half-heights of a marine, solid again at 0.36, so a bug on
//      a faded rack never floats in a hole. Bugs, marines and pickups
//      are never faded (other pipelines);
//    · cable sway: each cable's displacement this frame (a slow swing,
//      bowing and swinging harder under the bugs on it — design §1.1.3
//      «the sway is driven by the number of bugs on it»), read by
//      vs_overhead and by WorldSwarm for the bugs riding it;
//    · the drop language (design §1.1.4): frost dust falling from a
//      coiling bug to its landing ring, its eyes flaring (two hot
//      dots), the stream flashing and a ring of frost when it lets go,
//      a puff on landing; frost dust shed where a bug walks;
//    · on High the near chunks cast into the player's flashlight tile
//      (the beam marches pipe shadows through its cone).
//  Static grounding: the soft moon shadow of every route on the deck,
//  baked into the world mask's B (WorldLevel.writeWorldMask).
//  Look-dev / CI: `-noOverhead` (device A/B: no overhead draws),
//  `-ohVis` (OverheadVisibility: the occlusion / squad-visibility
//  metric). Once a second (diagnostics) `hb overhead draws=… tris=…
//  chunks=… near=… pts=… sway=…`. Nothing exists, draws or costs on
//  a station without routes (the bare v1.0 «Кельвин-9»; the classic
//  mission plays Mk II with its routes since Stage 1 R5).
// ================================================================

final class WorldOverhead {
    static let pipelines: [PipelineSpec] = [
        .world("overhead", "vs_overhead", "fs_overhead", .none, nil),
        .world("overheadCut", "vs_overhead", "fs_overhead_cut", .none, nil),
    ]
    /// `-noOverhead` (device A/B measurement, like `-noStation`): no overhead draws; `hb overhead` says `off`.
    static let noDraw = LaunchOptions.current.unknown.contains("-noOverhead")

    // ---------------------------------------------------------------- the cutaway (concept-station README «Fade»)
    /// The ghost the overhead keeps inside the cutaway (25 %: the structure stays continuous).
    static let ghost: Float = 0.25
    /// Screen radii (half screen heights) round a marine's chest: full ghost within, solid again at the outer one.
    static let marineRadius: (Float, Float) = (0.22, 0.36)
    /// Round a drop warning's ring (its 2 m ring is ≈ 0.19 half-heights at the focus).
    static let warnRadius: (Float, Float) = (0.26, 0.4)
    /// Near-eye fade (cinematic cameras): nothing nearer than 2.5 m, solid from 5 m.
    static let eyeFade: (Float, Float) = (2.5, 5.0)
    /// The darker grade: albedo ×, desaturation; the rime and the snow crust on the tops.
    static let grade: Float = 0.6, desaturate: Float = 0.3, rime: Float = 1.0, crust: Float = 0.9

    /// Layout of the per-frame block (Level.metal `struct OverheadParams`): 5 float4 + 8 points + 8 radii + 64 cables.
    enum Block {
        static let look = 0, misc = 1, mask = 2, view = 3, cut = 4, pts = 5, rad = 13, sway = 21, count = 85
        static let maxPoints = 8, maxCables = 64
    }

    private(set) var level: Level
    private var renderer: MetalRenderer!
    private var kit: KitStore!
    private var psFar: MTLRenderPipelineState?, psNear: MTLRenderPipelineState?, psShadow: MTLRenderPipelineState?

    private struct Chunk {
        let start: Int, count: Int, lo: F3, hi: F3, cls: Int
    }
    private var chunks: [Chunk] = []
    private var vbuf: MTLBuffer?, ibuf: MTLBuffer?
    /// Per-frame index lists, one per arena slot (FrameLoop keeps at most two frames on the GPU, as with the arena): this
    /// frame's visible far chunks back to back, then the near ones — one solid and one cutaway draw whatever the layout
    /// (tech estimate «+2 draws»), hidden chunks not drawn at all. Without them (allocation failed) the runs over the
    /// static index buffer are drawn instead.
    private var frameIdx: [MTLBuffer] = []
    private var frameIB: MTLBuffer?
    /// Cables: edge → (slot, perpendicular), edge lengths (the sway weight of a bug riding one).
    private var cables: [Int: (slot: Int, perp: F3)] = [:]
    private var edgeLength: [Float] = []
    private var cableAmp = [Float](repeating: 0.04, count: Block.maxCables)
    private var cablePhase = [Float](repeating: 0, count: Block.maxCables)
    private var swayNow = [F3](repeating: .zero, count: Block.maxCables)
    private var loads: [Int] = []
    /// The overhead's own grid lights (duct mouths), added to the station's.
    private(set) var lights: [(F3, F3)] = []
    /// The per-frame block, its arena region this frame, and a copy for the visibility pass.
    private(set) var block = [F4](repeating: .zero, count: Block.count)
    private var region = Region()
    /// This frame's draw runs (index ranges into frameIB — one each — or, without it, into ibuf): far, near; and the caster
    /// runs into ibuf (High).
    private var farRuns: [(Int, Int)] = [], nearRuns: [(Int, Int)] = [], casterRuns: [(Int, Int)] = []
    private var visibleChunks = 0, nearChunks = 0, points = 0
    private var casterCall = 0
    /// The caster draws / triangles this frame (High, the player's flashlight tile on; `hb overhead … casters=`).
    private var casterDraws = 0, casterTris = 0
    /// Last frame's stats (hb overhead), the build summary.
    private var lastDraws = (0, 0), lastTris = 0, lastLog: Double = 0
    /// The CPU cost of build() (ms, smoothed; `hb overhead … cpu=`).
    private var buildMs: Double = 0
    private(set) var summary = ""
    /// Drop zones whose let-go flash already fired (bug uid).
    private var flashed: Set<Int32> = []
    private var trailAcc: Float = 0
    /// Emission accumulators of the drop warnings (dust stream, eye glints): by the effects' dt, so a frozen look-dev shot
    /// (the world ×0.02) does not pile particles up at one place.
    private var streamAcc: Float = 0, glintAcc: Float = 1
    /// The visibility metric (`-ohVis`), when on.
    private(set) var visibility: OverheadVisibility?

    var hasGeometry: Bool { !chunks.isEmpty }

    // ---- Stage 1 R4 «Overhead bugs»: the duct mouths' rattle and seal, the cable runners' group warning, the Dropper's tick
    /// Sounds the overhead asks for this frame (id, deck position, gain): GameScene plays them through the attic voice.
    private var pendingSounds: [(SoundID, Vec2, Float)] = []
    /// Each duct mouth's outward direction in plan (from its duct out over the void), by route node.
    private var ductOut: [Int: F3] = [:]
    private var rattleClack: [Float] = []
    private var cableRattle: [Int: Float] = [:]
    private var cableDust: Float = 0, tickT: Float = 0

    init(level: Level) {
        self.level = level
    }

    /// Pipelines, the geometry, draw items (MetalWorld, once). `stationLamps`: WorldLevel's grid lights (the overhead's
    /// duct-mouth glows are registered together with them).
    func attach(_ r: MetalRenderer, stationLamps: [(F3, F3)]) {
        renderer = r
        kit = r.store.kit
        psFar = r.pipeline("overhead")
        psNear = r.pipeline("overheadCut")
        psShadow = r.pipeline("shadowKit")
        assemble(stationLamps: stationLamps)
        r.register(.opaque, order: 105, "overhead far") { [unowned self] enc in self.encode(enc, near: false) }
        r.register(.opaque, order: 350, "overhead near") { [unowned self] enc in self.encode(enc, near: true) }
        r.register(.shadowCasters, order: 60, "overhead casters") { [unowned self] enc in self.encodeCasters(enc) }
        if LaunchOptions.current.unknown.contains("-ohVis") {
            visibility = OverheadVisibility(overhead: self, renderer: r)
        }
    }

    /// Another station (behind a cover): the geometry and the lights again.
    func rebuild(level newLevel: Level, stationLamps: [(F3, F3)]) {
        level = newLevel
        assemble(stationLamps: stationLamps)
        visibility?.levelChanged()
    }

    private func assemble(stationLamps: [(F3, F3)]) {
        let t0 = FrameTimer.now()
        chunks.removeAll()
        vbuf = nil; ibuf = nil
        frameIdx = []; frameIB = nil
        cables = [:]
        lights = []
        let L = level.layout.overhead
        edgeLength = L.edges.map { e in
            let d = L.nodes[Int(e.b)].p - L.nodes[Int(e.a)].p
            return max(0.01, (d * d).sum().squareRoot())
        }
        loads = [Int](repeating: 0, count: L.edges.count)
        // (Stage 1 R4: the duct mouths face out along their duct)
        ductOut = [:]
        for (n, nd) in L.nodes.enumerated() where nd.kind == .ductMouth {
            guard let e = L.edges.first(where: { Int($0.a) == n || Int($0.b) == n }) else { continue }
            let o = L.nodes[Int(e.a) == n ? Int(e.b) : Int(e.a)].p
            let d = F3(nd.p.x - o.x, 0, nd.p.z - o.z)
            let l = (d * d).sum().squareRoot()
            ductOut[n] = l > 1e-3 ? d / l : F3(0, 0, -1)
        }
        guard !L.isEmpty, let k = kit, k.ready else {
            summary = L.isEmpty ? "overhead: no routes on this station — nothing to draw" : "overhead: kit not loaded"
            AppLog.info(summary)
            return
        }
        let b = OverheadBuild(level: level, pieces: k.pieces)
        b.build()
        cables = b.cables
        lights = b.lights
        var verts: [KitVertex] = []
        var idx: [UInt32] = []
        for cls in 0..<2 {
            for key in b.cells[cls].keys.sorted() {
                let m = b.cells[cls][key]!
                guard !m.isEmpty else { continue }
                let base = UInt32(verts.count)
                let start = idx.count
                verts += m.vertices
                for i in m.indices { idx.append(base + i) }
                chunks.append(Chunk(start: start, count: m.indices.count, lo: m.lo, hi: m.hi, cls: cls))
            }
        }
        let dev = renderer.device
        if !verts.isEmpty {
            vbuf = verts.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
            ibuf = idx.withUnsafeBytes { dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [.storageModeShared]) }
            vbuf?.label = "overhead.v"
            ibuf?.label = "overhead.i"
            let lists = (0..<MetalRenderer.arenaSlots).compactMap { _ in
                dev.makeBuffer(length: idx.count * 4, options: [.storageModeShared, .cpuCacheModeWriteCombined])
            }
            frameIdx = lists.count == MetalRenderer.arenaSlots ? lists : []
            for (k, b) in frameIdx.enumerated() { b.label = "overhead.i\(k)" }
        }
        if !lights.isEmpty { LightingHub.current?.setStationLamps(stationLamps + lights) }
        let tris = idx.count / 3
        let mb = Double(verts.count * MemoryLayout<KitVertex>.stride + idx.count * 4 * (1 + frameIdx.count)) / 1_048_576
        let names = ["pipes", "cables", "trays", "catwalks", "ducts"]
        summary = String(format: "overhead: %d vertices, %d triangles in %d chunks (%.2f MB; %.0f ms) | ", verts.count, tris, chunks.count, mb,
                         (FrameTimer.now() - t0) * 1000)
            + RouteKind.allCases.map { String(format: "%@ %.0f m", names[Int($0.rawValue)], b.metres[Int($0.rawValue)]) }.joined(separator: ", ")
            + " | \(b.arms) arms, \(b.supports) supports, \(b.piecesPlaced) pieces, \(b.trussGirders) truss girders, \(cables.count) swaying cables,"
            + " \(lights.count) lights"
        AppLog.info(summary)
    }

    // ================================================================ per frame
    /// This frame's cutaway points, cable sway, chunk runs and effects (MetalWorld.update, after the swarm and the squad).
    func build(game: Game, camera: MetalCamera, poses: [MetalEffects.MarinePose], time: Float, dt: Float, fx: MetalEffects) {
        farRuns.removeAll(keepingCapacity: true)
        nearRuns.removeAll(keepingCapacity: true)
        casterRuns.removeAll(keepingCapacity: true)
        casterCall = 0
        casterDraws = 0; casterTris = 0
        region = Region()
        frameIB = nil
        guard hasGeometry, let r = renderer else { return }
        let t0 = FrameTimer.now()
        defer { buildMs += ((FrameTimer.now() - t0) * 1000 - buildMs) * 0.1 }
        fillBlock(game: game, camera: camera, poses: poses, time: time, dt: dt, high: r.frameTier == .high)
        region = r.upload(block)
        classify(camera: camera, playerAt: poses.first.map { F3($0.x, $0.y, $0.z) }, truss: fx.fxK >= 0.5, high: r.frameTier == .high)
        effects(game: game, fx: fx, dt: dt, time: time, eye: camera.eye)
        visibility?.frame(game: game, camera: camera, poses: poses)
    }

    /// The block: look constants, the viewport, the cut points (marines' chests, live drop warnings), the sway table.
    private func fillBlock(game: Game, camera: MetalCamera, poses: [MetalEffects.MarinePose], time: Float, dt: Float, high: Bool) {
        let r = renderer!
        block[Block.look] = F4(WorldOverhead.rime, WorldOverhead.crust, WorldOverhead.grade, WorldOverhead.desaturate)
        block[Block.misc] = F4(high ? 1 : 0, 0, time, 0)
        block[Block.mask] = F4(-GRID_HALF, -GRID_HALF, 1 / (2 * GRID_HALF), 0)
        block[Block.view] = F4(2 / Float(max(1, r.targetWidth)), 2 / Float(max(1, r.targetHeight)), camera.aspect, WorldOverhead.ghost)
        var n = 0
        let vp = camera.viewProj
        let tanHalf = tanf(camera.fov * Float.pi / 360)
        /// A cut point: its screen spot, the view depth in front of which the overhead fades (`depthAt` + `pad`: a marine's
        /// feet + 1 m — Stage 1 R5: with its chest's depth, a deck post or a riser column standing just in front of a marine's
        /// legs was "behind the point" and stayed solid over them: Kelvin-9 Mk II's combat run hid 21 % of a marine), and its
        /// radius kept at its game-camera size in the world in a close shot (the punch-in at ≈ 10 m makes a marine three
        /// times taller on screen; at most × 3).
        func point(_ p: F3, depthAt d: F3? = nil, pad: Float = 0, weight: Float, rad: (Float, Float)) {
            guard n < Block.maxPoints, weight > 0.01 else { return }
            let c = vp.point(p.x, p.y, p.z)
            guard c.w > 0.5 else { return }
            let z = d.map { vp.point($0.x, $0.y, $0.z).w + pad } ?? c.w
            let s = min(3, max(1, MetalCamera.halfHeight / (c.w * tanHalf)))
            block[Block.pts + n] = F4(c.x / c.w * camera.aspect, c.y / c.w, z, min(1, weight))
            block[Block.rad + n] = F4(rad.0 * s, rad.1 * s, 0, 0)
            n += 1
        }
        for k in 0..<min(game.marines.count, poses.count) {
            point(F3(poses[k].x, poses[k].y + 1.1, poses[k].z), depthAt: F3(poses[k].x, poses[k].y, poses[k].z), pad: 1.0, weight: 1,
                  rad: WorldOverhead.marineRadius)
        }
        for z in game.dropZones where z.active {
            // eased in over 0.25 s (design §1.1.2: the overhead dithers down round every active drop warning)
            point(F3(z.x, level.groundY(z.x, z.z) + 0.2, z.z), weight: (z.warn - z.t) / 0.25, rad: WorldOverhead.warnRadius)
        }
        points = n
        block[Block.cut] = F4(WorldOverhead.eyeFade.0, WorldOverhead.eyeFade.1, Float(n), 0.3)
        sway(game: game, dt: dt)
    }

    /// Each cable's displacement: a slow swing (≈ 0.6–0.9 Hz) whose amplitude grows with the bugs on it, and a bow under
    /// their weight (smoothed: a pack running on bows it before it reaches the middle).
    private func sway(game: Game, dt: Float) {
        guard !cables.isEmpty else { return }
        for k in loads.indices { loads[k] = 0 }
        let S = game.bugs
        let st = S.states, re = S.routeEdges, dead = S.deadFlags
        let high = BugState.high.rawValue, coil = BugState.coil.rawValue
        for i in 0..<S.count where dead[i] == 0 && (st[i] == high || st[i] == coil) {
            let v = Int(re[i])
            if v == 0 { continue }
            let e = abs(v) - 1
            if e >= 0 && e < loads.count { loads[e] += 1 }
        }
        for (e, c) in cables {
            let s = c.slot
            let load = Float(min(4, loads[e]))
            let want: Float = 0.035 + 0.04 * load
            cableAmp[s] += (want - cableAmp[s]) * min(1, dt * 2.5)
            cablePhase[s] += dt * 2 * Float.pi * (0.6 + 0.07 * Float(s % 5))
            if cablePhase[s] > 1000 { cablePhase[s] -= 2 * Float.pi * 150 }
            let a = cableAmp[s], ph = cablePhase[s]
            let swing = c.perp * (a * sinf(ph))
            let bow = -(0.04 * load / 4 + a * 0.4 * (0.5 - 0.5 * cosf(2 * ph)))
            swayNow[s] = swing + F3(0, bow, 0)
            block[Block.sway + s] = F4(swayNow[s].x, swayNow[s].y, swayNow[s].z, 0)
        }
    }

    /// The displacement of a point `s` m along route edge `e` this frame (a bug riding a swaying cable moves with it).
    func swayOffset(edge e: Int, s: Float) -> F3 {
        guard let c = cables[e], e < edgeLength.count else { return .zero }
        let u = clampf(s / edgeLength[e], 0, 1)
        return swayNow[c.slot] * (4 * u * (1 - u))
    }

    // ---------------------------------------------------------------- chunk classes and runs
    /// Visible chunks → far / near index runs; the caster runs (High: route chunks within 22 m of the player).
    private func classify(camera: MetalCamera, playerAt: F3?, truss: Bool, high: Bool) {
        let planes = WorldLevel.frustumPlanes(camera.viewProj)
        var kinds = [UInt8](repeating: 0, count: chunks.count)   // 0 hidden, 1 far, 2 near
        visibleChunks = 0
        nearChunks = 0
        for (k, c) in chunks.enumerated() {
            if c.cls == 1 && !truss { continue }
            if !WorldLevel.visible(planes, c.lo, c.hi) { continue }
            visibleChunks += 1
            if near(c, camera) { kinds[k] = 2; nearChunks += 1 } else { kinds[k] = 1 }
        }
        if !compact(kinds) {
            farRuns = WorldOverhead.runs(chunks.map { ($0.start, $0.count) }, kinds, want: 1)
            nearRuns = WorldOverhead.runs(chunks.map { ($0.start, $0.count) }, kinds, want: 2)
        }
        if high, let p = playerAt {
            var ck = [UInt8](repeating: 0, count: chunks.count)
            for (k, c) in chunks.enumerated() where c.cls == 0 {
                let dx = max(c.lo.x - p.x, 0, p.x - c.hi.x), dz = max(c.lo.z - p.z, 0, p.z - c.hi.z)
                if dx * dx + dz * dz < 22 * 22 { ck[k] = 1 }
            }
            casterRuns = WorldOverhead.runs(chunks.map { ($0.start, $0.count) }, ck, want: 1)
        }
    }

    /// The visible chunks into this frame's index list, far ones first, then the near ones: farRuns / nearRuns become one
    /// range each (a copy of ≈ 65–95 KB of indices in the showcase's views: tens of microseconds). False without the
    /// lists.
    private func compact(_ kinds: [UInt8]) -> Bool {
        guard frameIdx.count == MetalRenderer.arenaSlots, let ib = ibuf, let r = renderer else { return false }
        let dst = frameIdx[r.arenaSlot]
        let src = ib.contents().assumingMemoryBound(to: UInt32.self)
        let out = dst.contents().assumingMemoryBound(to: UInt32.self)
        var n = 0
        for want: UInt8 in 1...2 {
            let first = n
            for (k, c) in chunks.enumerated() where kinds[k] == want {
                (out + n).update(from: src + c.start, count: c.count)
                n += c.count
            }
            let run = n > first ? [(first, n - first)] : []
            if want == 1 { farRuns = run } else { nearRuns = run }
        }
        frameIB = dst
        return true
    }

    /// A chunk is near when its screen box comes within reach of a cut point (or of the eye). (What hangs below the decks
    /// — the posts down to the abyss — stands behind them and never hides the squad: the box starts at −8 m.)
    private func near(_ c: Chunk, _ camera: MetalCamera) -> Bool {
        let vp = camera.viewProj
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        let y0 = min(c.hi.y, max(c.lo.y, -8))
        for k in 0..<8 {
            let x = k & 1 == 0 ? c.lo.x : c.hi.x, y = k & 2 == 0 ? y0 : c.hi.y, z = k & 4 == 0 ? c.lo.z : c.hi.z
            let q = vp.point(x, y, z)
            if q.w < WorldOverhead.eyeFade.1 + 2 { return true }
            let s = SIMD2<Float>(q.x / q.w * camera.aspect, q.y / q.w)
            lo = pointwiseMin(lo, s); hi = pointwiseMax(hi, s)
        }
        for k in 0..<points {
            let p = block[Block.pts + k], rr = block[Block.rad + k].y + 0.02
            if p.x > lo.x - rr && p.x < hi.x + rr && p.y > lo.y - rr && p.y < hi.y + rr { return true }
        }
        return false
    }

    /// Contiguous index runs of the chunks of kind `want` (laid out back to back in the index buffer); a hidden chunk
    /// (kind 0) between two wanted ones is drawn with them when small (the GPU clips it: cheaper than another draw), a
    /// chunk of the other kind always breaks the run.
    static func runs(_ ranges: [(Int, Int)], _ kinds: [UInt8], want: UInt8) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start = -1, end = 0, gap = 0
        for (k, (s, n)) in ranges.enumerated() {
            let kd = kinds[k]
            if kd == want {
                if start >= 0 && s == end + gap && gap <= 3000 * 3 { end = s + n } else {
                    if start >= 0 { out.append((start, end - start)) }
                    start = s; end = s + n
                }
                gap = 0
            } else if kd == 0 && start >= 0 {
                gap += n
            } else if start >= 0 {
                out.append((start, end - start))
                start = -1; gap = 0
            }
        }
        if start >= 0 { out.append((start, end - start)) }
        return out
    }

    // ---------------------------------------------------------------- draw items
    /// Opaque 105 (far, solid) / 350 (near, the cutaway).
    private func encode(_ enc: MTLRenderCommandEncoder, near: Bool) {
        let r = renderer!
        if !near { lastDraws = (0, 0); lastTris = 0 }
        defer { if near { heartbeat() } }
        guard !WorldOverhead.noDraw, let vb = vbuf, let ib = frameIB ?? ibuf, region.count > 0, let ps = near ? psNear : psFar, let k = kit else { return }
        let runs = near ? nearRuns : farRuns
        if runs.isEmpty { return }
        r.use(enc, ps)
        enc.setFragmentTexture(k.trimNormal, index: WorldLevel.Slot.trimNormal)
        enc.setFragmentTexture(k.trimORM, index: WorldLevel.Slot.trimORM)
        enc.setFragmentTexture(k.aoAtlas, index: WorldLevel.Slot.ao)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        enc.setVertexBuffer(r.arena, offset: region.offset, index: BufferIndex.material)
        enc.setFragmentBuffer(r.arena, offset: region.offset, index: BufferIndex.material)
        for (start, count) in runs {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: start * 4)
            r.count(triangles: count / 3)
            lastTris += count / 3
            if near { lastDraws.1 += 1 } else { lastDraws.0 += 1 }
        }
    }

    /// Shadow casters (High): the route chunks near the player into the player's flashlight tile — the first caster call
    /// of a frame whose player tile is on (ShadowAtlas draws that tile first) — so the beam's march shows the pipes.
    private func encodeCasters(_ enc: MTLRenderCommandEncoder) {
        let r = renderer!
        let call = casterCall
        casterCall += 1
        guard call == 0, !WorldOverhead.noDraw, r.frame.shadowParams.x > 0.5, let ps = psShadow, let vb = vbuf, let ib = ibuf,
              !casterRuns.isEmpty else { return }
        enc.setRenderPipelineState(ps)
        enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
        enc.setDepthBias(0, slopeScale: 1.5, clamp: 0.002)
        for (start, count) in casterRuns {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: start * 4)
            r.count(triangles: count / 3)
            casterDraws += 1
            casterTris += count / 3
        }
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }

    /// The overhead's geometry for the visibility pass: vertex / index buffers and this frame's visible runs (far + near).
    var visDraw: (MTLBuffer, MTLBuffer, [(Int, Int)])? {
        guard let vb = vbuf, let ib = frameIB ?? ibuf else { return nil }
        return (vb, ib, farRuns + nearRuns)
    }

    /// Once per second (diagnostics): `hb overhead draws=far+near tris=… chunks=visible/all near=… pts=… sway=… tier=…`.
    private func heartbeat() {
        guard AppLog.diagnostics, hasGeometry else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        let swing = cables.values.map { (swayNow[$0.slot] * swayNow[$0.slot]).sum().squareRoot() }.max() ?? 0
        AppLog.info("hb overhead draws=\(lastDraws.0)+\(lastDraws.1) tris=\(lastTris) chunks=\(visibleChunks)/\(chunks.count) near=\(nearChunks)"
                    + " pts=\(points)" + String(format: " sway=%.2fm cpu=%.3fms", swing, buildMs) + " casters=\(casterDraws)/\(casterTris)"
                    + " tier=" + (renderer.frameTier == .high ? "high" : "efficient") + (WorldOverhead.noDraw ? " off" : ""))
    }

    // ================================================================ the drop language and the dust (design §1.1.4)
    /// Per frame: frost dust shed by moving bugs on the routes; for every live drop warning the dust stream from the coiling
    /// bug to its ring, the red glint on its head, and the flash when it lets go.
    private func effects(game: Game, fx: MetalEffects, dt: Float, time: Float, eye: F3) {
        guard dt > 0 else { return }
        let S = game.bugs
        let n = S.count
        let X = S.xs, Z = S.zs, Y = S.heights, ST = S.states, dead = S.deadFlags, VX = S.velocityX, VZ = S.velocityZ
        let HD = S.headings, SC = S.scales, U = S.uids
        let high = BugState.high.rawValue, coil = BugState.coil.rawValue, dropSt = BugState.drop.rawValue
        let k = fx.fxK
        // dust where a bug walks (you can track an unseen bug by its dust)
        trailAcc += dt * 2.6 * k
        let shed = trailAcc >= 1
        if shed { trailAcc -= floorf(trailAcc) }
        if shed {
            for i in 0..<n where dead[i] == 0 && ST[i] == high && VX[i] * VX[i] + VZ[i] * VZ[i] > 0.1 {
                fx.gpu.burst(.ice, 1, at: F3(X[i], Y[i] - 0.05, Z[i]), jitter: F3(0.2, 0.03, 0.2), vel: F3(0, -0.5, 0), velJitter: F3(0.25, 0.2, 0.25),
                             life: (1.2, 1.8), size: (0.035, 0.02), color: F4(0.5, 0.62, 0.78, 0.7), gravity: 1.5, drag: 1.2)
            }
        }
        // the drop warnings
        streamAcc += dt * 110 * k
        let streamN = Int(streamAcc)
        streamAcc -= Float(streamN)
        glintAcc += dt
        let glint = glintAcc >= 0.05
        if glint { glintAcc = 0 }
        var live: Set<Int32> = []
        for z in game.dropZones where z.active {
            live.insert(z.uid)
            var from = F3(z.from.x, z.from.y, z.from.z)
            var hd: Float = 0, sc: Float = 1, found = false, coiling = false
            for i in 0..<n where U[i] == z.uid && dead[i] == 0 && (ST[i] == coil || ST[i] == dropSt) {
                from = F3(X[i], Y[i], Z[i]); hd = HD[i]; sc = SC[i] * 1.15; found = true; coiling = ST[i] == coil
                break
            }
            let land = F3(z.x, level.groundY(z.x, z.z) + 0.05, z.z)
            let p = z.progress
            if coiling || (!found && z.t > DROP_T) {
                // the frost-dust stream from the bug down to its ring (the 0.65·h image shift hides the landing spot: the
                // stream joins them on screen): ≈ 110 specks a second of 7 cm, stretched along their fall — what reads at
                // phone size in motion (the proof's ≈ 100 specks at 1.6–2.5 m/s)
                let d = land - from
                for _ in 0..<min(8, streamN) {
                    let u = Float.random(in: 0..<1)
                    let q = from + d * u
                    fx.gpu.burst(.ice, 1, at: q, jitter: F3(0.12, 0.05, 0.12), vel: d * 0.35 + F3(0, -1.2, 0), velJitter: F3(0.2, 0.3, 0.2),
                                 life: (0.5, 0.8), size: (0.075, 0.035), color: F4(0.85, 1.0, 1.3, 1), gravity: 2, drag: 0.6)
                }
                // the glint: a red four-ray star on its head, hotter as the drop nears — HDR into the bloom, the first thing
                // the eye catches at phone size (the proof's red glint; the bugs' own glints are pink dots). Nudged 0.3 m
                // toward the eye so the head does not swallow it.
                if found && glint {
                    let f = F3(sinf(hd), 0, cosf(hd))
                    let head = from + f * (0.42 * sc) + F3(0, 0.24 * sc - 0.06 * p, 0)
                    let toEye = eye - head
                    let le = max(0.01, (toEye * toEye).sum().squareRoot())
                    let pulse = 0.8 + 0.2 * sinf(time * 26) + 0.6 * p
                    fx.gpu.burst(.flash, 1, at: head + toEye * (0.3 / le), life: (0.09, 0.09), size: (0.5 + 0.25 * p, 0.45 + 0.25 * p),
                                 color: F4(4.2 * pulse, 0.45 * pulse, 0.35 * pulse, 1), sizeJitter: 0)
                }
            } else if !flashed.contains(z.uid) {
                // it lets go (t − 0.3 s): the stream flashes and a ring of frost locks round the landing point
                flashed.insert(z.uid)
                let d = land - from
                for s in 0..<8 {
                    let q = from + d * (Float(s) / 8)
                    fx.gpu.burst(.ice, 2, at: q, jitter: F3(0.1, 0.05, 0.1), vel: d * 0.5, velJitter: F3(0.3, 0.3, 0.3), life: (0.25, 0.4),
                                 size: (0.07, 0.03), color: F4(1.4, 1.6, 2.0, 1), gravity: 3, drag: 0.5)
                }
                fx.gpu.burst(.glow, fx.fxK >= 0.85 ? 18 : 12, at: land, ring: z.r, vel: F3(0, 0.25, 0), radial: 0.4, life: (0.3, 0.45),
                             size: (0.22, 0.05), color: F4(1.3, 0.75, 1.0, 1), drag: 1.5)
            }
        }
        if flashed.count > 0 { flashed.formIntersection(live) }
        bugsEffects(game: game, fx: fx, dt: dt, time: time)
    }

    /// The sounds asked for since the last call (GameScene, after the events).
    func takeSounds() -> [(SoundID, Vec2, Float)] {
        defer { pendingSounds.removeAll(keepingCapacity: true) }
        return pendingSounds
    }

    /// Where duct mouth `k` (Game.ducts order = OverheadGraph.ducts) breathes: its grille's centre and outward direction.
    private func mouth(_ node: Int) -> (F3, F3) {
        let out = ductOut[node] ?? F3(0, 0, -1)
        let p = level.layout.overhead.nodes[node].p
        return (F3(p.x, p.y - 0.35, p.z) + out * 0.5, out)
    }

    /// Stage 1 R4, per frame: a rattling duct mouth glows amber in pulses, puffs frost and clacks (design §1.1.3 «the grille
    /// rattles, glows amber and puffs frost»); a shut one sparks at its rim in the seconds before the hive chews through; a
    /// cable loaded with two or more bugs sheds a line of frost dust and rattles (the cable runners' group warning); the
    /// nearest creeping Dropper ticks on the metal above.
    private func bugsEffects(game: Game, fx: MetalEffects, dt: Float, time: Float) {
        let k = fx.fxK
        let ducts = game.ducts
        if rattleClack.count != ducts.count { rattleClack = [Float](repeating: 0, count: ducts.count) }
        for (i, d) in ducts.enumerated() {
            let (m, out) = mouth(d.node)
            if d.rattleT > 0 {
                let pulse = 0.55 + 0.45 * sinf(time * 31 + Float(i))
                LightingHub.current?.emit(m + out * 0.4, color: F3(1.0, 0.42, 0.08), intensity: 46 * pulse, range: 7, specular: false, priority: 16)
                if Float.random(in: 0..<1) < dt * 14 * k {
                    fx.gpu.burst(.steam, 1, at: m + out * 0.25, jitter: F3(0.25, 0.2, 0.25), vel: out * 1.4 + F3(0, -0.2, 0),
                                 velJitter: F3(0.4, 0.3, 0.4), life: (0.5, 0.9), size: (0.25, 0.7), color: F4(0.62, 0.7, 0.8, 0.3), drag: 1.4)
                    fx.gpu.burst(.ice, 2, at: m, jitter: F3(0.3, 0.25, 0.3), vel: out * 0.8, velJitter: F3(0.4, 0.3, 0.4), life: (0.6, 1.0),
                                 size: (0.04, 0.02), color: F4(0.8, 0.95, 1.2, 1), gravity: 4, drag: 0.6)
                }
                rattleClack[i] -= dt
                if rattleClack[i] <= 0 {
                    rattleClack[i] = 0.16 + 0.06 * Float.random(in: 0..<1)
                    pendingSounds.append((.reload, Vec2(m.x, m.z), 0.5))
                }
            } else {
                rattleClack[i] = 0
            }
            if !d.open && d.shutT < 6 && Float.random(in: 0..<1) < dt * 5 * k {
                fx.gpu.burst(.spark, 1, at: m + out * 0.1, jitter: F3(0.35, 0.3, 0.35), sphere: 2, life: (0.15, 0.3), size: (0.03, 0.02),
                             color: F4(1.3, 0.9, 0.6, 1), gravity: 9, drag: 1)
                fx.gpu.burst(.ice, 1, at: m, jitter: F3(0.3, 0.3, 0.3), vel: F3(0, -0.6, 0), life: (0.8, 1.2), size: (0.035, 0.02),
                             color: F4(0.6, 0.7, 0.85, 0.8), gravity: 2, drag: 1)
            }
        }
        guard let G = level.overhead else { return }
        // cable runners: a line of frost dust shaken off along a loaded cable, and its rattle
        cableDust += dt * 30 * k
        let dustN = Int(cableDust)
        cableDust -= Float(dustN)
        for (e, _) in cables where e < G.edgeCount {
            let load = e < loads.count ? loads[e] : 0
            var cool = (cableRattle[e] ?? 0) - dt
            if load >= 2 {
                for _ in 0..<min(6, dustN * min(load, 4) / 2) {
                    let sv = Float.random(in: 0..<1) * G.length[e]
                    let p = G.point(e, sv) + swayOffset(edge: e, s: sv)
                    fx.gpu.burst(.ice, 1, at: F3(p.x, p.y - 0.05, p.z), jitter: F3(0.08, 0.02, 0.08), vel: F3(0, -0.8, 0),
                                 velJitter: F3(0.2, 0.2, 0.2), life: (1.0, 1.6), size: (0.045, 0.025), color: F4(0.7, 0.85, 1.1, 0.85),
                                 gravity: 2, drag: 1)
                }
                if cool <= 0 {
                    cool = 1.1
                    let p = G.point(e, G.length[e] * 0.5)
                    pendingSounds.append((.reload, Vec2(p.x, p.z), 0.4))
                }
            }
            cableRattle[e] = max(0, cool)
        }
        // the Dropper's dry tick-tick from above: the nearest one creeping along a route within 16 m of the player
        tickT -= dt
        if tickT <= 0 {
            tickT = 0.28
            let S = game.bugs, P = game.player
            let drop = UInt8(BugType.dropper.rawValue), high = BugState.high.rawValue
            var bd: Float = 16 * 16
            var at: Vec2? = nil
            for i in 0..<S.count where S.deadFlags[i] == 0 && S.types[i] == drop && S.states[i] == high {
                let vx = S.velocityX[i], vz = S.velocityZ[i]
                if vx * vx + vz * vz < 0.1 { continue }
                let dx = S.xs[i] - P.x, dz = S.zs[i] - P.z, d2 = dx * dx + dz * dz
                if d2 < bd { bd = d2; at = Vec2(S.xs[i], S.zs[i]) }
            }
            if let p = at { pendingSounds.append((.click, p, 0.35)) }
        }
    }

    /// Core events the overhead answers: a drop lands (a puff of frost, a frost ring, rime on the deck), a bug is knocked
    /// off (dust and a little ice shaken loose where it was).
    func handle(_ e: GameEvent, fx: MetalEffects) {
        switch e {
        case .dropLanded(let pos, let hit):
            let y = level.groundY(pos.x, pos.y)
            let p = F3(pos.x, y + 0.15, pos.y)
            fx.gpu.burst(.steam, hit ? 3 : 2, at: p, jitter: F3(0.3, 0.05, 0.3), radial: 1.4, life: (0.5, 0.8), size: (0.5, 1.4),
                         color: F4(0.62, 0.72, 0.84, 0.32), drag: 1.6)
            fx.gpu.burst(.ice, Int(ceilf(10 * fx.fxK)), at: p, sphere: 3.2, upper: true, life: (0.3, 0.6), size: (0.06, 0.03),
                         color: F4(0.8, 1.0, 1.35, 1), gravity: 9, drag: 0.8)
            fx.decals.add(pos.x, pos.y, size: 1.3, cell: .frost, kind: .frost, tint: F3(0.75, 0.86, 0.98), opacity: 0.55)
        case .routeKnockdown(let pos, let h):
            let p = F3(pos.x, level.groundY(pos.x, pos.y) + h, pos.y)
            fx.gpu.burst(.ice, Int(ceilf(12 * fx.fxK)), at: p, jitter: F3(0.3, 0.05, 0.3), sphere: 1.6, life: (0.6, 1.1), size: (0.05, 0.025),
                         color: F4(0.7, 0.85, 1.1, 0.9), gravity: 4, drag: 1)
            fx.gpu.burst(.spark, 2, at: p, sphere: 2.5, life: (0.15, 0.3), size: (0.035, 0.02), color: F4(1.3, 1.1, 0.9, 1), gravity: 10, drag: 1)
        // ---- Stage 1 R4
        case .pinned(_, let pos, _):
            // the Dropper slams onto its marine: frost chips and a cold puff where it holds on
            let p = F3(pos.x, level.groundY(pos.x, pos.y) + 0.3, pos.y)
            fx.gpu.burst(.ice, Int(ceilf(10 * fx.fxK)), at: p, sphere: 2.6, upper: true, life: (0.3, 0.6), size: (0.05, 0.03),
                         color: F4(0.85, 1.0, 1.3, 1), gravity: 8, drag: 0.8)
            fx.gpu.burst(.steam, 2, at: p, jitter: F3(0.2, 0.05, 0.2), radial: 1.0, life: (0.4, 0.7), size: (0.4, 1.0),
                         color: F4(0.62, 0.72, 0.84, 0.3), drag: 1.6)
        case .pinBroken(_, let pos, _, _):
            let p = F3(pos.x, level.groundY(pos.x, pos.y) + 0.35, pos.y)
            fx.gpu.burst(.ice, Int(ceilf(6 * fx.fxK)), at: p, sphere: 2.2, upper: true, life: (0.25, 0.5), size: (0.045, 0.025),
                         color: F4(0.8, 0.95, 1.2, 1), gravity: 8, drag: 0.8)
        case .ductSealed(let k):
            // the grille slams shut: a cold burst, sparks off the slats, a short amber flash going out
            if let G = level.overhead, k < G.ducts.count {
                let (m, out) = mouth(G.ducts[k])
                fx.gpu.burst(.steam, 3, at: m + out * 0.2, jitter: F3(0.2, 0.2, 0.2), vel: out * 1.6, velJitter: F3(0.5, 0.4, 0.5), life: (0.5, 0.9),
                             size: (0.4, 1.1), color: F4(0.62, 0.7, 0.8, 0.35), drag: 1.5)
                fx.gpu.burst(.spark, Int(ceilf(8 * fx.fxK)), at: m + out * 0.15, sphere: 3, life: (0.2, 0.4), size: (0.035, 0.02),
                             color: F4(1.4, 1.0, 0.6, 1), gravity: 9, drag: 1)
                fx.gpu.burst(.ice, Int(ceilf(10 * fx.fxK)), at: m, jitter: F3(0.3, 0.3, 0.3), sphere: 2, life: (0.6, 1.0), size: (0.05, 0.025),
                             color: F4(0.8, 0.95, 1.2, 1), gravity: 6, drag: 0.8)
                fx.flash(m + out * 0.5, F3(1.0, 0.45, 0.1), peak: 60, dur: 0.35, range: 7, priority: 14)
            }
        case .ductOpened(let k):
            // the hive chewed through: dust and ice shaken out of the mouth
            if let G = level.overhead, k < G.ducts.count {
                let (m, out) = mouth(G.ducts[k])
                fx.gpu.burst(.steam, 2, at: m + out * 0.2, jitter: F3(0.2, 0.2, 0.2), vel: out * 1.2, velJitter: F3(0.4, 0.3, 0.4), life: (0.6, 1.0),
                             size: (0.4, 1.0), color: F4(0.55, 0.6, 0.68, 0.3), drag: 1.4)
                fx.gpu.burst(.ice, Int(ceilf(8 * fx.fxK)), at: m, jitter: F3(0.3, 0.3, 0.3), vel: out, sphere: 1.5, life: (0.7, 1.1),
                             size: (0.05, 0.025), color: F4(0.7, 0.8, 0.95, 0.9), gravity: 5, drag: 0.8)
            }
        case .ductHit(let k):
            if let G = level.overhead, k < G.ducts.count {
                let (m, out) = mouth(G.ducts[k])
                fx.gpu.burst(.spark, 2, at: m + out * 0.2, sphere: 2.5, life: (0.12, 0.25), size: (0.03, 0.02), color: F4(1.4, 1.1, 0.8, 1),
                             gravity: 9, drag: 1)
            }
        case .perched(let p):
            fx.gpu.burst(.ice, Int(ceilf(5 * fx.fxK)), at: F3(p.x, p.y - 0.05, p.z), jitter: F3(0.2, 0.03, 0.2), vel: F3(0, -0.6, 0),
                         velJitter: F3(0.3, 0.2, 0.3), life: (1.0, 1.5), size: (0.04, 0.02), color: F4(0.6, 0.72, 0.9, 0.8), gravity: 1.5, drag: 1.2)
        default:
            break
        }
    }

    // ================================================================ static grounding (WorldLevel's world mask, B)
    /// The soft moon shadow of every route on the deck (the moon toward normalize(−25, 60, 35): a point h m above the
    /// deck shadows the deck (+0.42 h, −0.58 h) away): S × S values (0…255) for the world mask's B, which fs_level dims
    /// the ambient and the moonlit albedo with. Zero everywhere on a station without routes.
    static func moonShadow(level: Level, size S: Int) -> [UInt8] {
        var acc = [Float](repeating: 0, count: S * S)
        let L = level.layout.overhead
        if L.isEmpty { return [UInt8](repeating: 0, count: S * S) }
        let off = SIMD2<Float>(25 / 60, -35 / 60)
        func splat(_ x: Float, _ z: Float, _ r: Float, _ v: Float) {
            let px0 = Int(((x - r + GRID_HALF) * 2).rounded(.down)), px1 = Int(((x + r + GRID_HALF) * 2).rounded(.up))
            let pz0 = Int(((z - r + GRID_HALF) * 2).rounded(.down)), pz1 = Int(((z + r + GRID_HALF) * 2).rounded(.up))
            for j in max(0, pz0)...min(S - 1, max(0, pz1)) {
                for i in max(0, px0)...min(S - 1, max(0, px1)) {
                    let tx = Float(i) * 0.5 - GRID_HALF + 0.25, tz = Float(j) * 0.5 - GRID_HALF + 0.25
                    let d = ((tx - x) * (tx - x) + (tz - z) * (tz - z)).squareRoot()
                    if d >= r { continue }
                    let k = j * S + i
                    acc[k] = max(acc[k], v * (1 - smooth01f(d / r)))
                }
            }
        }
        for e in L.edges {
            let a = L.nodes[Int(e.a)].p, b = L.nodes[Int(e.b)].p
            let A = F3(a.x, a.y, a.z), B = F3(b.x, b.y, b.z)
            let len = ((B - A) * (B - A)).sum().squareRoot()
            let (width, strength): (Float, Float)
            switch e.kind {
            case .pipe: (width, strength) = (0.9, 0.5)
            case .cable: (width, strength) = (0.18, 0.22)
            case .tray: (width, strength) = (0.65, 0.35)
            case .catwalk: (width, strength) = (1.0, 0.45)
            case .duct: (width, strength) = (0.9, 0.6)
            }
            let n = max(1, Int((len / 0.4).rounded(.up)))
            for s in 0...n {
                let u = Float(s) / Float(n)
                var p = A + (B - A) * u
                p.y -= 4 * e.sag * u * (1 - u)
                // the deck the shadow lands on (one refinement: the shadow point's own deck height)
                var h = p.y - level.groundY(p.x, p.z)
                var sx = p.x + off.x * h, sz = p.z + off.y * h
                let c = level.cellOf(sx, sz)
                if c < 0 || level.walkValue(c) == 0 { continue }
                h = p.y - level.groundY(sx, sz)
                if h < 1 || h > 14 { continue }
                sx = p.x + off.x * h; sz = p.z + off.y * h
                splat(sx, sz, width / 2 + 0.25 + 0.05 * h, strength * (1 - h / 20))
            }
        }
        // one 3 × 3 box blur (the penumbra)
        var out = [UInt8](repeating: 0, count: S * S)
        for j in 0..<S {
            for i in 0..<S {
                var s: Float = 0
                for dj in -1...1 {
                    for di in -1...1 {
                        let jj = min(S - 1, max(0, j + dj)), ii = min(S - 1, max(0, i + di))
                        s += acc[jj * S + ii]
                    }
                }
                out[j * S + i] = UInt8(clampf(s / 9, 0, 1) * 255)
            }
        }
        return out
    }
}
