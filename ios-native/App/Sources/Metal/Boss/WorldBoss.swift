import Foundation
import CoreGraphics
import Metal
import IceHiveCore

// ================================================================
//  WORLD BOSS — a chain boss on screen (Stage 2 B5 «The Threader in the
//  game»; design §1.5, tech §5.2 «the segment IHV drawn along the path»).
//  B1's chain body is a set of swarm slots that the swarm renderer skips
//  (WorldSwarm: `bugs.bossPart(i) >= 0`); this module draws the boss from
//  B4's state (`Game.bossPart(k)`, `bossBodyPoint(behind:)`,
//  `Game.threader`) with B2's creature files (BossLibrary — the IHV1
//  rigid format of the bugs, IHVLoader) through the swarm's own
//  pipeline and material (Swarm.metal vs_creature / fs_chitin: wet
//  chitin on the full light model, the type's cold rim, HDR glands,
//  the eye channel, sacs, frost, the hit flash):
//    the body  each segment on the chord of the body path between
//              bossBodyPoint(d − 0.8) and (d + 0.8), d = 2 + (j − 1) × 1.6
//              (its `front` / `back` sockets are the shared joints: the
//              body closes on any curve, the 90° turn at a crossing too);
//              the head on its chord from 1.2 m behind to the head point;
//              node k with its segment's transform; the whole body
//              interpolated between ticks by sliding it back along its
//              own path (the head's last step × (1 − alpha))
//    the clips each part's clip from the boss's mode (ThreaderLook.swift),
//              cross-faded from the last pose (0.15 s)
//    the LOD   one LOD per part kind per frame (the largest on screen;
//              B2's switch sizes; Efficient: segments at LOD1 unless
//              they fill ≥ 1.6 × the switch size) — 3 draws per frame
//              (head, segments, nodes: tech §5.2 «the swarm draws grow
//              by up to 3 per boss type and LOD»)
//    the glints the lantern and the node sacs as the swarm's HDR dots
//              (one transparent draw)
//    the cutaway the overhead's rule for a boss over the deck (ctx.md
//              «Readability»): when a part stands in front of a
//              marine, the draws switch to `bossCut` (fs_chitin_cut:
//              the same ≈ 25 % ghost written as MSAA coverage within
//              WorldOverhead.marineRadius of the marine's chest); the
//              squad-visibility metric (`-ohVis`) draws the body too
//              (fs_creature_vis: its cutaway alpha in A)
//    the death `.bossKilled` freezes the last pose of every part and
//              plays the death clips; the body melts into the deck from
//              10 s on (as the swarm's corpses)
//  Draw items: opaque 302 «boss» (after the swarm), transparent 401
//  «boss glints». `hb boss …` once a second (diagnostics), `boss: …`
//  lines at load. Generic for later chain bosses: a BossLibrary row
//  per kind (three files), a look (ThreaderLook) per kind.
// ================================================================

/// The creature files of a chain boss, one per part role (head, segment, node), loaded once per device when a level brings
/// that boss (tools/blender/creatures; IHVLoader's format, B2's raised boss gate).
final class BossLibrary {
    let kind: BossKind
    let head: IHVCreature, segment: IHVCreature, node: IHVCreature
    let summary: String
    private static var cache: [String: BossLibrary] = [:]

    /// The files of each chain boss (head, segment, node).
    static func files(_ kind: BossKind) -> [String]? {
        switch kind {
        case .threader: return ["threader_head", "threader_seg", "threader_node"]
        case .queen: return nil
        }
    }

    static func shared(_ device: MTLDevice, _ kind: BossKind) -> BossLibrary? {
        let key = "\(ObjectIdentifier(device).hashValue)-\(kind.rawValue)"
        if let c = cache[key] { return c }
        guard let names = files(kind) else { return nil }
        let t0 = FrameTimer.now()
        var loaded: [IHVCreature] = []
        for n in names {
            do { loaded.append(try IHVCreature.load(device: device, name: n)) } catch {
                AppLog.error("boss: \(kind.rawValue) \(n): \(error)")
                return nil
            }
        }
        let lib = BossLibrary(kind: kind, files: loaded, ms: (FrameTimer.now() - t0) * 1000)
        cache[key] = lib
        return lib
    }

    private init(kind: BossKind, files f: [IHVCreature], ms: Double) {
        self.kind = kind
        head = f[0]; segment = f[1]; node = f[2]
        let kb = f.reduce(0) { $0 + $1.bytes } / 1024
        var parts: [String] = []
        for c in f {
            let tris = c.lods.map { String($0.triangles) }.joined(separator: "/")
            parts.append("\(c.name) \(tris) tris \(c.clips.count) clips")
        }
        summary = String(format: "boss: %@ files %d KB in %.1f ms: ", kind.rawValue, kb, ms) + parts.joined(separator: ", ")
    }

    /// The part kinds' files in draw order (head, segment, node).
    var parts: [IHVCreature] { [head, segment, node] }
}

/// Stage 2 B5: where a chain boss's body is this frame (world spheres: x, y, z, radius) — HUD.keep keeps banners and toasts
/// off its head and nodes (MetalWorld conforms through WorldBoss).
protocol BossKeepSource: AnyObject {
    var bossSpheres: [SIMD4<Float>] { get }
}

