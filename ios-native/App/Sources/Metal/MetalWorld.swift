import Foundation
import Metal
import MetalKit
import IceHiveCore

// ================================================================
//  METAL WORLD — the Metal renderer as a WorldPresenter: GameScene
//  (simulation loop, events, HUD in a transparent SKView on top,
//  audio, demos) calls update() once per frame; it builds the web
//  camera, poses the squad (renderMarines), writes the swarm instances
//  per bug type with a CPU frustum cull (writeBugInstances), runs the
//  effects (renderFx), fills the lights, uploads everything into the
//  frame arena and draws the MTKView synchronously.
// ================================================================
final class MetalWorld: WorldPresenter {
    let rendererName = "metal"
    let level: Level
    let view: MTKView
    let store: MeshStore
    let renderer: MetalRenderer
    let camera = MetalCamera()
    let fx: MetalEffects
    /// wait = free frame slot (GPU back-pressure), mar = squad poses, bug = swarm instances, fx = effects,
    /// up = uploads + lights, draw = drawable + encode + commit
    let timer = FrameTimer(["wait", "mar", "bug", "fx", "up", "draw"])

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
    private var loggedDrawable = CGSize.zero

    var fxK: Float {
        get { fx.fxK }
        set { fx.setQuality(fxK: newValue) }
    }

    /// Main thread: takes over the view (delegate) with prepared meshes and pipelines.
    init(view: MTKView, level: Level, store: MeshStore, renderer: MetalRenderer) {
        self.view = view
        self.level = level
        self.store = store
        self.renderer = renderer
        self.fx = MetalEffects(level: level)
        func b(_ n: String, _ pass: MeshPass, rough: Float = 0.62, metal: Float = 0.45, snow: Bool = true) -> MeshBatch {
            MeshBatch(mesh: store.mesh(n), pass: pass, roughness: rough, metalness: metal, glow: 2.2, snow: snow)
        }
        turretBase = b("turret_base", .props)
        turretHead = b("turret_head", .props)
        medkit = b("medkit", .props)
        glob = b("glob", .unlit, snow: false)
        grenade = b("grenade", .unlit, snow: false)
        beaconTop = b("beacon_top", .unlit, snow: false)
        corpseGeneric = b("corpse_generic", .lambert, snow: false)
        corpseBrute = b("corpse_brute", .lambert, snow: false)
        for c in MarineClass.allCases {
            marineBatches.append(["body", "leg", "gun"].map { b("marine_\(c.id)_\($0)", .props, rough: 0.55, metal: 0.5, snow: false) })
        }
        corpseGeneric.instances.reserveCapacity(520)
        corpseBrute.instances.reserveCapacity(64)
        propBatches = [turretBase, turretHead, medkit, glob, grenade, beaconTop]
        tailBatches = [turretBase, turretHead, medkit, corpseGeneric, corpseBrute, glob, grenade, beaconTop]
        view.delegate = renderer
        renderer.view = view
    }

    /// Load meshes, textures and compile the pipelines (call off the main thread). nil if Metal is unusable.
    static func prepare(device: MTLDevice, log: (String) -> Void) -> (MeshStore, MetalRenderer)? {
        let store = MeshStore(device: device)
        log("metal: " + store.loadAll())
        guard let r = MetalRenderer(device: device, store: store) else { log("metal: renderer init failed"); return nil }
        log("metal: " + r.buildPipelines() + " device=\(device.name)")
        return r.ready ? (store, r) : nil
    }

    func reset() {
        fx.reset()
        aimInit = false
    }

    func handle(_ e: GameEvent, game: Game) { fx.handle(e, game: game) }

    // ---------------------------------------------------------------- HUD projection
    func hudPoint(_ x: Float, _ y: Float, _ z: Float) -> CGPoint { camera.hudPoint(x, y, z) }

    func feet(_ k: Int) -> (Float, Float, Float) {
        k >= 0 && k < poses.count ? (poses[k].x, poses[k].y, poses[k].z) : (0, 0, 0)
    }

    var stats: WorldStats { lastStats }

