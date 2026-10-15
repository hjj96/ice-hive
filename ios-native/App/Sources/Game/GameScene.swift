import SpriteKit
import UIKit
import IceHiveCore

// ================================================================
//  GAME SCENE — one SKScene for the whole game: drives Game.tick() at
//  a fixed 60 Hz with an accumulator (render interpolation between
//  ticks, hit-stop slow motion), routes GameEvents to the renderer /
//  HUD / audio / haptics, and switches between the title (attract
//  mode behind), the mission, level-up cards, pause and the report.
// ================================================================
final class GameScene: SKScene {
    enum Mode: String { case loading, title, playing, levelUp, paused, ended }

    let options: LaunchOptions
    private(set) var mode: Mode = .loading
    private var assets: SpriteAssets?
    private var level: Level?
    private var game: Game?
    private var renderer: WorldRenderer?
    private let cameraCtl = CameraController()
    private let hud = HUD()
    private let input = InputController()
    private let titleScreen = TitleScreen()
    private let levelUpScreen = LevelUpScreen()
    private let menu = MenuScreen()
    private let haptics = Haptics()
    private var audio: AudioEngine?
    private var demo: DemoScript?
    private var selectedClass: MarineClass = .assault
    private var surrendered = false

    // loop state
    private var acc: Double = 0
    private var lastTime: Double = -1
    private var renderTime: Float = 0
    private var hitStopT: Float = 0, hitStopK: Float = 1, hitStopCd: Float = 0
    private var endDelay: Float = -1
    private var heartT: Float = 0

    // stats
    private var startTime: Double = -1
    private var frameCount = 0
    private var fpsWindowStart: Double = 0
    private var lastHeartbeat: Double = 0
    private var fps: Double = 0
    private var fpsSum: Double = 0
    private var fpsSamples = 0
    private var fpsMin: Double = 999
    private var simMs: Double = 0
    private var renderMs: Double = 0
    private var reportedReady = false
    private var reportedDone = false
    private var loadingLabel: Label?
    private var loadingSub: Label?
    /// Opaque cover over the world while loading and for the first frames after it (texture uploads and shader
    /// compiles happen behind it), then faded out: the moment it is gone is "scene ready".
    private let cover = SKSpriteNode(color: Tone.hex(0x05070a), size: CGSize(width: 4000, height: 4000))
    private var coverFrames = 0
    private var readyTime: Double = -1
    private var loadStep = 0
    private var bootTime: Double = 0
    private let sceneTimer = FrameTimer(["sim", "ev", "cam", "draw", "hud", "au"])
    private var worstDt: Double = 0
    private var lastDebugText: Double = 0
    private var lastFrameTime: Double = 0
    private var worstMs: Double = 0

