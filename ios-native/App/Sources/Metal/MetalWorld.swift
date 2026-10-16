import Foundation
import Metal
import IceHiveCore

// ================================================================
//  METAL WORLD — the world of the game: GameScene (simulation loop,
//  events, HUD, audio, demos) calls update() once per display-link
//  tick; it always moves the web camera (the HUD projects through it)
//  and, when FrameLoop holds a free frame slot, builds the frame:
//  poses the squad (renderMarines), writes the swarm instances per bug
//  type with a CPU frustum cull (writeBugInstances), runs the effects
//  (renderFx), fills the lights and uploads everything into the frame
//  arena; FrameLoop encodes and presents it. Without a slot (the GPU
//  is behind) nothing is built and the time carries over to the next
//  drawn frame, so effects do not slow down.
// ================================================================
/// Meshes, textures and pipelines, started when the view controller loads its view (before the scene's first frame);
/// the scene picks the result up behind its loading cover.
final class MetalPreload {
    let started = FrameTimer.now()
    private(set) var finished: Double = 0
    private var done = false
    private var result: (MeshStore, MetalRenderer)?
    private var waiters: [((MeshStore, MetalRenderer)?) -> Void] = []

    /// `fail`: `-failMetal` (CI): report Metal as unusable without trying, to exercise the failure screen.
    init(device: MTLDevice, queue: MTLCommandQueue, fail: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let r = fail ? nil : MetalWorld.prepare(device: device, queue: queue) { AppLog.info($0) }
            DispatchQueue.main.async { [self] in
                result = r
                done = true
                finished = FrameTimer.now()
                let w = waiters
                waiters.removeAll()
                for f in w { f(r) }
            }
        }
    }

    /// Main thread: `f` runs once everything is loaded (immediately when it already is).
    func whenReady(_ f: @escaping ((MeshStore, MetalRenderer)?) -> Void) {
        if done { f(result) } else { waiters.append(f) }
    }
}

final class MetalWorld: HUDProjection {
    let level: Level
    let store: MeshStore
    let renderer: MetalRenderer
    let camera = MetalCamera()
    let fx: MetalEffects
    /// cam = camera + visible quad, mar = squad poses, bug = swarm instances, fx = effects, up = uploads + lights
    let timer = FrameTimer(["cam", "mar", "bug", "fx", "up"])

    private var poses = [MetalEffects.MarinePose](repeating: MetalEffects.MarinePose(x: 0, y: 0, z: 0), count: 4)
    private var walkPh: [Float] = [0, 0, 0, 0]
    private var aimVis: [Float] = [0, 0, 0, 0]
    private var aimInit = false
    private var gunSpin: [Float] = [0, 0, 0, 0]
    /// [class rawValue] → body, leg, gun
    private var marineBatches: [[MeshBatch]] = []
    private let turretBase: MeshBatch, turretHead: MeshBatch, medkit: MeshBatch
    private let glob: MeshBatch, grenade: MeshBatch, beaconTop: MeshBatch
    private let corpseGeneric: MeshBatch, corpseBrute: MeshBatch
    private var propBatches: [MeshBatch] = []
    private var tailBatches: [MeshBatch] = []
    private var typeCounts = [Int](repeating: 0, count: 4)
    private var bugPtr = [UnsafeMutablePointer<BugInstance>?](repeating: nil, count: 4)
    private var bugCnt = [Int](repeating: 0, count: 4)
    private var spotPos = [F4](repeating: .zero, count: 4), spotDir = [F4](repeating: .zero, count: 4)
    private var pointPos = [F4](repeating: .zero, count: 3), pointCol = [F4](repeating: .zero, count: 3)
    private var visibleBugs = 0
    private var lastStats = WorldStats()
    /// Effect time of ticks without a drawn frame, added to the next drawn one (effects keep their speed).
    private var dtCarry: Float = 0
    /// Camera of the last built frame: a frozen world (menus) is not rebuilt while it holds still.
    private var lastEye = F3(0, 0, 0), lastFocus = F3(0, 0, 0)
    private var lastTarget = (0, 0)
    private var lastRise: Float = -1