/// One part's transform this frame (the instance's feet = the model origin on the body path).
struct BossPartXf {
    var pos = F3.zero
    var heading: Float = 0
    var pitch: Float = 0
}

/// What one part plays and shows this frame (ThreaderLook fills it, WorldBoss packs it into a CreatureInstance).
struct BossPartPose {
    var a = ClipSample.zero
    var b = ClipSample.zero
    var wB: Float = 0
    /// Instance channels: hit flash, frost, dead (0…1), glow boost (0…1), head look yaw / pitch (rad).
    var flash: Float = 0, frost: Float = 0, dead: Float = 0, boost: Float = 0
    var lookY: Float = 0, lookP: Float = 0
}

final class WorldBoss {
    static let pipelines: [PipelineSpec] = [
        // the boss's body near a marine: fs_chitin with the overhead's cutaway as MSAA coverage (Swarm.metal fs_chitin_cut)
        .world("bossCut", "vs_creature", "fs_chitin_cut"),
    ]
    /// Parts of a chain boss drawn at most (the head, 18 segments, 5 nodes = 24; B1's BOSS_PARTS bound).
    static let maxParts = BOSS_PARTS
    /// The swarm type slots the three part kinds take in the boss's own SwarmParams (Swarm.metal kBodyLift: 1.15 head,
    /// 1.2 segment, 1.0 node — B2's «albedo lift 1.0–1.2»; slots 0 / 1 stay empty).
    static let typeSlot: [Int] = [2, 3, 4]
    /// Seconds the body lies dead before it melts into the deck (the swarm's corpses: 9), its sink speed (m/s).
    static let corpseSinkAfter: Float = 10, sinkSpeed: Float = 0.14
    /// Efficient tier: a segment keeps LOD0 only above this many times its switch size (B2: 85–160 px at the game camera —
    /// LOD1 on Efficient there, the LOD pop measured 2.6 luma at the game camera: 54.0 / 56.6).
    static let efficientSegK: Float = 1.6
    /// `-bossLOD 0|1|2`: every part at that LOD (look-dev A/B); `-noBossDraw`: the boss's draws skipped (device A/B).
    static let forcedLOD: Int? = {
        let a = LaunchOptions.current.unknown
        guard let i = a.firstIndex(of: "-bossLOD"), i + 1 < a.count, let k = Int(a[i + 1]) else { return nil }
        return max(0, min(2, k))
    }()
    static let noDraw = LaunchOptions.current.unknown.contains("-noBossDraw")

    let level: Level
    /// The boss arena's pieces (the Manifold's trunks: where the body's path runs on past a trunk's end — `emerge`).
    private let arena: ManifoldArena?
    /// The overhead layer (MetalWorld sets it): the Manifold's trunks it hides, shakes and drops (WorldOverhead.setTrunk).
    weak var overhead: WorldOverhead?
    private var renderer: MetalRenderer!
    private(set) var library: BossLibrary?
    private var psSolid: MTLRenderPipelineState?, psCut: MTLRenderPipelineState?, psGlint: MTLRenderPipelineState?
    private var device: MTLDevice?
    /// The look of the kind on screen (clips by mode, the lure, the telegraphs' extras): the Threader's.
    private(set) var look: ThreaderLook?
    // ---- the boss's own swarm tables
    private var params: SwarmParams
    private var lookPivots = [F4](repeating: .zero, count: 2 * WorldSwarm.types)
    private var glintTable: [GlintSocket] = []
    private var glintFirst = [Int](repeating: 0, count: 3), glintPer = [Int](repeating: 0, count: 3)
    // ---- this frame
    /// Per part (0 the head, 1… the segments, then the nodes): its transform, its kind (0 head, 1 segment, 2 node).
    private(set) var xf = [BossPartXf](repeating: BossPartXf(), count: WorldBoss.maxParts)
    private(set) var kinds = [Int](repeating: 1, count: WorldBoss.maxParts)
    private(set) var partCount = 0
    private var poses = [BossPartPose](repeating: BossPartPose(), count: WorldBoss.maxParts)
    private var inst = [CreatureInstance]()
    /// This frame's draws: per kind its LOD and arena region; the glint block.
    private var lod = [Int](repeating: 0, count: 3), lodPrev = [Int](repeating: 0, count: 3)
    private var regions = [Region](repeating: Region(), count: 3)
    private var glintRegion = Region()
    private var glintCount = 0
    /// The cutaway: on this frame (a part in front of a marine), the block for fs_chitin_cut.
    private(set) var cutOn = false
    private var cut = [F4](repeating: .zero, count: WorldBoss.Cut.count)
    private var cutRegion = Region()
    /// The boss is drawn this frame (alive or dying), its triangles, the frames the cut ran (hb).
    private(set) var drawn = false
    private var tris = 0, cutFrames = 0, frames = 0
    private var lastLog: Double = 0
    private(set) var clock: Float = 0
    private var gameID: ObjectIdentifier?
    /// The body's last frame alive (the death holds it); dying since `deathT` (clock), -1 alive / none.
    private var deathT: Float = -1
    private var buildMs: Double = 0