    // ---------------------------------------------------------------- frame
    func update(game: Game, alpha: Float, dt: Float, time: Float, camera cam: CameraController) {
        timer.begin()
        renderer.beginFrame()
        timer.mark()
        let size = view.bounds.size
        let ds = view.drawableSize
        if ds != loggedDrawable {
            loggedDrawable = ds
            AppLog.info("metal: view \(Int(size.width))x\(Int(size.height)) pt, drawable \(Int(ds.width))x\(Int(ds.height)) px (scale \(view.contentScaleFactor))")
        }
        camera.resize(width: Float(size.width), height: Float(size.height), drawableHeight: Float(ds.height))
        let ex: Float = game.stage == .extract ? smooth01f(game.extractT / 4.5) : 0
        camera.update(focus: F3(cam.focus.0, cam.focus.1, cam.focus.2), shake: F3(cam.shakeOffset.0, cam.shakeOffset.1, cam.shakeOffset.2),
                      title: game.attract, time: time, extract: ex)
        game.setVisibleQuad(camera.ground(ndcX: -1, ndcY: -1, height: cam.ty), camera.ground(ndcX: 1, ndcY: -1, height: cam.ty),
                            camera.ground(ndcX: 1, ndcY: 1, height: cam.ty), camera.ground(ndcX: -1, ndcY: 1, height: cam.ty))
        let rise = game.liftRise
        let list = renderer.list
        list.liftRise = rise

        renderMarines(game: game, alpha: alpha, dt: dt, time: time, rise: rise)
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
        view.draw()
        renderer.cancelFrame()   // no-op when the frame was drawn
        timer.mark()

        var s = WorldStats()
        s.visibleBugs = visibleBugs
        s.particles = list.pa.count + list.pn.count
        s.drawCalls = renderer.drawCalls
        s.instances = renderer.instanceCount
        s.triangles = renderer.triangles
        s.chunks = renderer.drawCalls
        s.nodes = renderer.instanceCount
        s.encodeMs = renderer.encodeMs
        s.gpuMs = renderer.gpuMs
        s.waitMs = renderer.waitMs
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
            out[k] = BugInstance(pos: F4(bx, gy, bz, s), rot: F4(cosf(HD[i]), sinf(HD[i]), sp, cp),
                                 color: F4(v, v * (0.92 + vr * 0.1), v, sy), anim: F4(PH[i], flash, burn, frz))
            bugCnt[t] = k + 1
            vis += 1
        }
        for t in 0..<4 { list.bugs[t].count = bugPtr[t] == nil ? 0 : bugCnt[t] }
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
        // instanced meshes
        corpseGeneric.instances.removeAll(keepingCapacity: true)
        corpseGeneric.instances.append(contentsOf: fx.corpses[0])
        corpseBrute.instances.removeAll(keepingCapacity: true)
        corpseBrute.instances.append(contentsOf: fx.corpses[1])
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
            let p = poses[k]
            var pos: F3, target: F3, i: Float
            if m.downed {
                pos = F3(p.x, p.y + 0.6, p.z)
                target = F3(p.x + m.ax * 2, p.y, p.z + m.az * 2)
                i = 12 * (0.6 + 0.4 * sinf(time * 9 + Float(k)))
            } else {
                pos = F3(p.x + m.ax * 0.3, p.y + 1.75, p.z + m.az * 0.3)
                target = F3(p.x + m.ax * 9, p.y, p.z + m.az * 9)
                i = (m.isPlayer ? 62 : 42) * (m.firing ? 1.12 : 1) * (m.hurtT > 0 ? 0.6 + 0.4 * sinf(time * 60) : 1)
            }
            let dir = (target - pos) / max(1e-4, (target - pos).magnitude)
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
        F.misc = F4(camera.pxScale, Float(view.drawableSize.height), renderer.list.liftRise, 1)
        F.camRight = F4(camera.right.x, camera.right.y, camera.right.z, 0)
        F.camUp = F4(camera.up.x, camera.up.y, camera.up.z, 0)
        renderer.frame = F
    }
}

private extension SIMD3 where Scalar == Float {
    var magnitude: Float { (self * self).sum().squareRoot() }
}