    var fxK: Float {
        get { fx.fxK }
        set {
            fx.setQuality(fxK: newValue)
            shadows = newValue >= 0.85
        }
    }
    /// «Высокая»: the player's flashlight casts shadows (the squad and bug proxies, web Q.shadows).
    private var shadows = false
    /// The player's flashlight this frame (web renderFx: spots[0] follows the aim): position, unit direction, on.
    private var spot0 = (pos: F3(0, -50, 0), dir: F3(0, -1, 0), on: false)
    static let shadowProxyMax = 400

    /// Main thread: the world with prepared meshes and pipelines.
    init(level: Level, store: MeshStore, renderer: MetalRenderer) {
        self.level = level
        self.store = store
        self.renderer = renderer
        self.fx = MetalEffects(level: level)
        func b(_ n: String, _ pass: MeshPass, rough: Float = 0.62, metal: Float = 0.45, snow: Bool = true,
               casts: Bool = false, receives: Bool = false) -> MeshBatch {
            MeshBatch(mesh: store.mesh(n), pass: pass, roughness: rough, metalness: metal, glow: 2.2, snow: snow,
                      castsShadow: casts, receivesShadow: receives)
        }
        turretBase = b("turret_base", .props)
        turretHead = b("turret_head", .props)
        medkit = b("medkit", .props)
        glob = b("glob", .unlit, snow: false)
        grenade = b("grenade", .unlit, snow: false)
        beaconTop = b("beacon_top", .unlit, snow: false)
        corpseGeneric = b("corpse_generic", .lambert, snow: false, receives: true)
        corpseBrute = b("corpse_brute", .lambert, snow: false, receives: true)
        for c in MarineClass.allCases {
            marineBatches.append(["body", "leg", "gun"].map { b("marine_\(c.id)_\($0)", .props, rough: 0.55, metal: 0.5, snow: false, casts: true) })
        }
        propBatches = [turretBase, turretHead, medkit, glob, grenade, beaconTop]
        tailBatches = [turretBase, turretHead, medkit, glob, grenade, beaconTop]
    }

    /// Load meshes, textures and compile the pipelines side by side (call off the main thread). nil if Metal is unusable.
    static func prepare(device: MTLDevice, queue: MTLCommandQueue, log: (String) -> Void) -> (MeshStore, MetalRenderer)? {
        let store = MeshStore(device: device)
        guard let r = MetalRenderer(device: device, queue: queue, store: store) else { log("metal: renderer init failed"); return nil }
        let group = DispatchGroup()
        var loaded = ""
        DispatchQueue.global(qos: .userInitiated).async(group: group) { loaded = store.loadAll() }
        let built = r.compilePipelines()
        group.wait()
        r.bindResources()
        log("metal: " + loaded)
        log("metal: " + built + " device=\(device.name)")
        return r.ready ? (store, r) : nil
    }

    func reset() {
        fx.reset()
        aimInit = false
        dtCarry = 0
        lastRise = -1
    }

    /// Memory warning: the transient particle pools go (stains and corpses stay).
    func trim() { fx.trim() }

    /// Loading cover: every explosion kind, kill splash, frost burst and acid splash once at `pos`, so their first use
    /// in the mission costs nothing new (the cover hides them; reset() clears them before the cover lifts).
    func warmUp(game: Game, at pos: Vec2) {
        for k in [ExplosionKind.frag, .mini, .boomer, .frost, .pulse] { fx.handle(.explosion(kind: k, pos: pos, radius: 4), game: game) }
        for t in BugType.allCases {
            fx.handle(.bugKilled(type: t, pos: pos, frozen: t == .runner, source: 0, heading: 0, scale: 1, height: 0), game: game)
        }
        fx.handle(.bugFrozen(pos: pos), game: game)
        fx.handle(.acidSplash(pos: pos), game: game)
        fx.handle(.bulletHit(pos: pos, dir: Vec2(1, 0), killed: true), game: game)
    }