    /// Layout of the cut block (Swarm.metal `struct SwarmCut`): view, cut, 8 points, 8 radii.
    enum Cut {
        static let view = 0, cut = 1, pts = 2, rad = 10, count = 18
    }

    init(level: Level) {
        self.level = level
        arena = level.layout.manifold
        let z = SwarmTypeGPU(rim: .zero, eye: .zero, sac: .zero, gland: .zero, proxy: .zero, glint: .zero)
        params = SwarmParams(types: (z, z, z, z, z), info: .zero, queen: .zero)
        inst.reserveCapacity(WorldBoss.maxParts * 2)
    }

    /// Pipelines (the swarm's and the boss's cut), the draw items; the boss's files when the level is its arena (MetalWorld,
    /// once — the Manifold loads the Threader under the loading cover, any other level on its first frame with a chain boss).
    func attach(_ r: MetalRenderer) {
        renderer = r
        device = r.device
        psSolid = r.pipeline("creature"); psCut = r.pipeline("bossCut"); psGlint = r.pipeline("swarmGlint")
        if level.layout.manifold != nil { load(.threader) }
        r.register(.opaque, order: 302, "boss") { [unowned self] enc in self.encode(enc) }
        r.register(.transparent, order: 401, "boss glints") { [unowned self] enc in self.encodeGlints(enc) }
    }

    private func load(_ kind: BossKind) {
        guard library?.kind != kind, let dev = device else { return }
        guard let lib = BossLibrary.shared(dev, kind) else { return }
        library = lib
        look = ThreaderLook(library: lib)
        AppLog.info(lib.summary)
        buildTables(lib)
    }

    /// The type table of the three kinds (B2's colours), their look pivots (`neck`), the glint sockets (the lantern, the sacs).
    private func buildTables(_ lib: BossLibrary) {
        let T = ThreaderLook.self
        func ty(_ k: Int, glint: SIMD4<UInt32>) -> SwarmTypeGPU {
            SwarmTypeGPU(rim: T.rim, eye: T.eye, sac: T.sac, gland: T.gland, proxy: F4(0.5, 0.3, 1.0, 0.2), glint: glint)
        }
        glintTable.removeAll()
        lookPivots = [F4](repeating: .zero, count: 2 * WorldSwarm.types)
        for (k, c) in lib.parts.enumerated() {
            let slot = WorldBoss.typeSlot[k]
            if let n = c.sockets.first(where: { $0.name == "neck" }) { lookPivots[slot] = F4(n.rest.x, n.rest.y, n.rest.z, 1) }
            let g = c.sockets.filter { $0.glint }.sorted { ($0.intensity, $0.radius) > ($1.intensity, $1.radius) }.prefix(2)
            glintFirst[k] = glintTable.count
            glintPer[k] = g.count
            // (the head group of the head: every bone of the head file turns with the look — B2: «head group = the head bone
            // and its children»; w = bone + 256 × group)
            for s in g {
                let grp: Float = k == 0 ? 1 : 0
                glintTable.append(GlintSocket(pos: F4(s.rest.x, s.rest.y, s.rest.z, Float(s.bone) + 256 * grp),
                                              info: F4(s.radius, s.intensity, s.hot ? 1 : 0, 0.3 * Float(k))))
            }
        }
        let z = SWarmZero.type
        params.types = (z, z, ty(0, glint: .zero), ty(1, glint: .zero), ty(2, glint: .zero))
        params.info = F4(0, 0, 1.5, 1.1)
        params.queen = .zero
    }

    /// GameScene's events (through MetalWorld): the boss's death, its cues for the look (screams, pops).
    func handle(_ e: GameEvent, game: Game, fx: MetalEffects) {
        switch e {
        case .bossKilled(let kind, _) where kind == library?.kind && partCount > 0:
            deathT = clock
            look?.died(at: clock)
            AppLog.info(String(format: "boss: %@ dies — the death clips from t=%.1f (%d parts)", kind.rawValue, game.time, partCount))
        default: break
        }
        look?.handle(e, game: game, clock: clock, fx: fx, boss: self)
    }