    init(size: CGSize, options: LaunchOptions) {
        self.options = options
        super.init(size: size)
        backgroundColor = Tone.hex(0x1a2737)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        if let c = options.playerClass, let mc = MarineClass(id: c) { selectedClass = mc }
        demo = DemoScript.make(options: options)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // ---------------------------------------------------------------- boot
    override func didMove(to view: SKView) {
        if assets != nil || loadingLabel != nil { relayout(); return }
        addChild(cameraCtl.node)
        camera = cameraCtl.node
        cover.zPosition = ZBand.hud + 900
        cameraCtl.node.addChild(cover)
        let title = Label("ЛЕДЯНОЙ УЛЕЙ", font: Fonts.bold, size: 30, color: UIPalette.ink, kern: 4)
        title.node.zPosition = ZBand.hud + 901
        cameraCtl.node.addChild(title.node)
        let sub = Label("ПРОГРЕВ РЕАКТОРОВ…", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 2.5)
        sub.node.position = CGPoint(x: 0, y: -30)
        sub.node.zPosition = ZBand.hud + 901
        cameraCtl.node.addChild(sub.node)
        loadingLabel = title
        loadingSub = sub
        Fonts.logAvailability()
        loadStep = 0
    }

    /// Loading runs over several frames so the loading screen is on screen while atlases index / preload.
    private func advanceLoading() {
        switch loadStep {
        case 0, 1:
            loadStep += 1          // let the loading screen render first
        case 2:
            loadStep = 3
            bootTime = ProcessInfo.processInfo.systemUptime
            let a = SpriteAssets()
            assets = a
            AppLog.info(String(format: "sprites indexed in %.0f ms", (ProcessInfo.processInfo.systemUptime - bootTime) * 1000))
            finishLoading()
        default:
            if let l = loadingSub { l.node.alpha = 0.5 + 0.5 * CGFloat(sinf(Float(lastTime) * 4)) }
        }
    }

    /// Build the world (hidden), then decode the five sprite sheets in the background (SKTexture.preload) before the
    /// first frame shows them — otherwise each sheet is decoded synchronously the first time a frame of it is drawn.
    private func finishLoading() {
        guard let a = assets else { return }
        let t0 = ProcessInfo.processInfo.systemUptime
        let lv = Level(source: KelvinStation(), seed: 1)
        level = lv
        let r = WorldRenderer(level: lv, assets: a, bugCapacity: QualityTier.med.bugCap)
        renderer = r
        r.world.isHidden = true
        addChild(r.world)
        r.attach(to: cameraCtl)
        r.lighting.node.isHidden = true
        cameraCtl.node.addChild(hud.root)
        cameraCtl.node.addChild(titleScreen.root)
        cameraCtl.node.addChild(levelUpScreen.root)
        cameraCtl.node.addChild(menu.root)
        hud.visible = false
        titleScreen.root.isHidden = true
        hud.showDebug = options.debugHUD
        input.hitAbility = { [weak self] p in
            guard let s = self else { return false }
            return s.hud.abilityButton.contains(hudPoint: s.hud.hp(p.x, p.y))
        }
        input.hitDash = { [weak self] p in
            guard let s = self else { return false }
            return s.hud.dashButton.contains(hudPoint: s.hud.hp(p.x, p.y))
        }
        audio = AudioEngine(enabled: !options.mute)
        let pages = a.sheets.pages
        AppLog.info(String(format: "world built in %.0f ms; preloading %d sheets", (ProcessInfo.processInfo.systemUptime - t0) * 1000, pages.count))
        let t1 = ProcessInfo.processInfo.systemUptime
        SKTexture.preload(pages) {
            DispatchQueue.main.async { [weak self] in
                guard let s = self else { return }
                AppLog.info(String(format: "sheets decoded in %.0f ms", (ProcessInfo.processInfo.systemUptime - t1) * 1000) + " mem=\(Memory.footprintMB())MB")
                s.startAfterLoading()
            }
        }
        // never hang on the loading screen if the preload does not call back
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let s = self, !s.started else { return }
            AppLog.error("texture preload still running after 8 s, starting anyway")
            s.startAfterLoading()
        }
    }

    private var started = false

    private func startAfterLoading() {
        guard let r = renderer, !started else { return }
        started = true
        r.world.isHidden = false
        r.lighting.node.isHidden = options.noLighting
        // the world now renders behind the cover: GPU uploads and shader compiles happen before anyone sees a frame
        coverFrames = 0
        relayout()
        if let d = demo, d.startsMission {
            startMission(selectedClass)
        } else {
            showTitle()
        }
    }

    func relayout() {
        guard let view = view else { return }
        let insets = view.safeAreaInsets
        input.viewSize = size
        hud.layout(size: size, insets: insets)
        if mode == .title { titleScreen.layout(size: size, insets: insets, selected: selectedClass) }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if renderer != nil { relayout() }
    }