    func handle(_ e: GameEvent, game: Game) { fx.handle(e, game: game) }

    // ---------------------------------------------------------------- HUD projection
    func hudPoint(_ x: Float, _ y: Float, _ z: Float) -> CGPoint { camera.hudPoint(x, y, z) }

    func feet(_ k: Int) -> (Float, Float, Float) {
        k >= 0 && k < poses.count ? (poses[k].x, poses[k].y, poses[k].z) : (0, 0, 0)
    }

    var stats: WorldStats { lastStats }

    // ---------------------------------------------------------------- frame
    /// `viewSize`: points (HUD space). `frozen`: the simulation stands still (pause / level-up / report) — the last
    /// image is kept while the camera holds still too.
    func update(game: Game, alpha: Float, dt dt0: Float, time: Float, camera cam: CameraController, viewSize: CGSize, frozen: Bool) {
        timer.begin()
        let tw = renderer.targetWidth, th = renderer.targetHeight
        camera.resize(width: Float(viewSize.width), height: Float(viewSize.height), drawableHeight: Float(max(1, th)))
        let ex: Float = game.stage == .extract ? smooth01f(game.extractT / 4.5) : 0
        camera.update(focus: F3(cam.focus.0, cam.focus.1, cam.focus.2), shake: F3(cam.shakeOffset.0, cam.shakeOffset.1, cam.shakeOffset.2),
                      title: game.attract, time: time, extract: ex)
        game.setVisibleQuad(camera.ground(ndcX: -1, ndcY: -1, height: cam.ty), camera.ground(ndcX: 1, ndcY: -1, height: cam.ty),
                            camera.ground(ndcX: 1, ndcY: 1, height: cam.ty), camera.ground(ndcX: -1, ndcY: 1, height: cam.ty))
        timer.mark()
        let rise = game.liftRise
        // no free frame slot (the GPU is behind): nothing to build; the effects catch up on the next drawn frame
        guard renderer.frameOpen else {
            dtCarry = min(0.25, dtCarry + dt0)
            return
        }
        if frozen && renderer.hasWorldImage && rise == lastRise && tw == lastTarget.0 && th == lastTarget.1
            && maxAbs(camera.eye - lastEye) < 1e-3 && maxAbs(camera.focus - lastFocus) < 1e-3 {
            return
        }
        lastEye = camera.eye; lastFocus = camera.focus; lastTarget = (tw, th); lastRise = rise
        let dt = dt0 + dtCarry
        dtCarry = 0
        let list = renderer.list
        list.liftRise = rise

        renderMarines(game: game, alpha: alpha, dt: dt, time: time, rise: rise)
        spot0.on = false
        if let m = game.marines.first {
            let (p, d) = flashlight(m, poses[0])
            spot0 = (p, d, true)
        }
        timer.mark()
        writeBugs(game: game, alpha: alpha, time: time, dt: dt)
        timer.mark()
        fx.beginFrame()
        fx.setCameraRight(camera.right)
        fx.update(game: game, dt: dt, time: time, poses: poses, focus: camera.focus, liftRise: rise)
        props(game: game, time: time, dt: dt)
        timer.mark()
        upload(game: game, dt: dt)
        lights(game: game, time: time)
        timer.mark()
        renderer.built = true

        var s = WorldStats()
        s.visibleBugs = visibleBugs
        s.particles = list.pa.count + list.pn.count
        s.drawCalls = renderer.drawCalls
        s.instances = renderer.instanceCount
        s.triangles = renderer.triangles
        s.encodeMs = renderer.encodeMs
        lastStats = s
    }