    // ================================================================ per frame
    /// This frame's parts, poses, instances, LODs and the cutaway (MetalWorld.update, after the swarm). `cones`: the lure's
    /// volume cone goes there (VolumeCones.lure).
    func build(game: Game, alpha: Float, time: Float, dt: Float, camera: MetalCamera, poses squad: [MetalEffects.MarinePose],
               fx: MetalEffects, cones: VolumeCones) {
        let t0 = FrameTimer.now()
        defer { buildMs += ((FrameTimer.now() - t0) * 1000 - buildMs) * 0.1 }
        drawn = false
        cutOn = false
        glintCount = 0
        cones.lure = nil
        Occupancy.extra.removeAll(keepingCapacity: true)
        for k in 0..<3 { regions[k] = Region() }
        clock += dt
        let gid = ObjectIdentifier(game)
        if gid != gameID {
            // a new sortie: nothing of the last one's boss
            gameID = gid
            deathT = -1
            partCount = 0
            look?.reset()
        }
        trunks(game: game)
        let alive = game.boss.alive && game.bossPartCount > 0 && BossLibrary.files(game.boss.kind) != nil
        if alive && library?.kind != game.boss.kind { load(game.boss.kind) }
        guard let lib = library, let L = look, let r = renderer else { return }
        if alive {
            if deathT >= 0 { deathT = -1; L.reset() }
            guard layBody(game, alpha: alpha) else { return }
            // (the look writes each part's pose through setPose — never `&poses` across the call: it reads the head's pose
            // back through worldPoint while it runs, the lantern and the dust sockets, and an inout borrow of the array for the
            // whole call would trap on that read: Swift's exclusivity check)
            L.frame(game: game, boss: self, clock: clock, dt: dt, camera: camera, fx: fx, cones: cones)
        } else if deathT >= 0 && partCount > 0 && game.boss.kind == lib.kind {
            L.dying(boss: self, clock: clock, since: clock - deathT)
            // melts into the deck after a while (the swarm's corpses), gone once it is under
            let sink = max(0, clock - deathT - WorldBoss.corpseSinkAfter) * WorldBoss.sinkSpeed
            if sink > 3 { partCount = 0; return }
            for k in 0..<partCount { xf[k].pos.y -= sink - L.sunk; }
            L.sunk = sink
        } else {
            if partCount > 0 && !alive { partCount = 0 }
            return
        }
        writeInstances(lib, camera: camera, high: r.frameTier == .high)
        cutaway(game: game, camera: camera, poses: squad)
        drawn = true
        frames += 1
        if cutOn { cutFrames += 1 }
        heartbeat(game)
    }

    /// The Manifold's trunks this frame (WorldOverhead.setTrunk): the one being ripped down shakes through its warning and
    /// falls in the last 0.4 s; the fallen one lies on the deck (B4's `fallenTrunk`, until a new sortie restores the level).
    private func trunks(game: Game) {
        guard let A = level.layout.manifold, let oh = overhead else { return }
        let thr = game.boss.kind == .threader && game.boss.spawned
        let v = thr ? game.threader : nil
        for t in 0..<A.trunks.count {
            var shake: Float = 0, fall: Float = -1
            if let v = v {
                if t == v.fallenTrunk { fall = 1 }
                else if t == v.pullTrunk && v.pullT >= 0 {
                    shake = 0.05 * min(1, (THREADER_PULL_WARN - v.pullT) / 0.6)
                    if v.pullT < 0.4 { fall = 1 - v.pullT / 0.4 }
                }
            }
            oh.setTrunk(t, shake: shake, fall: fall, time: clock)
        }
    }

    /// The parts' transforms from the body path: the head on its chord, the segments on theirs, the nodes on their segments.
    /// False when the path is not there (no chain boss).
    private func layBody(_ game: Game, alpha: Float) -> Bool {
        let n = min(WorldBoss.maxParts, game.bossPartCount)
        guard n > 1 else { return false }
        // the head's last step (its slot's velocity × the tick): the body slides back along its own path by (1 − alpha) of it
        let hv = game.bossPart(0)
        var lag: Float = 0
        if hv.slot >= 0 {
            let S = game.bugs
            let vx = S.velocityX[hv.slot], vz = S.velocityZ[hv.slot]
            let step = (vx * vx + vz * vz).squareRoot() * SIM_DT
            if step < 1.5 { lag = (1 - max(0, min(1, alpha))) * step }
        }
        func pt(_ d: Float) -> F3? {
            guard let p = game.bossBodyPoint(behind: d) else { return nil }
            return emerge(F3(p.position.x, p.position.y, p.position.z))
        }
        guard let H = pt(lag), let HB = pt(lag + 1.2) else { return false }
        xf[0] = WorldBoss.chord(front: H, back: HB, at: H, fallback: game.bossPart(0).heading)
        kinds[0] = 0
        var segs = 0
        var q = 1
        // (a vertical chord — the body climbing a riser — keeps the heading of the part in front of it)
        var lastHd = xf[0].heading
        while q < n {
            let v = game.bossPart(q)
            switch v.role {
            case .segment:
                let d = 2 + Float(v.segment - 1) * 1.6 + lag
                if let f = pt(max(0, d - 0.8)), let b = pt(d + 0.8) {
                    xf[q] = WorldBoss.chord(front: f, back: b, at: (f + b) * 0.5, fallback: lastHd)
                    lastHd = xf[q].heading
                }
                kinds[q] = 1
                segs += 1
            case .node:
                // its segment's transform (the segments come first: part s is segment s)
                let s = max(1, min(n - 1, v.segment))
                xf[q] = xf[s]
                kinds[q] = 2
            case .head:
                kinds[q] = 0
            }
            q += 1
        }
        partCount = n
        return segs > 0
    }

