import Foundation
import Metal
import IceHiveCore

// ================================================================
//  METAL WORLD — the world of the game, orchestration only (WP1
//  «Кадр»): GameScene (simulation loop, events, HUD, audio, demos)
//  calls update() once per display-link tick; it always moves the web
//  camera (the HUD projects through it) and, when FrameLoop holds a
//  free frame slot, builds the frame through the world modules, each
//  owned by one package:
//    WorldSquad (WP4)    poses of the squad, its mesh batches
//    WorldSwarm (WP3)    swarm instances (CPU frustum cull), proxies
//    MetalEffects (WP5)  effects: particles, stains, sprites, ribbons
//    Corpses (WP3)       bodies on the deck
//    GroundGlyphs (WP4)  team rings, progress rings
//    WorldLevel (WP6)    static level draws, dynamic props
//    Atmosphere (WP2)    haze, weather
//    LightGrid (WP2)     the lights of the frame
//    ShadowAtlas (WP2)   flashlight shadow pre-pass
//  then uploads everything into the frame arena and fills the frame
//  uniforms; FrameLoop encodes and presents it (MetalRenderer runs the
//  modules' registered draw items). Without a slot (the GPU is behind)
//  nothing is built and the time carries over to the next drawn frame,
//  so effects do not slow down. Every tick it also asks RenderQuality
//  for the frame's dynamic-resolution viewport, and once per second
//  (diagnostics) logs `hb gpu` (GPUCounters + quality state).
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
    /// Every pipeline of the world frame, compiled together behind the loading cover.
    static var pipelineSpecs: [PipelineSpec] {
        MetalRenderer.pipelines + WorldLevel.pipelines + WorldSwarm.pipelines + MetalEffects.pipelines + Atmosphere.pipelines
    }

    let level: Level
    let store: MeshStore
    let renderer: MetalRenderer
    let camera = MetalCamera()
    let fx: MetalEffects
    let squad: WorldSquad
    let swarm: WorldSwarm
    let corpses: Corpses
    let glyphs: GroundGlyphs
    let levelDraw: WorldLevel
    let atmosphere = Atmosphere()
    let lightGrid = LightGrid()
    let shadowAtlas = ShadowAtlas()
    /// cam = camera + visible quad, mar = squad poses, bug = swarm instances, fx = effects, up = uploads + lights
    let timer = FrameTimer(["cam", "mar", "bug", "fx", "up"])

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
            corpses.setQuality(fxK: newValue)
            shadows = newValue >= 0.85
            renderer.quality.setChosen(fxK: newValue)
        }
    }
    /// The fog / abyss: the display value it should show at exposure 0 EV before the grade (deep blue-black), as the
    /// linear radiance the materials mix in (Common.h encodeColor) and the world pass clears to.
    static let fogDisplay = displayRGB(0x121b28)
    static let fogRadiance = PostChain.radiance(forDisplay: fogDisplay)
    private var lastGPULog: Double = 0
    /// «Высокая»: the player's flashlight casts shadows (the squad and bug proxies, web Q.shadows).
    private var shadows = false {
        didSet { shadowAtlas.enabled = shadows }
    }
    /// The player's flashlight this frame (web renderFx: spots[0] follows the aim): position, unit direction, on.
    private var spot0 = (pos: F3(0, -50, 0), dir: F3(0, -1, 0), on: false)

    /// Main thread: the world with prepared meshes and pipelines.
    init(level: Level, store: MeshStore, renderer: MetalRenderer) {
        self.level = level
        self.store = store
        self.renderer = renderer
        fx = MetalEffects(level: level)
        squad = WorldSquad(level: level, store: store)
        swarm = WorldSwarm(level: level)
        corpses = Corpses(level: level, store: store)
        glyphs = GroundGlyphs(level: level)
        levelDraw = WorldLevel(level: level, store: store)
        fx.corpses = corpses
        renderer.clearRegistrations()
        renderer.registerBatchService()
        renderer.targets.setClearColor(MetalWorld.fogRadiance)
        levelDraw.attach(renderer)
        swarm.attach(renderer)
        fx.attach(renderer)
        glyphs.attach(renderer)
        atmosphere.attach(renderer)
        shadowAtlas.attach(renderer)
    }

    deinit { renderer.clearRegistrations() }

    /// Load meshes, textures and compile the pipelines side by side (call off the main thread). nil if Metal is unusable.
    static func prepare(device: MTLDevice, queue: MTLCommandQueue, log: (String) -> Void) -> (MeshStore, MetalRenderer)? {
        let store = MeshStore(device: device)
        guard let r = MetalRenderer(device: device, queue: queue, store: store) else { log("metal: renderer init failed"); return nil }
        let group = DispatchGroup()
        var loaded = ""
        DispatchQueue.global(qos: .userInitiated).async(group: group) { loaded = store.loadAll() }
        let built = r.compilePipelines(MetalWorld.pipelineSpecs)
        group.wait()
        let post = r.bindResources()
        log("metal: " + loaded)
        log("metal: " + built + " device=\(device.name)")
        log("metal: " + post + " | counters " + (r.counters.perPass ? "per pass (stage boundaries)" : "command-buffer totals")
            + " | device class \(r.quality.deviceClass) bug cap \(r.quality.deviceBugCap) default tier \(r.quality.deviceDefaultTier.rawValue)")
        return r.ready ? (store, r) : nil
    }

    func reset() {
        fx.reset()
        corpses.reset()
        squad.reset()
        renderer.quality.resetMission()
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

    func handle(_ e: GameEvent, game: Game) {
        fx.handle(e, game: game)
        // flash adaptation: a big blast dips the exposure for a moment (scripted; no auto-exposure)
        if case .explosion(let kind, _, _) = e, kind.isBig { renderer.post.dip(ev: -0.35, duration: 0.45) }
    }

    // ---------------------------------------------------------------- HUD projection
    func hudPoint(_ x: Float, _ y: Float, _ z: Float) -> CGPoint { camera.hudPoint(x, y, z) }

    func feet(_ k: Int) -> (Float, Float, Float) { squad.feet(k) }

    var stats: WorldStats { lastStats }

    // ---------------------------------------------------------------- frame
    /// `viewSize`: points (HUD space). `frozen`: the simulation stands still (pause / level-up / report) — the last
    /// image is kept while the camera holds still too.
    func update(game: Game, alpha: Float, dt dt0: Float, time: Float, camera cam: CameraController, viewSize: CGSize, frozen: Bool) {
        timer.begin()
        // this tick's tier, thermal step and dynamic-resolution viewport (before anything reads the target size)
        renderer.prepareViewport(points: viewSize, hz: dt0 > 0 && dt0 < 0.012 ? 120 : 60)
        heartbeat()
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

        squad.build(game: game, alpha: alpha, dt: dt, time: time, rise: rise)
        spot0.on = false
        if let m = game.marines.first {
            let (p, d) = WorldSquad.flashlight(m, squad.poses[0])
            spot0 = (p, d, true)
        }
        timer.mark()
        swarm.build(game: game, alpha: alpha, time: time, dt: dt, camera: camera,
                    spot: shadows && spot0.on ? (spot0.pos, spot0.dir) : nil, fx: fx)
        timer.mark()
        fx.beginFrame()
        fx.setCameraRight(camera.right)
        fx.update(game: game, dt: dt, time: time, poses: squad.poses, focus: camera.focus, liftRise: rise)
        corpses.liftRise(rise)
        glyphs.build(game: game, time: time, poses: squad.poses, liftRise: rise)
        levelDraw.build(game: game, time: time, dt: dt, rise: rise, fx: fx)
        timer.mark()
        upload(dt: dt)
        frameUniforms(game: game, time: time, rise: rise)
        timer.mark()
        renderer.built = true

        var s = WorldStats()
        s.visibleBugs = swarm.visible
        s.particles = fx.particleCount
        s.drawCalls = renderer.drawCalls
        s.instances = renderer.instanceCount
        s.triangles = renderer.triangles
        s.encodeMs = renderer.encodeMs
        lastStats = s
    }

    // ---------------------------------------------------------------- uploads
    private func upload(dt: Float) {
        let r = renderer
        // mesh batches (corpses in persistent buffers, copied only after a change; then the squad and the props)
        corpses.upload(r)
        squad.upload(r)
        levelDraw.upload(r)
        fx.upload(r, teamRings: glyphs.teamRings, dt: dt)
        glyphs.upload(r)
        atmosphere.build(focus: camera.focus, fxK: fx.fxK)
    }

    /// The frame uniforms: camera, fog, misc (here), the lights (LightGrid), the shadow camera (ShadowAtlas).
    private func frameUniforms(game: Game, time: Float, rise: Float) {
        var F = renderer.frame
        F.viewProj = camera.viewProj
        F.view = camera.view
        F.camPos = F4(camera.eye.x, camera.eye.y, camera.eye.z, time)
        let fog = MetalWorld.fogRadiance
        F.fog = F4(fog.x, fog.y, fog.z, camera.fogDensity)
        lightGrid.fill(&F, game: game, time: time, poses: squad.poses, fx: fx)
        F.misc = F4(camera.pxScale, Float(renderer.targetHeight), rise, 0)
        F.fx = F4(fx.fxK < 0.5 ? 1 : 2, 0, 0, 0)
        F.camRight = F4(camera.right.x, camera.right.y, camera.right.z, 0)
        F.camUp = F4(camera.up.x, camera.up.y, camera.up.z, 0)
        shadowAtlas.setup(&F, spot: spot0.on ? (spot0.pos, spot0.dir) : nil)
        renderer.frame = F
    }
}