    // ---------------------------------------------------------------- squad (12-main.js renderMarines)
    private func renderMarines(game: Game, alpha: Float, dt: Float, time: Float, rise: Float) {
        let liftOn = game.stage == .extract
        if !aimInit {
            aimInit = true
            for (k, m) in game.marines.enumerated() where k < 4 { aimVis[k] = m.aim; walkPh[k] = 0 }
        }
        for b in marineBatches { for x in b { x.instances.removeAll(keepingCapacity: true) } }
        for (k, m) in game.marines.enumerated() where k < 4 {
            let x = m.px + (m.x - m.px) * alpha, z = m.pz + (m.z - m.pz) * alpha
            let y = level.groundY(x, z) + (liftOn && level.onLift(m.x, m.z) ? rise : 0)
            poses[k] = MetalEffects.MarinePose(x: x, y: y, z: z)
            var d = m.aim - aimVis[k]
            while d > Float.pi { d -= TAU }
            while d < -Float.pi { d += TAU }
            aimVis[k] += d * min(1, 22 * dt)
            let sp = (m.vx * m.vx + m.vz * m.vz).squareRoot()
            var rotX: Float = 0, legLx: Float = 0, legRx: Float = 0, legLz: Float = 0, legRz: Float = 0
            var bodyY: Float = 0, gunZ: Float = 0.08, oy: Float = 0
            if m.downed {
                oy = 0.28
                rotX = -1.35
                legLx = 0.2; legRx = -0.1
            } else {
                rotX = m.dashT > 0 ? 0.35 : 0
                walkPh[k] += sp * dt * 2.6
                let w = min(1, sp / 4)
                let sw = sinf(walkPh[k]) * 0.75 * w
                // legs swing along the movement direction relative to where the marine faces
                let rel = cosf(atan2f(m.vx, m.vz) - aimVis[k])
                legLx = sw * rel; legRx = -sw * rel
                legLz = sw * 0.4 * (1 - abs(rel)); legRz = -legLz
                bodyY = abs(sinf(walkPh[k])) * 0.05 * w
                gunZ = 0.08 - (m.muzzle > 0 ? 0.05 : 0) - (m.cls == .gunner && m.firing ? sinf(time * 80) * 0.015 : 0)
                if m.cls == .gunner { gunSpin[k] += m.spin * dt * 40 }
            }
            let hurt: Float = m.hurtT > 0 ? 0.7 : 0
            let inv: Float = m.inv > 0 && !m.downed && m.dashT <= 0 ? 0.12 + 0.1 * sinf(time * 20) : 0
            let em = F4(hurt, inv * 0.8, inv, 0)
            let g = Mat4.translation(x, y + oy, z) * Mat4.rotationY(aimVis[k]) * Mat4.rotationX(rotX) * Mat4.scale(1.12)
            let bt = marineBatches[m.cls.rawValue]
            let tint = F4(1, 1, 1, 0)
            bt[0].instances.append(MeshInstance(model: g * Mat4.translation(0, bodyY, 0), tint: tint, emissive: em))
            bt[1].instances.append(MeshInstance(model: g * Mat4.translation(-0.13, 0.78, 0) * Mat4.rotationX(legLx) * Mat4.rotationZ(legLz), tint: tint, emissive: em))
            bt[1].instances.append(MeshInstance(model: g * Mat4.translation(0.13, 0.78, 0) * Mat4.rotationX(legRx) * Mat4.rotationZ(legRz), tint: tint, emissive: em))
            bt[2].instances.append(MeshInstance(model: g * Mat4.translation(0.2, 1.12, gunZ) * Mat4.rotationZ(gunSpin[k]), tint: tint, emissive: em))
        }
    }