    /// An instance on the chord front ← back placed at `at`: heading and pitch along the chord (Swarm.metal placeOffset); a
    /// (near) vertical chord takes `fallback` as its heading (its back then faces away from that heading).
    @inline(__always) static func chord(front f: F3, back b: F3, at p: F3, fallback: Float = 0) -> BossPartXf {
        let d = f - b
        let h = (d.x * d.x + d.z * d.z).squareRoot()
        let l = max(1e-5, (d * d).sum().squareRoot())
        return BossPartXf(pos: p, heading: h > 0.02 * l ? atan2f(d.x, d.z) : fallback, pitch: atan2f(d.y, max(h, 1e-5)))
    }

    /// The body's path where it runs on past a trunk's end, as drawn. The core seeds a chain's history straight behind its
    /// head at the spawn (GameBossBody.bossSpawnChain), and the Threader comes out at a trunk's leg 2.5 m from that trunk's
    /// abyss riser: for its first seconds ~27 m of its body would hang level over the abyss beyond the trunk's end. Drawn,
    /// that stretch bends over the riser's elbow (B2's `mf_trunk_elbow`: its outer face a quarter circle of 0.9 + 0.45 m
    /// round the bend's centre 1.35 m under the route line) and on down the riser pipe's outer face — the body climbs out
    /// of the abyss. Every other point of the path as it is. (Render only: the parts' slots and hit circles are the core's.)
    private func emerge(_ p: F3) -> F3 {
        guard let A = arena else { return p }
        let R = ManifoldBuild.elbowR + ManifoldBuild.trunkR
        for tr in A.trunks {
            if abs(p.y - tr.y) > 0.6 { continue }
            let half = tr.length / 2
            let m = tr.point(half)
            let dx = p.x - m.x, dz = p.z - m.y
            let u = dx * tr.dir.x + dz * tr.dir.y
            let v = dz * tr.dir.x - dx * tr.dir.y
            if abs(v) > 0.6 || abs(u) <= half { continue }
            let s: Float = u > 0 ? 1 : -1
            let b = abs(u) - half
            let q = b / R
            var out = R, y = tr.y - R - (b - R * Float.pi / 2)
            if q <= Float.pi / 2 { out = R * sinf(q); y = tr.y - R + R * cosf(q) }
            let along = s * (half + out)
            return F3(m.x + tr.dir.x * along - tr.dir.y * v, y, m.y + tr.dir.y * along + tr.dir.x * v)
        }
        return p
    }

    /// ThreaderLook: part `k`'s pose this frame (its clips, channels and look).
    func setPose(_ k: Int, _ p: BossPartPose) {
        if k >= 0 && k < poses.count { poses[k] = p }
    }

    /// Part `k`'s socket `name` in the world: its rest point (the head group turned by the part's look), then its bones at
    /// clip A of the pose set for it this frame (setPose).
    func worldPoint(_ k: Int, socket name: String) -> F3? {
        guard let lib = library, k < partCount else { return nil }
        let c = lib.parts[kinds[k]]
        guard let s = c.sockets.first(where: { $0.name == name }) else { return nil }
        let P = poses[k]
        var rest = s.rest
        if kinds[k] == 0 && (P.lookY != 0 || P.lookP != 0) {
            let pv = lookPivots[WorldBoss.typeSlot[0]]
            rest = WorldBoss.lookTurn(rest, pivot: F3(pv.x, pv.y, pv.z), yaw: P.lookY, pitch: P.lookP)
        }
        let a = P.a
        let m = c.socketPoint(IHVSocket(name: s.name, bone: s.bone, flags: s.flags, rest: rest), Int(a.rows & 0xffff), Int(a.rows >> 16), a.frac)
        return WorldBoss.place(xf[k], m)
    }

    /// Swarm.metal lookTurn on the CPU: yaw about the model's up, then pitch about its side (nose up), about the pivot.
    static func lookTurn(_ p: F3, pivot: F3, yaw: Float, pitch: Float) -> F3 {
        let cy = cosf(yaw), sy = sinf(yaw), cp = cosf(pitch), sp = sinf(pitch)
        var q = p - pivot
        q = F3(cy * q.x + sy * q.z, q.y, -sy * q.x + cy * q.z)
        q = F3(q.x, cp * q.y + sp * q.z, -sp * q.y + cp * q.z)
        return pivot + q
    }

    /// Swarm.metal placeOffset (scale 1, no lean): model → world.
    @inline(__always) static func place(_ t: BossPartXf, _ p: F3) -> F3 {
        let c = cosf(t.heading), sn = sinf(t.heading), sp = sinf(t.pitch), cp = cosf(t.pitch)
        let ax = F3(c, 0, -sn), ay = F3(-sn * sp, cp, -c * sp), az = F3(sn * cp, sp, c * cp)
        return t.pos + ax * p.x + ay * p.y + az * p.z
    }

    /// The model-space forward (+z) of part `k` in the world.
    func forward(_ k: Int) -> F3 {
        let t = xf[k]
        let cp = cosf(t.pitch)
        return F3(sinf(t.heading) * cp, sinf(t.pitch), cosf(t.heading) * cp)
    }