extension MetalWorld {
    /// Once per second (diagnostics): `hb gpu` — GPU time per frame and per pass (device) or the command-buffer total
    /// (simulator), the tier, the dynamic-resolution scale and range, viewport / allocation, thermal step, 120 Hz
    /// policy; plus RenderQuality's events (sweep steps, ladder changes).
    fileprivate func heartbeat() {
        let q = renderer.quality
        for e in q.takeEvents() { AppLog.info("quality: " + e) }
        guard AppLog.diagnostics else { return }
        let now = FrameTimer.now()
        if now - lastGPULog < 1 { return }
        lastGPULog = now
        renderer.counters.calibrate()
        let t = renderer.targets, r = q.range
        AppLog.info("hb gpu " + renderer.counters.takeSummary()
                    + String(format: " | ema=%.2f tier=", q.gpuEma) + q.tier.rawValue
                    + String(format: " scale=%.2f range=%.2f-%.2f", q.scale, r.lo, r.hi)
                    + " view=\(t.viewW)x\(t.viewH) alloc=\(t.allocW)x\(t.allocH) allocs=\(t.allocations) thermal=\(q.ladder)"
                    + " 120hz=" + (q.allows120Hz(now: now) ? "ok" : "no") + " bugcap=\(q.deviceBugCap)"
                    + String(format: " ev=%.2f", renderer.post.exposureEV))
    }
}

@inline(__always) private func maxAbs(_ v: F3) -> Float { max(abs(v.x), max(abs(v.y), abs(v.z))) }