    // ---------------------------------------------------------------- swarm (05-sim.js writeBugInstances)
    private func writeBugs(game: Game, alpha: Float, time: Float, dt: Float) {
        let S = game.bugs
        let n = S.count
        let types = S.types, dead = S.deadFlags
        for t in 0..<4 { typeCounts[t] = 0 }
        for i in 0..<n where dead[i] == 0 { typeCounts[Int(min(3, types[i]))] += 1 }
        let list = renderer.list
        for t in 0..<4 {
            list.bugs[t] = Region()
            bugPtr[t] = nil
            bugCnt[t] = 0
            if typeCounts[t] > 0, let a = renderer.alloc(BugInstance.self, typeCounts[t]) {
                bugPtr[t] = a.0
                list.bugs[t].offset = a.1
            }
        }
        let X = S.xs, Z = S.zs, PX = S.prevXs, PZ = S.prevZs, Y = S.heights, HD = S.headings, SC = S.scales
        let PH = S.gaitPhases, FL = S.flashes, BU = S.burnTimers, FR = S.freezeTimers, CH = S.chills
        let ST = S.states, TT = S.stateTimers, VR = S.variations
        let swell = BugState.swell.rawValue, wind = BugState.wind.rawValue, climb = BugState.climb.rawValue
        let brute = UInt8(BugType.brute.rawValue)
        var vis = 0
        // shadow proxies: bugs inside the player's flashlight cone (cos 0.6, 32 m), «высокая» only
        list.proxies = Region()
        var proxyPtr: UnsafeMutablePointer<BugInstance>? = nil
        var proxyN = 0
        if shadows && spot0.on, let a = renderer.alloc(BugInstance.self, MetalWorld.shadowProxyMax) {
            proxyPtr = a.0
            list.proxies.offset = a.1
        }
        let sp0 = spot0.pos, sd0 = spot0.dir, cosCone = cosf(0.6)
        for i in 0..<n where dead[i] == 0 {
            let t = Int(min(3, types[i]))
            guard let out = bugPtr[t] else { continue }
            let bx = PX[i] + (X[i] - PX[i]) * alpha, bz = PZ[i] + (Z[i] - PZ[i]) * alpha
            let gy = level.groundY(bx, bz) + Y[i]
            let sc = SC[i]
            // CPU frustum cull: clip-space test of a point at mid-body height (15 % margin covers the body size)
            if !camera.visible(bx, gy + 0.3 * sc, bz) { continue }
            var s = sc, sy = sc
            let st = ST[i]
            if st == swell {
                let p = 1 - TT[i] / 0.8
                s *= 1 + p * 0.45 + sinf(time * 40) * 0.04 * p
                sy = s
            }
            if st == wind && types[i] == brute { sy = s * (1 + sinf(time * 30) * 0.05) }
            var sp: Float = 0, cp: Float = 1
            if st == climb && Y[i] < -0.1 {
                // nose up while scaling the wall, levelling out as it crests the edge
                let p = clampf((-Y[i] - 0.1) / 0.7, 0, 1) * 1.4
                sp = sinf(p); cp = cosf(p)
            }
            let vr = VR[i], v = 0.55 + vr * 0.75
            var flash = max(0, FL[i])
            if st == swell { flash = max(FL[i], (0.5 + 0.5 * sinf(time * (18 + 30 * (1 - TT[i] / 0.8)))) * 0.9) }
            var burn: Float = 0
            if BU[i] > 0 {
                burn = 0.55 + 0.45 * sinf(time * 23 + Float(i) * 1.7)
                if dt > 0 { fx.burningBug(bx, bz, sc, dt: dt) }
            }
            let frz: Float = FR[i] > 0 ? 1 : CH[i] * 0.55
            let k = bugCnt[t]
            // built once and written to both slots: the arena is write-combined memory, never read it back
            let inst = BugInstance(pos: F4(bx, gy, bz, s), rot: F4(cosf(HD[i]), sinf(HD[i]), sp, cp),
                                   color: F4(v, v * (0.92 + vr * 0.1), v, sy), anim: F4(PH[i], flash, burn, frz))
            out[k] = inst
            if let pp = proxyPtr, proxyN < MetalWorld.shadowProxyMax {
                let o = F3(bx, gy + 0.3 * sc, bz) - sp0
                let d2 = (o * o).sum()
                if d2 < 32 * 32 && (o * sd0).sum() > cosCone * d2.squareRoot() { pp[proxyN] = inst; proxyN += 1 }
            }
            bugCnt[t] = k + 1
            vis += 1
        }
        for t in 0..<4 { list.bugs[t].count = bugPtr[t] == nil ? 0 : bugCnt[t] }
        list.proxies.count = proxyN
        visibleBugs = vis
    }