    // ---------------------------------------------------------------- instances, LODs
    private func writeInstances(_ lib: BossLibrary, camera: MetalCamera, high: Bool) {
        guard let r = renderer else { return }
        inst.removeAll(keepingCapacity: true)
        var maxPx = [Float](repeating: 0, count: 3)
        let eye = camera.eye, fwd = camera.forward, pxScale = camera.pxScale
        var count = [0, 0, 0]
        for k in 0..<partCount { count[kinds[k]] += 1 }
        // contiguous by kind: heads, segments, nodes
        for kind in 0..<3 {
            let c = lib.parts[kind]
            for k in 0..<partCount where kinds[k] == kind {
                let t = xf[k], P = poses[k]
                let depth = max(0.5, ((t.pos - eye) * fwd).sum())
                maxPx[kind] = max(maxPx[kind], c.length * pxScale / depth)
                let ty = UInt32(WorldBoss.typeSlot[kind])
                // (SwarmTypes.h CreatureInstance: anim = rows A, rows B, fracs, weight B | type << 16 (no instance flags);
                // fx = hit flash | frost << 16 | dead << 24, no lean, seed | glow boost << 16, the head's look)
                let fracs: UInt32 = unorm16(P.a.frac) | (unorm16(P.b.frac) << 16)
                let wty: UInt32 = unorm16(P.wB) | (ty << 16)
                let state: UInt32 = unorm8(P.flash) | (unorm8(P.frost) << 16) | (unorm8(P.dead) << 24)
                let seed: UInt32 = unorm16(0.37 + 0.11 * Float(k % 5)) | (unorm16(P.boost) << 16)
                let look: UInt32 = kind == 0 ? WorldSwarm.packLook(P.lookY, P.lookP, 0) : 0
                let rot = F4(cosf(t.heading), sinf(t.heading), sinf(t.pitch), cosf(t.pitch))
                inst.append(CreatureInstance(pos: F4(t.pos.x, t.pos.y, t.pos.z, 1), rot: rot, tint: F4(1, 1, 1, 1),
                                             anim: SIMD4<UInt32>(P.a.rows, P.b.rows, fracs, wty),
                                             fx: SIMD4<UInt32>(state, 0, seed, look)))
            }
        }
        // one LOD per kind: the largest on screen against B2's switch sizes, ±12 % hysteresis
        tris = 0
        for kind in 0..<3 {
            let L = lib.parts[kind].lods
            var l = 2
            let px = maxPx[kind]
            let k0: Float = (!high && kind == 1) ? WorldBoss.efficientSegK : 1
            let s0 = L[0].switchPx * k0, s1 = L.count > 1 ? L[1].switchPx : 0
            // (±12 % hysteresis on the last frame's LOD: no flicker at a threshold)
            if px >= s0 * (lodPrev[kind] == 0 ? 0.88 : 1.12) { l = 0 } else if px >= s1 * (lodPrev[kind] <= 1 ? 0.88 : 1.12) { l = 1 }
            if let f = WorldBoss.forcedLOD { l = f }
            l = min(l, L.count - 1)
            lod[kind] = l
            lodPrev[kind] = l
            tris += L[l].triangles * count[kind]
        }
        guard !inst.isEmpty, let a = r.alloc(CreatureInstance.self, inst.count) else { return }
        a.0.update(from: inst, count: inst.count)
        var o = 0
        for kind in 0..<3 {
            regions[kind] = Region(offset: a.1 + o * MemoryLayout<CreatureInstance>.stride, count: count[kind])
            o += count[kind]
        }
        // the glint block: the head (its lantern, dimmed while the lure is off — the glint shader's frost byte) and the nodes
        let nodes = count[2]
        let heads = count[0]
        guard heads + nodes > 0, let g = r.alloc(CreatureInstance.self, heads + nodes) else { return }
        var gi = 0
        let lureOn = look?.lureLit ?? false
        let frostMask: UInt32 = 0xff << 16
        for k in 0..<inst.count {
            let kind = Int((inst[k].anim.w >> 16) & 0xff) - WorldBoss.typeSlot[0]
            if kind == 1 { continue }
            var c = inst[k]
            // (the lantern dimmed while the lure is off: the glint shader takes × (1 − frost), the body keeps its own byte)
            if kind == 0 && !lureOn { c.fx.x = (c.fx.x & ~frostMask) | (unorm8(0.85) << 16) }
            g.0[gi] = c
            gi += 1
        }
        glintRegion = Region(offset: g.1, count: gi)
        let perHead = UInt32(glintPer[0]), perNode = UInt32(glintPer[2])
        let gHead = UInt32(heads) * perHead
        // the swarm glint shader's cumulative ranges: types 0 / 1 empty at 0, the head (2) from 0, the segments (3) empty, the
        // nodes (4) after the head's
        let z = SIMD4<UInt32>(0, 0, 0, 0)
        params.types.0.glint = z
        params.types.1.glint = z
        params.types.2.glint = SIMD4(UInt32(glintFirst[0]), perHead, 0, 0)
        params.types.3.glint = SIMD4(UInt32(glintFirst[1]), 0, gHead, UInt32(heads))
        params.types.4.glint = SIMD4(UInt32(glintFirst[2]), perNode, gHead, UInt32(heads))
        glintCount = Int(gHead + UInt32(nodes) * perNode)
        params.info = F4(clock, 0, 1.5, 1.1)
    }