    // ---------------------------------------------------------------- modes
    private func newGame(attract: Bool) -> Game? {
        guard let lv = level else { return nil }
        var cfg = GameConfig()
        cfg.quality = .med
        cfg.attract = attract
        let seed: UInt32 = options.seed ?? UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000) & 0x7fff_ffff)
        return Game(seed: seed, playerClass: selectedClass, config: cfg, level: lv)
    }

    private func showTitle() {
        guard let g = newGame(attract: true) else { return }
        game = g
        renderer?.reset()
        cameraCtl.reset()
        acc = 0
        mode = .title
        hud.visible = false
        menu.hide()
        levelUpScreen.hide()
        titleScreen.root.isHidden = false
        if let v = view { titleScreen.layout(size: size, insets: v.safeAreaInsets, selected: selectedClass) }
        AppLog.info("mode title")
    }

    private func startMission(_ cls: MarineClass) {
        selectedClass = cls
        guard let g = newGame(attract: false) else { return }
        game = g
        surrendered = false
        endDelay = -1
        renderer?.reset()
        cameraCtl.reset()
        input.reset()
        acc = 0
        hitStopT = 0; hitStopK = 1; hitStopCd = 0
        titleScreen.root.isHidden = true
        menu.hide()
        levelUpScreen.hide()
        hud.visible = true
        hud.setSquad(g.marines)
        relayout()
        mode = .playing
        demo?.begin(game: g)
        AppLog.info("mode playing class=\(cls.id) seed=\(g.seed) demo=\(demo?.name ?? "-")")
    }

    private func openLevelUp() {
        guard let g = game, let v = view else { return }
        if g.offer.isEmpty { g.rollUpgrades() }
        levelUpScreen.show(level: g.xpLevel, offer: g.offer, cls: g.playerClass, size: size, insets: v.safeAreaInsets)
        mode = .levelUp
        input.reset()
        audio?.play(.levelup, pos: nil, listener: listener())
        haptics.play(.success)
    }

    private func chooseCard(_ k: Int) {
        guard let g = game else { return }
        if g.chooseUpgrade(k) != nil {
            audio?.play(.click, pos: nil, listener: listener())
            haptics.play(.select)
        }
        if g.wantsLevelUp { openLevelUp() } else { levelUpScreen.hide(); mode = .playing }
    }

    private func pause() {
        guard mode == .playing else { return }
        mode = .paused
        input.reset()
        menu.showPause(size: size, soundOn: audio?.enabled ?? false)
    }

    private func showEnd() {
        guard let g = game else { return }
        mode = .ended
        input.reset()
        menu.showEnd(size: size, stats: g.stats, surrendered: surrendered)
        AppLog.info("mission over won=\(g.phase == .won) time=\(formatTime(g.time)) kills=\(g.kills)")
    }

    /// App went to the background: pause like the web game.
    func appWillResignActive() { if mode == .playing { pause() } }

    // ---------------------------------------------------------------- touches
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view = view else { return }
        for t in touches {
            let p = t.location(in: view)
            let h = hud.hp(p.x, p.y)
            switch mode {
            case .loading:
                break
            case .title:
                if let a = titleScreen.hit(h) {
                    switch a {
                    case .select(let c):
                        selectedClass = c
                        titleScreen.layout(size: size, insets: view.safeAreaInsets, selected: c)
                        audio?.play(.click, pos: nil, listener: listener())
                        haptics.play(.select)
                    case .start:
                        audio?.play(.click, pos: nil, listener: listener())
                        startMission(selectedClass)
                    }
                }
            case .levelUp:
                if let k = levelUpScreen.hit(h) { chooseCard(k) }
            case .paused, .ended:
                if let a = menu.hit(h) { menuAction(a) }
            case .playing:
                if hud.pauseHit(viewPoint: p) { pause() } else { input.began(t, at: p) }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view = view else { return }
        for t in touches { input.moved(t, at: t.location(in: view)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { input.ended(t) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { input.ended(t) }
    }

    func keyDown(_ code: Int) {
        if code == UIKeyboardHIDUsage.keyboardEscape.rawValue || code == UIKeyboardHIDUsage.keyboardP.rawValue {
            if mode == .playing { pause() } else if mode == .paused { menuAction(.resume) }
            return
        }
        if mode == .title && (code == UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue) { startMission(selectedClass); return }
        if mode == .levelUp {
            if code == UIKeyboardHIDUsage.keyboard1.rawValue { chooseCard(0) }
            if code == UIKeyboardHIDUsage.keyboard2.rawValue { chooseCard(1) }
            if code == UIKeyboardHIDUsage.keyboard3.rawValue { chooseCard(2) }
            return
        }
        if mode == .ended && code == UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue { startMission(selectedClass); return }
        input.keyDown(code)
    }

    func keyUp(_ code: Int) { input.keyUp(code) }

    private func menuAction(_ a: MenuScreen.Action) {
        audio?.play(.click, pos: nil, listener: listener())
        switch a {
        case .resume:
            menu.hide(); mode = .playing
        case .sound:
            if let au = audio {
                au.master = au.master > 0 ? 0 : 0.8
                menu.showPause(size: size, soundOn: au.master > 0)
            }
        case .quit:
            surrendered = true
            menu.hide()
            showEnd()
        case .again:
            startMission(selectedClass)
        case .changeClass:
            showTitle()
        }
    }

    // ---------------------------------------------------------------- frame
    private func listener() -> Vec2 {
        guard let g = game else { return Vec2(0, 0) }
        return Vec2(g.player.x, g.player.z)
    }

    override func update(_ currentTime: TimeInterval) {
        if startTime < 0 { startTime = currentTime; lastTime = currentTime; lastFrameTime = currentTime; fpsWindowStart = currentTime; lastHeartbeat = currentTime }
        let dt = Float(min(0.1, max(0, currentTime - lastTime)))
        lastTime = currentTime
        frameCount += 1
        worstDt = max(worstDt, currentTime - lastFrameTime)
        lastFrameTime = currentTime
        guard let g = game, let r = renderer, mode != .loading else {
            advanceLoading()
            heartbeat(currentTime)
            return
        }
        updateCover(currentTime)
        sceneTimer.begin()

        // hit-stop slows the whole world (simulation + effects) for a few frames
        var ts: Float = 1
        if hitStopCd > 0 { hitStopCd -= dt }
        if hitStopT > 0 { hitStopT -= dt; ts *= hitStopK; if hitStopT <= 0 { hitStopK = 1 } }
        let running = mode == .playing || mode == .title
        let t0 = ProcessInfo.processInfo.systemUptime
        if running {
            if mode == .playing {
                let c = input.command()
                g.setPlayerInput(move: c.move, aim: c.aim, fire: c.fire, ability: c.ability, dash: c.dash, assist: c.assist)
                input.consumePresses()
            }
            demo?.frame(game: g, dt: dt)
            acc += Double(dt * ts)
            var steps = 0
            let step = Double(SIM_DT)
            while acc >= step && steps < 4 { g.tick(); acc -= step; steps += 1 }
            if acc > step { acc = step * 0.5 }
        }
        let t1 = ProcessInfo.processInfo.systemUptime
        simMs += ((t1 - t0) * 1000 - simMs) * 0.05
        sceneTimer.mark()

        drainEvents(g, r)
        sceneTimer.mark()

        if mode == .playing && g.wantsLevelUp && !g.autoPickUpgrades { openLevelUp() }
        if mode == .playing && g.phase != .playing {
            if endDelay < 0 { endDelay = 1.6 }
            endDelay -= dt
            if endDelay <= 0 && demo == nil { showEnd() }
        }
        // low armour heartbeat (app side, like the web UI)
        if mode == .playing && g.player.hp > 0 && g.player.hp < g.player.maxHp * 0.3 && !g.player.downed {
            heartT -= dt
            if heartT <= 0 { heartT = 0.9; audio?.play(.heart, pos: nil, listener: listener()) }
        }

        let alpha: Float = running ? Float(max(0, min(1, acc / Double(SIM_DT)))) : 1
        let vdt: Float = running ? dt * ts : 0
        renderTime += vdt
        let P = g.player
        let feet = (P.px + (P.x - P.px) * alpha, g.level.groundY(P.x, P.z), P.pz + (P.z - P.pz) * alpha)
        cameraCtl.update(game: g, feet: feet, dt: max(dt, 0.0001), viewSize: size, title: mode == .title, liftRise: g.liftRise)
        g.setVisibleArea(cameraCtl.visibleGround())
        sceneTimer.mark()
        let t1r = ProcessInfo.processInfo.systemUptime
        r.update(game: g, alpha: alpha, dt: vdt, time: renderTime, camera: cameraCtl)
        sceneTimer.mark()
        if mode != .title { hud.update(game: g, dt: dt, camera: cameraCtl, marines: r.marines, input: input) }
        sceneTimer.mark()
        let near = g.bugCountNear(Vec2(cameraCtl.tx, cameraCtl.tz))
        audio?.update(dt: dt, game: g, bugsNear: near, listener: listener(), title: mode == .title)
        sceneTimer.mark()
        let t2 = ProcessInfo.processInfo.systemUptime
        renderMs += ((t2 - t1r) * 1000 - renderMs) * 0.05
        // debug text 4× a second (every new string renders a new label texture)
        if hud.showDebug && currentTime - lastDebugText >= 0.25 {
            lastDebugText = currentTime
            hud.setDebug(String(format: "fps %.0f sim %.1f draw %.1f ms ", fps, simMs, renderMs) + mode.rawValue
                         + String(format: "\nжуки %d/%d част %d узлы %d+%d", g.bugsAlive, r.bugs.visibleCount,
                                  r.fx.pa.visibleCount + r.fx.pn.visibleCount, r.levelLayer.liveNodeCount, r.dynamicNodeCount))
        }
        heartbeat(currentTime)
    }

    private func drainEvents(_ g: Game, _ r: WorldRenderer) {
        let lis = listener()
        let inMission = mode != .title
        g.drainEvents { e in
            r.handle(e, game: g)
            switch e {
            case .sound(let id, let pos, _):
                audio?.play(id, pos: pos, listener: lis)
            case .shake(let a):
                cameraCtl.addShake(a)
            case .hitStop(let d, let k):
                if hitStopCd <= 0 { hitStopT = max(hitStopT, d); hitStopK = min(hitStopK, k); hitStopCd = d + 0.8 }
            case .screenFlash(let a):
                if inMission { hud.screenFlash(a) }
            case .damageFlash(let a):
                if inMission { hud.damageFlash(a) }
            case .hordeFlash:
                if inMission { hud.hordeFlash() }
            case .toast(let text, let kind):
                if inMission { hud.toast(text, kind: kind) }
            case .banner(let title, let sub, let teal):
                if inMission { hud.showBanner(title: title, subtitle: sub, teal: teal) }
            case .haptic(let k):
                if inMission { haptics.play(k) }
            case .victory, .defeat:
                AppLog.info("phase \(g.phase) at t=\(formatTime(g.time)) kills=\(g.kills)")
            default:
                break
            }
        }
    }

    /// Keep the cover up for a few frames after loading, then fade it out; its disappearance is "scene ready".
    private func updateCover(_ currentTime: TimeInterval) {
        guard cover.parent != nil else { return }
        coverFrames += 1
        let hold = 20
        if coverFrames == hold {
            loadingLabel?.node.removeFromParent()
            loadingSub?.node.removeFromParent()
        }
        if coverFrames >= hold {
            cover.alpha = max(0, 1 - CGFloat(coverFrames - hold) / 12)
            if cover.alpha <= 0 {
                cover.removeFromParent()
                readyTime = currentTime
                worstDt = 0
                AppLog.info(String(format: "loading took %.2f s (from the first frame)", currentTime - startTime))
                reportedReady = true
                AppLog.info("scene ready mode=\(mode.rawValue) size=\(Int(size.width))x\(Int(size.height)) levelNodes=\(renderer?.levelLayer.nodeCount ?? 0)")
            }
        }
    }

    private func heartbeat(_ currentTime: TimeInterval) {
        if currentTime - fpsWindowStart >= 1.0 {
            fps = Double(frameCount) / max(0.001, currentTime - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = currentTime
        }
        if currentTime - lastHeartbeat >= 1.0 {
            lastHeartbeat = currentTime
            let t = currentTime - startTime
            // demo time runs from "scene ready" (the end of loading); fps statistics skip its first second
            let td = readyTime > 0 ? currentTime - readyTime : -1
            let worst = worstDt * 1000
            worstDt = 0
            if let g = game, let r = renderer, readyTime > 0 {
                if td > 1.2 { fpsSum += fps; fpsSamples += 1; fpsMin = min(fpsMin, fps); worstMs = max(worstMs, worst) }
                AppLog.info(String(format: "hb t=%.1f td=%.1f fps=%.1f worst=%.0fms sim=%.2fms draw=%.2fms ", t, td, fps, worst, simMs, renderMs)
                            + "mode=\(mode.rawValue) bugs=\(g.bugsAlive) vis=\(r.bugs.visibleCount) parts=\(r.fx.pa.visibleCount + r.fx.pn.visibleCount) "
                            + "chunks=\(r.levelLayer.visibleChunks) nodes=\(r.levelLayer.nodeCount + r.dynamicNodeCount) stage=\(g.stage.rawValue) "
                            + "hp=\(Int(g.player.hp)) kills=\(g.kills) mem=\(Memory.footprintMB())MB demo=\(demo?.name ?? "-")")
            } else {
                AppLog.info(String(format: "hb t=%.1f fps=%.1f ", t, fps) + "mode=\(mode.rawValue) demo=\(demo?.name ?? "-")")
            }
            if let r = renderer, readyTime > 0 {
                AppLog.info("hb ms " + sceneTimer.summary + " | " + r.timer.summary + " | sfx \(audio?.played ?? 0)")
            }
            if let s = options.seconds, !reportedDone, td >= s {
                reportedDone = true
                let avg = fpsSamples > 0 ? fpsSum / Double(fpsSamples) : fps
                AppLog.info(String(format: "demo done after %.0fs avgFps=%.1f minFps=%.1f worstFrame=%.0fms", s, avg, fpsMin == 999 ? fps : fpsMin, worstMs)
                            + " mem=\(Memory.footprintMB())MB")
            }
        }
    }
}

/// Haptic feedback for HapticKind events.
final class Haptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let note = UINotificationFeedbackGenerator()
    private let sel = UISelectionFeedbackGenerator()
    private var last: Double = 0

    func play(_ k: HapticKind) {
        let now = ProcessInfo.processInfo.systemUptime
        if k == .light && now - last < 0.08 { return }
        last = now
        switch k {
        case .select: sel.selectionChanged()
        case .light: light.impactOccurred()
        case .medium: medium.impactOccurred()
        case .heavy: heavy.impactOccurred()
        case .success: note.notificationOccurred(.success)
        case .warning: note.notificationOccurred(.warning)
        case .error: note.notificationOccurred(.error)
        }
    }
}