    // ---------------------------------------------------------------- props (globs, grenades, medkits, turret, beacon tips)
    private func props(game: Game, time: Float, dt: Float) {
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

    // ---------------------------------------------------------------- uploads
    private func upload(game: Game, dt: Float) {
        let r = renderer, list = r.list
        // instanced meshes (the corpse rings go straight from the effects into the arena)
        corpseGeneric.region = r.upload(fx.corpses[0])
        if corpseGeneric.region.count > 0 { list.batches.append(corpseGeneric) }
        corpseBrute.region = r.upload(fx.corpses[1])
        if corpseBrute.region.count > 0 { list.batches.append(corpseBrute) }
        for b in marineBatches { for x in b where !x.instances.isEmpty { x.region = r.upload(x.instances); list.batches.append(x) } }
        for b in tailBatches where !b.instances.isEmpty {
            b.region = r.upload(b.instances)
            list.batches.append(b)
        }
        list.decals = r.upload(fx.decals)
        list.glowSprites = r.upload(fx.glowSprites)
        list.ringSprites = r.upload(fx.ringSprites)
        list.fillSprites = r.upload(fx.fillSprites)
        list.laneSprites = r.upload(fx.laneSprites)
        list.indicators = r.upload(fx.indicators)
        list.ribbons = r.upload(fx.ribbons)
        // particles: simulated and written straight into the arena
        list.pa = Region(); list.pn = Region()
        if let a = r.alloc(ParticleInstance.self, max(1, fx.pa.count)) {
            list.pa = Region(offset: a.1, count: fx.pa.update(dt: dt, out: a.0, max: max(1, fx.pa.count)))
        } else {
            _ = fx.pa.update(dt: dt, out: nil, max: 0)
        }
        if let a = r.alloc(ParticleInstance.self, max(1, fx.pn.count)) {
            list.pn = Region(offset: a.1, count: fx.pn.update(dt: dt, out: a.0, max: max(1, fx.pn.count)))
        } else {
            _ = fx.pn.update(dt: dt, out: nil, max: 0)
        }
        // weather (quality med: 700 snowflakes, 6 mist banks, 420 motes)
        let k = fx.fxK
        list.snow = k < 0.5 ? 350 : (k < 0.85 ? 700 : 1300)
        list.mist = k < 0.5 ? 0 : (k < 0.85 ? 6 : 14)
        list.motes = 420
        list.weather = F4(camera.focus.x, camera.focus.y, camera.focus.z, 0)
    }

    /// A marine's flashlight (renderFx): from the chest along the aim to a point 9 m ahead on the floor; a downed marine's
    /// lies on the deck pointing 2 m ahead.
    private func flashlight(_ m: Marine, _ p: MetalEffects.MarinePose) -> (F3, F3) {
        let pos: F3, target: F3
        if m.downed {
            pos = F3(p.x, p.y + 0.6, p.z)
            target = F3(p.x + m.ax * 2, p.y, p.z + m.az * 2)
        } else {
            pos = F3(p.x + m.ax * 0.3, p.y + 1.75, p.z + m.az * 0.3)
            target = F3(p.x + m.ax * 9, p.y, p.z + m.az * 9)
        }
        return (pos, (target - pos) / max(1e-4, (target - pos).magnitude))
    }

    // ---------------------------------------------------------------- lights (03-render.js rig + renderFx updates)
    private func lights(game: Game, time: Float) {
        var F = renderer.frame
        let invPi: Float = 1 / Float.pi
        F.viewProj = camera.viewProj
        F.view = camera.view
        F.camPos = F4(camera.eye.x, camera.eye.y, camera.eye.z, time)
        let fog = displayRGB(0x1a2737)
        F.fog = F4(fog.x, fog.y, fog.z, camera.fogDensity)
        let sky = linearRGB(0x5a74a0) * (0.42 * invPi), ground = linearRGB(0x05070b) * (0.42 * invPi)
        F.hemiSky = F4(sky.x, sky.y, sky.z, 0)
        F.hemiGround = F4(ground.x, ground.y, ground.z, 0)
        let md = F3(-25, 60, 35) / F3(-25, 60, 35).magnitude
        F.moonDir = F4(md.x, md.y, md.z, 0)
        let mc = linearRGB(0x8eaade) * (0.5 * invPi)
        F.moonColor = F4(mc.x, mc.y, mc.z, 0)
        // flashlights follow the aim
        for k in 0..<4 { spotPos[k] = .zero; spotDir[k] = .zero }
        for (k, m) in game.marines.enumerated() where k < 4 {
            let (pos, dir) = flashlight(m, poses[k])
            let i: Float = m.downed ? 12 * (0.6 + 0.4 * sinf(time * 9 + Float(k)))
                : (m.isPlayer ? 62 : 42) * (m.firing ? 1.12 : 1) * (m.hurtT > 0 ? 0.6 + 0.4 * sinf(time * 60) : 1)
            spotPos[k] = F4(pos.x, pos.y, pos.z, i * invPi)
            spotDir[k] = F4(dir.x, dir.y, dir.z, 0)
        }
        F.spotPos = (spotPos[0], spotPos[1], spotPos[2], spotPos[3])
        F.spotDir = (spotDir[0], spotDir[1], spotDir[2], spotDir[3])
        for k in 0..<3 {
            let l = fx.lights[k]
            pointPos[k] = .zero
            pointCol[k] = .zero
            if l.intensity > 0.01 {
                pointPos[k] = F4(l.pos.x, l.pos.y, l.pos.z, 18)
                let c = l.color * (l.intensity * invPi)
                pointCol[k] = F4(c.x, c.y, c.z, 0)
            }
        }
        F.pointPos = (pointPos[0], pointPos[1], pointPos[2])
        F.pointColor = (pointCol[0], pointCol[1], pointCol[2])
        F.misc = F4(camera.pxScale, Float(renderer.targetHeight), renderer.list.liftRise, 0)
        F.fx = F4(fx.fxK < 0.5 ? 1 : 2, 0, 0, 0)
        F.camRight = F4(camera.right.x, camera.right.y, camera.right.z, 0)
        F.camUp = F4(camera.up.x, camera.up.y, camera.up.z, 0)
        // the player's flashlight shadow camera (three.js SpotLightShadow: fov = 2 × angle, near 0.5, far = distance 32)
        let list = renderer.list
        list.shadowOn = shadows && spot0.on
        if list.shadowOn {
            let view = Mat4.lookAt(eye: spot0.pos, target: spot0.pos + spot0.dir)
            F.shadowMatrix = Mat4.perspective(fovY: 1.0, aspect: 1, near: 0.5, far: 32) * view
            F.shadowParams = F4(1, -0.0006, 1 / Float(MetalRenderer.shadowSize), 0)
        } else {
            F.shadowParams = F4(0, 0, 0, 0)
        }
        renderer.frame = F
    }
}

private extension SIMD3 where Scalar == Float {
    var magnitude: Float { (self * self).sum().squareRoot() }
}

@inline(__always) private func maxAbs(_ v: F3) -> Float { max(abs(v.x), max(abs(v.y), abs(v.z))) }