    // ---------------------------------------------------------------- the cutaway
    /// The marines' cut points (WorldOverhead's rule: a chest point, the depth of the feet + 1 m, the overhead's radii kept at
    /// their game-camera size in a close shot), and whether any part stands in front of one this frame.
    private func cutaway(game: Game, camera: MetalCamera, poses: [MetalEffects.MarinePose]) {
        guard let r = renderer else { return }
        let vp = camera.viewProj
        let tanHalf = tanf(camera.fov * Float.pi / 360)
        cut[Cut.view] = F4(2 / Float(max(1, r.targetWidth)), 2 / Float(max(1, r.targetHeight)), camera.aspect, WorldOverhead.ghost)
        var n = 0
        let rad = WorldOverhead.marineRadius
        for k in 0..<min(game.marines.count, poses.count) where n < 8 {
            let p = poses[k]
            let c = vp.point(p.x, p.y + 1.1, p.z)
            guard c.w > 0.5 else { continue }
            let z = vp.point(p.x, p.y, p.z).w + 1.0
            let s = min(3, max(1, MetalCamera.halfHeight / (c.w * tanHalf)))
            cut[Cut.pts + n] = F4(c.x / c.w * camera.aspect, c.y / c.w, z, 1)
            cut[Cut.rad + n] = F4(rad.0 * s, rad.1 * s, 0, 0)
            n += 1
        }
        cut[Cut.cut] = F4(WorldOverhead.eyeFade.0, WorldOverhead.eyeFade.1, Float(n), 0.3)
        // any part in front of a cut point, within its outer radius + the part's own size on screen?
        var near = false
        if n > 0, let lib = library {
            let halfH = Float(max(1, r.targetHeight)) / 2
            outer: for k in 0..<partCount {
                let t = xf[k]
                let c = vp.point(t.pos.x, t.pos.y + 0.3, t.pos.z)
                guard c.w > 0.3 else { near = true; break }
                let sx = c.x / c.w * camera.aspect, sy = c.y / c.w
                let size = lib.parts[kinds[k]].length * 0.6 * camera.pxScale / c.w / halfH
                for i in 0..<n {
                    let p = cut[Cut.pts + i], rr = cut[Cut.rad + i].y
                    let dx = sx - p.x, dy = sy - p.y
                    if dx * dx + dy * dy < (rr + size) * (rr + size) && c.w < p.z + 1.5 { near = true; break outer }
                }
                if c.w < WorldOverhead.eyeFade.1 + 2 { near = true; break }
            }
        }
        cutOn = near && psCut != nil
        cutRegion = cutOn ? r.upload(cut) : Region()
    }

    // ---------------------------------------------------------------- draws
    private func bindCommon(_ enc: MTLRenderCommandEncoder) {
        var P = params
        enc.setVertexBytes(&P, length: MemoryLayout<SwarmParams>.stride, index: 3)
        enc.setFragmentBytes(&P, length: MemoryLayout<SwarmParams>.stride, index: 3)
        lookPivots.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 7) }
    }

    /// Opaque item 302: one instanced draw per part kind at its LOD (the head, the segments, the nodes).
    private func encode(_ enc: MTLRenderCommandEncoder) {
        guard drawn, !WorldBoss.noDraw, let lib = library, let r = renderer else { return }
        guard let ps = cutOn ? psCut : psSolid else { return }
        r.use(enc, ps)
        bindCommon(enc)
        if cutOn { enc.setFragmentBuffer(r.arena, offset: cutRegion.offset, index: 6) }
        for kind in 0..<3 where regions[kind].count > 0 {
            let c = lib.parts[kind]
            let L = c.lods[min(lod[kind], c.lods.count - 1)]
            enc.setVertexTexture(c.boneTexture, index: 6)
            enc.setVertexBuffer(c.buffer, offset: c.glowOffset, index: 4)
            enc.setVertexBuffer(c.buffer, offset: L.vertexOffset, index: BufferIndex.vertices)
            enc.setVertexBuffer(r.arena, offset: regions[kind].offset, index: BufferIndex.instances)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: L.indexCount, indexType: L.indexType, indexBuffer: c.buffer,
                                      indexBufferOffset: L.indexOffset, instanceCount: regions[kind].count)
            r.count(instances: regions[kind].count, triangles: L.triangles * regions[kind].count)
        }
    }

    /// Transparent item 401: the lantern and the node sacs as HDR dots (the swarm's glint shader, the boss's tables).
    private func encodeGlints(_ enc: MTLRenderCommandEncoder) {
        guard drawn, glintCount > 0, !WorldBoss.noDraw, let ps = psGlint, let lib = library, !glintTable.isEmpty, let r = renderer else { return }
        r.use(enc, ps)
        var P = params
        enc.setVertexBytes(&P, length: MemoryLayout<SwarmParams>.stride, index: 3)
        glintTable.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 10) }
        lookPivots.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 7) }
        // the glint shader's per-type textures / glow tables 6–10 / 11–15: the three kinds in slots 2–4, the head's in 0 / 1
        let files = [lib.head, lib.head, lib.head, lib.segment, lib.node]
        for t in 0..<WorldSwarm.types {
            enc.setVertexTexture(files[t].boneTexture, index: 6 + t)
            enc.setVertexBuffer(files[t].buffer, offset: files[t].glowOffset, index: 11 + t)
        }
        enc.setVertexBuffer(r.arena, offset: glintRegion.offset, index: BufferIndex.instances)
        r.drawQuads(enc, glintCount)
    }

    /// The squad-visibility metric's mask (OverheadVisibility, `-ohVis`): the body with its cutaway alpha into A (max blend,
    /// depth-tested against the deck and the marines' proxies), at the mask's viewport `w` × `h`.
    func encodeVis(_ enc: MTLRenderCommandEncoder, pipeline ps: MTLRenderPipelineState, w: Int, h: Int) {
        guard drawn, let lib = library, let r = renderer else { return }
        var c = cut
        c[Cut.view].x = 2 / Float(max(1, w))
        c[Cut.view].y = 2 / Float(max(1, h))
        enc.setRenderPipelineState(ps)
        bindCommon(enc)
        c.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 6) }
        for kind in 0..<3 where regions[kind].count > 0 {
            let f = lib.parts[kind]
            let L = f.lods[min(lod[kind], f.lods.count - 1)]
            enc.setVertexTexture(f.boneTexture, index: 6)
            enc.setVertexBuffer(f.buffer, offset: f.glowOffset, index: 4)
            enc.setVertexBuffer(f.buffer, offset: L.vertexOffset, index: BufferIndex.vertices)
            enc.setVertexBuffer(r.arena, offset: regions[kind].offset, index: BufferIndex.instances)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: L.indexCount, indexType: L.indexType, indexBuffer: f.buffer,
                                      indexBufferOffset: L.indexOffset, instanceCount: regions[kind].count)
        }
    }

    /// Where a round that hit near (x, z) along (dx, dz) meets the body drawn this frame: the nearest part (plan) within its
    /// size, on its plates toward the shooter (MetalEffects.bulletHit — the swarm's impact point does not know the boss).
    func impactPoint(x: Float, z: Float, dx: Float, dz: Float) -> (pos: F3, normal: F3, ichor: F3)? {
        guard drawn, deathT < 0 else { return nil }
        var best: Float = .greatestFiniteMagnitude
        var bk = -1
        for k in 0..<partCount {
            let p = xf[k].pos
            let r: Float = kinds[k] == 0 ? 1.6 : 1.0
            let ex = p.x - x, ez = p.z - z, d2 = ex * ex + ez * ez
            if d2 < r * r && d2 < best { best = d2; bk = k }
        }
        guard bk >= 0 else { return nil }
        let l = max(1e-4, (dx * dx + dz * dz).squareRoot())
        let up: Float = kinds[bk] == 0 ? 0.6 : (kinds[bk] == 2 ? 0.9 : 0.35)
        let n = F3(-dx / l, 0.3, -dz / l)
        return (xf[bk].pos + F3(-dx / l * 0.45, up, -dz / l * 0.45), n / (n * n).sum().squareRoot(), ThreaderLook.ichor)
    }

    /// The head, the nodes and every third segment as spheres (x, y, z, radius) — what a banner or a toast must not cover
    /// (HUD.keep). Empty while nothing is drawn.
    var keepSpheres: [SIMD4<Float>] {
        guard drawn, partCount > 0 else { return [] }
        var out: [SIMD4<Float>] = []
        for k in 0..<partCount where kinds[k] != 1 || k % 3 == 0 {
            let p = xf[k].pos
            out.append(SIMD4(p.x, p.y, p.z, kinds[k] == 0 ? 2.6 : (kinds[k] == 2 ? 1.2 : 1.0)))
        }
        return out
    }

    /// The sounds the boss asked for since the last call (GameScene plays them: AudioEngine.playBoss).
    func takeSounds() -> [(BossSound, Vec2, Bool, Float)] { look?.takeSounds() ?? [] }

    private func heartbeat(_ game: Game) {
        guard AppLog.diagnostics else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        let kindName = library?.kind.rawValue ?? "-"
        let draws = regions.filter { $0.count > 0 }.count
        var line = "hb boss \(kindName) parts=\(partCount) lod=\(lod[0])/\(lod[1])/\(lod[2]) tris=\(tris)"
        line += " draws=\(draws)+\(glintCount > 0 ? 1 : 0) glints=\(glintCount) cut=\(cutFrames)/\(frames)"
        line += String(format: " build=%.3fms", buildMs)
        if game.boss.alive {
            let v = game.threader
            let lure = v.lure ? (v.locked >= 0 ? "locked" : "on") : "off"
            line += " mode=\(v.mode) lure=\(lure)"
        } else if deathT >= 0 {
            line += " dying"
        }
        line += look?.heartbeatTail ?? ""
        if WorldBoss.noDraw { line += " off" }
        AppLog.info(line)
        cutFrames = 0
        frames = 0
    }
}

/// A zero type row (the boss's empty slots 0 / 1).
private enum SWarmZero {
    static let type = SwarmTypeGPU(rim: .zero, eye: .zero, sac: .zero, gland: .zero, proxy: .zero, glint: .zero)
}
