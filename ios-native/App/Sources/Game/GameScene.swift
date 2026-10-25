import SpriteKit
import UIKit
import IceHiveCore

// ================================================================
//  GAME SCENE — one SKScene for the whole game, driven by FrameLoop
//  through SKRenderer (no SKView): drives Game.tick() at a fixed
//  60 Hz with an accumulator (render interpolation between ticks,
//  hit-stop slow motion), routes GameEvents to the Metal world / HUD /
//  audio / haptics, and switches between the title (attract mode
//  behind), the mission, level-up cards, pause and the report. The
//  scene itself only holds the HUD, the menus and the loading cover;
//  MetalWorld draws the world underneath.
// ================================================================
final class GameScene: SKScene {
    enum Mode: String { case loading, title, playing, levelUp, paused, ended }

    let options: LaunchOptions
    private(set) var mode: Mode = .loading
    private var level: Level?
    private var game: Game?
    /// The Metal world (nil until its meshes and pipelines are ready).
    private var world: MetalWorld?
    /// Its renderer, for FrameLoop.
    var renderer: MetalRenderer? { world?.renderer }
    private weak var host: GameHost?
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
    /// Settings and records (UserDefaults, v1 values migrated on the first launch). Demos keep the v1.1 meta keys
    /// (profile, tier pick, coach flag, stick seconds) in memory, seeded by `-profile` / `-report` (DemoFixtures).
    private let settings: SettingsStore
    /// Menu / card / title buttons fire when the finger lifts over the target it went down on (web onTap); so does the
    /// coach card's «Пропустить» (a tap target, not a stick touch: it works while a thumb rests on the move stick).
    private enum TapTarget: Equatable { case title(TitleScreen.Action), card(Int), menu(MenuScreen.Action), coachSkip }
    /// How a mission starts (v1.1): an explicit tier / coach, else the rules of `startMission`.
    struct MissionOptions {
        var tier: Int? = nil
        var coach: Bool? = nil
    }
    /// The report of the mission that just ended (its buttons act on it).
    private var report: MissionReport?
    /// Rank-up haptic, 0.65 s after the report (scene time), -1 = none.
    private var rankUpHapticAt: Double = -1
    /// The report is built over the frames after the mission ends (MenuScreen.stepEnd): when it began, step timings.
    private var endBegunAt: Double = -1
    private var endStepMs: [Double] = []
    /// Cumulative thumb-stick seconds (VX-5 ghost sticks fade at 6; saved per whole second until then).
    private var stickUse: Float = 0
    /// Last logged threat state / lift lock (diagnostics lines on change).
    private var threatLogged = -1
    private var liftLockLogged = false
    private var taps: [ObjectIdentifier: TapTarget] = [:]
    /// Combo count of the last `.combo` event (pitch of the combo chime that follows it).
    private var comboForSound = 0

    // loop state
    private var acc: Double = 0
    private var lastTime: Double = -1
    private var renderTime: Float = 0
    private var hitStopT: Float = 0, hitStopK: Float = 1, hitStopCd: Float = 0
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
    /// Drawn frames (completed on the GPU) per second, over the measured window.
    private var drawnMin: Double = 999
    private var drawnSum: Double = 0
    private var gapWorst: Double = 0
    private var simMs: Double = 0
    private var renderMs: Double = 0
    private var reportedDone = false
    private var loadingLabel: Label?
    private var loadingSub: Label?
    /// Opaque cover over the world while loading and for the first frames after it (first submissions, texture
    /// residency and the HUD's first draws happen behind it), then faded out: the moment it is gone is "scene ready".
    private let cover = SKSpriteNode(color: Tone.hex(0x05070a), size: CGSize(width: 4000, height: 4000))
    /// Drawn frames since the world started behind the cover.
    private var coverFrames = 0
    /// GPU-completed frames when the world started (the cover waits for a few more).
    private var coverDoneBase = 0
    private var coverStart: Double = 0
    private var hudWasVisible = false
    private var readyTime: Double = -1
    private var loadStep = 0
    private var metalFailed = false
    private let sceneTimer = FrameTimer(["sim", "ev", "cam", "world", "hud", "au"])
    private var worstDt: Double = 0
    private var lastDebugText: Double = 0
    private var lastFrameTime: Double = 0
    private var worstMs: Double = 0
    private var hitchLogs = 0
    private var cpuProcLast: Double = 0
    private var cpuMainLast: Double = 0
    /// Ticks without a free frame slot / without a drawable at the last hitch line.
    private var skipsSeen = (0, 0)
    /// Effective graphics: the tier, with the thermal fallback applied (logged when it changes).
    private var thermalNote = ""

    private let metalPreload: MetalPreload?

    init(size: CGSize, options: LaunchOptions, host: GameHost, metalPreload: MetalPreload?) {
        self.metalPreload = metalPreload
        self.options = options
        self.host = host
        settings = options.demo != nil ? SettingsStore(volatileMeta: DemoFixtures.meta(options: options)) : SettingsStore()
        super.init(size: size)
        // the scene only draws the HUD / menus / loading cover over the composited world
        backgroundColor = .clear
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        if let mc = MarineClass(id: settings.cls) { selectedClass = mc }
        demo = DemoScript.make(options: options)
        if let c = options.playerClass ?? demo?.preferredClass, let mc = MarineClass(id: c) { selectedClass = mc }
        MetalRenderer.glintDots = options.glintDots
        haptics.enabled = settings.haptics
        if !settings.migrated.isEmpty { AppLog.info("settings: migrated from v1: " + settings.migrated.joined(separator: ",")) }
        AppLog.info("settings: cls=\(settings.cls) best=\(settings.bestKills)/\(settings.bestWin)s muted=\(settings.muted) vol=\(settings.vol) "
                    + "haptics=\(settings.haptics) quality=\(settings.quality)")
        let p = settings.profile
        AppLog.info("v11 meta: runs=\(p.runs) wins=\(p.wins) pick=\(settings.diffPick.map { String($0) } ?? "-") tut=\(settings.tutSeen ? 1 : 0) "
                    + "sticks=\(settings.stickSeconds) tier=\(Difficulty.tier(settings.effectiveTier).id) first=\(settings.isFirstMission ? 1 : 0)"
                    + (settings.volatileMeta ? " (demo, in memory)" : ""))
        stickUse = Float(settings.stickSeconds)
        hud.sticksLearned = settings.stickSeconds >= 6
        if let st = options.station {
            AppLog.info("v11 station \(st) ignored: generated stations are off (AppFeatures.generatedStations)")
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // ---------------------------------------------------------------- boot
    /// The loading screen (SKRenderer never calls didMove(to:): the view controller calls this once).
    func boot() {
        guard loadingLabel == nil else { return }
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

    /// Loading runs over several frames so the loading screen is on screen while the world loads.
    private func advanceLoading() {
        switch loadStep {
        case 0, 1:
            loadStep += 1          // let the loading screen render first
        case 2:
            loadStep = 3
            loadMetal()
        default:
            if let l = loadingSub, !metalFailed { l.node.alpha = 0.5 + 0.5 * CGFloat(sinf(Float(lastTime) * 4)) }
        }
    }

    private var started = false

    /// Meshes, textures and pipelines load off the main thread behind the loading cover (MetalPreload, started with the
    /// view), the HUD / input / audio meanwhile.
    private func loadMetal() {
        let t0 = FrameTimer.now()
        let lv = Level(source: KelvinStation(), seed: 1)
        level = lv
        cameraCtl.node.addChild(hud.root)
        cameraCtl.node.addChild(titleScreen.root)
        cameraCtl.node.addChild(levelUpScreen.root)
        cameraCtl.node.addChild(menu.root)
        hud.visible = false
        titleScreen.root.isHidden = true
        hud.showDebug = options.debugHUD && !options.storeShot
        input.hitAbility = { [weak self] p in
            guard let s = self else { return false }
            return s.hud.abilityButton.contains(hudPoint: s.hud.hp(p.x, p.y))
        }
        input.hitDash = { [weak self] p in
            guard let s = self else { return false }
            return s.hud.dashButton.contains(hudPoint: s.hud.hp(p.x, p.y))
        }
        applyReduceMotion()
        buildAudio()
        guard let pre = metalPreload else { showMetalFailure("no preload"); return }
        pre.whenReady { [weak self] prepared in
            guard let s = self else { return }
            guard let ready = prepared else {
                s.showMetalFailure("renderer unavailable")
                return
            }
            let w = MetalWorld(level: lv, store: ready.0, renderer: ready.1)
            s.world = w
            s.applyQuality()
            AppLog.info(String(format: "metal world ready in %.0f ms (preload %.0f ms, started %.0f ms before the scene) ",
                               (FrameTimer.now() - t0) * 1000, (pre.finished - pre.started) * 1000, max(0, t0 - pre.started) * 1000)
                        + Memory.summary)
            s.startAfterLoading()
        }
    }

    /// Metal could not start (no library / a required pipeline failed): a readable message on the cover instead of an
    /// endless loading screen.
    private func showMetalFailure(_ why: String) {
        metalFailed = true
        AppLog.error("metal: \(why)")
        loadingSub?.color = UIPalette.amber
        loadingSub?.set("НЕ УДАЛОСЬ ЗАПУСТИТЬ ГРАФИКУ (METAL)")
        loadingSub?.node.alpha = 1
        let hint = Label("ПЕРЕЗАПУСТИТЕ ИГРУ", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 2.5)
        hint.node.position = CGPoint(x: 0, y: -50)
        hint.node.zPosition = ZBand.hud + 901
        cameraCtl.node.addChild(hint.node)
        AppLog.info("metal: failure screen shown")
    }

    /// A new audio engine (boot, or after a media-services reset), built off the main thread.
    private func buildAudio() {
        let mute = options.mute
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let engine = AudioEngine(enabled: !mute)
            DispatchQueue.main.async {
                guard let s = self else { return }
                engine.master = s.settings.masterVolume
                engine.onMediaReset = { [weak s] in
                    DispatchQueue.main.async {
                        guard let sc = s else { return }
                        sc.audio = nil
                        sc.buildAudio()
                    }
                }
                s.audio = engine
            }
        }
    }

    /// The graphics tier in effect: the «Графика» setting, or the demo's own (swarmshot: high, like the store shots).
    private var qualityName: String { demo?.preferredQuality ?? settings.quality }

    /// «Графика»: auto = the web phone tier (med). Effect density, flashlight shadows (high), and 120 Hz for high apply
    /// at once; the bug cap (gameplay) is fixed per mission by newGame (GameConfig.quality), so a change from the pause
    /// menu sizes the swarm from the next mission on. A hot device (thermal .serious / .critical) falls back to the med
    /// effects without shadows and a 1.5x world image; .critical also caps the display at 30 Hz (applyFrameRate).
    func applyQuality() {
        let q = QualityTier(rawValue: qualityName) ?? .med
        var fxK: Float = q == .low ? 0.4 : (q == .med ? 0.7 : 1.0)
        var scale = CGFloat(options.metalScale ?? 2)
        let th = ProcessInfo.processInfo.thermalState
        let hot = th == .serious || th == .critical
        if hot {
            fxK = min(fxK, 0.7)
            scale = min(scale, 1.5)
        }
        world?.fxK = fxK
        host?.setWorldScale(scale)
        let note = hot ? "thermal \(th == .critical ? "critical" : "serious"): fxK \(fxK) scale \(scale)" : ""
        if note != thermalNote { thermalNote = note; if !note.isEmpty { AppLog.info(note) } }
        applyFrameRate()
    }

    /// 60 Hz normally; 120 on ProMotion only with «Графика: высокая» while the device is cool and not in Low Power
    /// Mode; 30 behind the menus (static screens over a frozen world) and when the device is critically hot.
    func applyFrameRate() {
        let menuUp = mode == .paused || mode == .ended || mode == .levelUp
        var fps = 60
        let pi = ProcessInfo.processInfo
        let cool = pi.thermalState == .nominal || pi.thermalState == .fair
        if qualityName == "high" && UIScreen.main.maximumFramesPerSecond >= 120 && cool && !pi.isLowPowerModeEnabled { fps = 120 }
        if menuUp || pi.thermalState == .critical { fps = 30 }
        host?.setFrameRate(fps)
    }

    /// iOS Reduce Motion: shake and recoil kick at 35 %, longer banner (web prefers-reduced-motion).
    func applyReduceMotion() {
        let on = UIAccessibility.isReduceMotionEnabled
        cameraCtl.reducedMotion = on
        hud.reducedMotion = on
    }

    /// Memory warning: rebuildable HUD textures and the live particles go; the footprint before / after is logged.
    func didReceiveMemoryWarning() {
        let before = Memory.summary
        HUDKitCaches.clear()
        world?.trim()
        AppLog.info("memory warning: " + before + " → " + Memory.summary)
    }

    private var insets: UIEdgeInsets { host?.safeAreaInsets ?? .zero }
    /// `-layoutCheck`: the HUD of the mission was checked.
    private var hudChecked = false

    /// Station of the title and the missions («Кельвин-9» while generated stations are off).
    private var stationName: String { level?.layout.name ?? "Кельвин-9" }

    /// The title (v1.1): profile line instead of the record, rank chips + medal pips on the class cards, the tier row.
    private func layoutTitle() {
        let t = settings.effectiveTier
        titleScreen.layout(size: size, insets: insets, selected: selectedClass, soundOn: !settings.muted,
                           meta: TitleScreen.Meta(profile: settings.profile, tier: t, station: stationName),
                           layoutCheck: options.layoutCheck)
        AppLog.info("v11 title tier=\(Difficulty.tier(t).id) runs=\(settings.profile.runs) pick=\(settings.diffPick.map { String($0) } ?? "-")")
    }

    private func startAfterLoading() {
        guard world != nil, !started else { return }
        started = true
        // the world now renders behind the cover: first submissions and residency happen before anyone sees a frame
        coverFrames = 0
        coverDoneBase = host?.timeline.completedFrames ?? 0
        coverStart = lastTime
        relayout()
        if let d = demo, d.startsMission {
            startMission(selectedClass)
        } else {
            showTitle()
        }
    }

    func relayout() {
        guard loadingLabel != nil else { return }
        input.viewSize = size
        hud.layout(size: size, insets: insets)
        if mode == .title { layoutTitle() }
        // a rotation under the pause menu or the report lays it out again for the new size
        if mode == .paused { menu.showPause(size: size, state: pauseState, layoutCheck: options.layoutCheck, insets: insets) }
        if mode == .ended, let r = report {
            menu.showEnd(size: size, insets: insets, report: r, layoutCheck: options.layoutCheck)
            applyFrameRate()   // (a rotation while the report was still being built: it is up now)
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if world != nil { relayout() }
    }

    // ---------------------------------------------------------------- modes
    private func newGame(attract: Bool, tier: Int = 1, coach: Bool = false) -> Game? {
        guard let lv = level else { return nil }
        var cfg = GameConfig()
        cfg.quality = QualityTier(rawValue: qualityName) ?? .med
        cfg.attract = attract
        // v1.1: the tier is fixed for the mission; the coach and the revive line only in real missions
        cfg.difficulty = Difficulty.tier(tier)
        cfg.coach = coach && !attract
        cfg.reviveLineArmed = !attract && settings.profile.runs < 3
        if options.queen { cfg.queenAt = 0 }
        cfg.queenHp = options.queenHp
        let seed: UInt32 = options.seed ?? UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000) & 0x7fff_ffff)
        return Game(seed: seed, playerClass: selectedClass, config: cfg, level: lv)
    }

    private func showTitle() {
        guard let g = newGame(attract: true) else { return }
        game = g
        world?.reset()
        cameraCtl.reset()
        acc = 0
        mode = .title
        input.reset()
        taps.removeAll()
        hud.visible = false
        menu.hide()
        levelUpScreen.hide()
        titleScreen.root.isHidden = false
        layoutTitle()
        applyFrameRate()
        AppLog.info("mode title")
    }

    /// «В бой», «Ещё раз», pause «Обучение» (coach), the report chip (after `setDiff(0)`): the tier is re-evaluated
    /// for every mission (spec §1.2) unless given; the coach runs on the first mission ever (or when asked).
    private func startMission(_ cls: MarineClass, _ mo: MissionOptions = MissionOptions()) {
        selectedClass = cls
        if demo == nil { settings.setClass(cls.id) }
        let tier: Int
        if let t = mo.tier { tier = t } else if let d = demo { tier = options.tier ?? d.defaultTier ?? settings.effectiveTier } else { tier = settings.effectiveTier }
        let coach = mo.coach ?? options.coach ?? ((demo == nil || demo?.name == "coach") ? settings.isFirstMission : false)
        guard let g = newGame(attract: false, tier: tier, coach: coach) else { return }
        game = g
        surrendered = false
        report = nil
        rankUpHapticAt = -1
        threatLogged = -1
        liftLockLogged = false
        world?.reset()
        cameraCtl.reset()
        input.reset()
        taps.removeAll()
        acc = 0
        heartT = 0
        hitStopT = 0; hitStopK = 1; hitStopCd = 0
        titleScreen.root.isHidden = true
        menu.hide()
        levelUpScreen.hide()
        hud.visible = true
        hud.setSquad(g.marines)
        relayout()
        mode = .playing
        applyFrameRate()
        demo?.begin(game: g)
        AppLog.info("mode playing class=\(cls.id) seed=\(g.seed) demo=\(demo?.name ?? "-")")
        AppLog.info("v11 start tier=\(g.difficulty.id) coach=\(g.coach.active ? 1 : 0) station=\(g.stationName) seed=\(g.seed)")
    }

    /// Thumbs held through a level-up or the pause menu keep steering afterwards (web showScreen): the sticks stay,
    /// only one-shot presses are dropped.
    private func openLevelUp() {
        guard let g = game else { return }
        if g.offer.isEmpty { g.rollUpgrades() }
        levelUpScreen.show(level: g.xpLevel - g.pendingLevels + 1, offer: g.offer, counts: g.upgradeCounts, cls: g.playerClass,
                           size: size, insets: insets, layoutCheck: options.layoutCheck)
        let first = mode != .levelUp
        mode = .levelUp
        input.consumePresses()
        if first {
            audio?.play(.levelup, pos: nil, listener: listener())
            haptics.play(.success)
        }
        applyFrameRate()
    }

    private func chooseCard(_ k: Int) {
        guard let g = game, mode == .levelUp, !levelUpScreen.locked else { return }
        if g.chooseUpgrade(k) != nil {
            audio?.play(.click, pos: nil, listener: listener())
            haptics.play(.select)
        }
        if g.wantsLevelUp { openLevelUp() } else { levelUpScreen.hide(); mode = .playing; applyFrameRate() }
    }

    private var pauseState: MenuScreen.PauseState {
        MenuScreen.PauseState(soundOn: !settings.muted, volume: settings.vol, quality: settings.quality, hapticsOn: settings.haptics,
                              tierName: game?.difficulty.name ?? Difficulty.veteran.name)
    }

    private func pause() {
        guard mode == .playing else { return }
        mode = .paused
        input.consumePresses()
        menu.showPause(size: size, state: pauseState, layoutCheck: options.layoutCheck, insets: insets)
        audio?.play(.click, pos: nil, listener: listener())
        applyFrameRate()
    }

    private func resume() {
        guard mode == .paused else { return }
        menu.hide()
        mode = .playing
        applyFrameRate()
    }

    /// Mission end (v1.1 spec §2.11): the run is committed into the profile once (surrender counts as a loss; demos
    /// commit into their in-memory profile), then the report (MissionReport, built in the core) is laid out.
    private func showEnd() {
        guard let g = game, mode != .ended else { return }
        mode = .ended
        input.reset()
        taps.removeAll()
        let tEnd = FrameTimer.now()
        let won = g.phase == .won
        if demo == nil { settings.recordMission(kills: g.kills, won: won, time: g.time) }
        let run = g.runSummary(won: won, surrendered: surrendered)
        var prof = settings.profile
        let res = prof.commit(run, diffPicked: settings.diffPick != nil)
        settings.saveProfile(prof)
        let rep = MissionReport.make(run: run, result: res, profile: prof, stats: g.stats, newStationShown: AppFeatures.generatedStations)
        report = rep
        let tModel = FrameTimer.now()
        // laid out over the next frames, one column per frame (stepPendingReport), so no frame pays for the whole screen;
        // the menus' 30 Hz comes with its last step: the build frames run at 60 Hz, and the rate switch lands on a tick
        // with ~2 ms of work instead of this one (the end events + the profile + the report model)
        menu.beginEnd(size: size, insets: insets, report: rep, layoutCheck: options.layoutCheck)
        endBegunAt = lastTime
        endStepMs.removeAll()
        if res.rankUp { rankUpHapticAt = lastTime + 0.65 }
        if AppLog.diagnostics {
            AppLog.info(String(format: "end tick: profile + report model %.1f ms, menu reset %.1f ms", (tModel - tEnd) * 1000,
                               (FrameTimer.now() - tModel) * 1000))
        }
        let q = !run.queenSpawned ? "none" : (run.queenDone ? "killed" : "alive")
        AppLog.info("mission over won=\(won) time=\(formatTime(g.time)) kills=\(g.kills) record=\(res.record)")
        AppLog.info("v11 run tier=\(g.difficulty.id) won=\(won ? 1 : 0) surrendered=\(run.surrendered ? 1 : 0) downs=\(run.downs) "
                    + "downBy=\(run.downBy.rawValue) stage=\(run.stage.rawValue) beacons=\(run.beaconsDone) queen=\(q) score=\(res.score.total) "
                    + "xp=\(res.xp) rank=\(res.rank0)→\(res.rank1) medal=\(res.medal ? 1 : 0) recTip=\(res.recTip ? 1 : 0) record=\(res.record ? 1 : 0) "
                    + String(format: "t=%.0f", g.time))
    }

    /// One piece of the pending report (column A, column B + fit, placement); the step times are logged once it is up.
    private func stepPendingReport() {
        let t0 = FrameTimer.now()
        let done = menu.stepEnd()
        endStepMs.append((FrameTimer.now() - t0) * 1000)
        if done {
            AppLog.info("report built in \(endStepMs.count) frames: " + endStepMs.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " ms")
            applyFrameRate()
        }
    }

    /// App went to the background: pause like the web game.
    func appWillResignActive() { if mode == .playing { pause() } }

    /// Back in the foreground: the audio session may have been taken over meanwhile.
    func appDidBecomeActive() { audio?.restart("app active") }

    // ---------------------------------------------------------------- touches (forwarded by GameView)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view = host?.touchView else { return }
        for t in touches {
            let p = t.location(in: view)
            let h = hud.hp(p.x, p.y)
            let id = ObjectIdentifier(t)
            switch mode {
            case .loading:
                break
            case .title:
                if let a = titleScreen.hit(h) { taps[id] = .title(a) }
            case .levelUp:
                if let k = levelUpScreen.hit(h) { taps[id] = .card(k) }
            case .paused, .ended:
                if let a = menu.hit(h) { taps[id] = .menu(a) }
            case .playing:
                if hud.pauseHit(viewPoint: p) { pause() } else if hud.coachSkipHit(h) { taps[id] = .coachSkip } else { input.began(t, at: p) }
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view = host?.touchView else { return }
        for t in touches { input.moved(t, at: t.location(in: view)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view = host?.touchView else { return }
        for t in touches {
            input.ended(t)
            guard let target = taps.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            let p = t.location(in: view)
            let h = hud.hp(p.x, p.y)
            switch target {
            case .title(let a):
                if mode == .title && titleScreen.hit(h) == a { titleAction(a) }
            case .card(let k):
                if mode == .levelUp && levelUpScreen.hit(h) == k { chooseCard(k) }
            case .menu(let a):
                if (mode == .paused || mode == .ended) && menu.hit(h) == a { menuAction(a) }
            case .coachSkip:
                if mode == .playing && hud.coachSkipHit(h) { game?.coachSkip() }
            }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            input.ended(t)
            taps.removeValue(forKey: ObjectIdentifier(t))
        }
    }

    private func titleAction(_ a: TitleScreen.Action) {
        switch a {
        case .select(let c):
            selectedClass = c
            settings.setClass(c.id)
            layoutTitle()
            audio?.play(.click, pos: nil, listener: listener())
            haptics.play(.select)
        case .start:
            audio?.play(.click, pos: nil, listener: listener())
            startMission(selectedClass)
        case .sound:
            settings.setMuted(!settings.muted)
            audio?.master = settings.masterVolume
            layoutTitle()
            audio?.play(.click, pos: nil, listener: listener())
        case .tier(let i):
            // one tap = the player's pick (stored), the row redrawn
            settings.setDiff(i)
            layoutTitle()
            audio?.play(.click, pos: nil, listener: listener())
            haptics.play(.select)
        }
    }

    func keyDown(_ code: Int) {
        if code == UIKeyboardHIDUsage.keyboardEscape.rawValue || code == UIKeyboardHIDUsage.keyboardP.rawValue {
            if mode == .playing { pause() } else if mode == .paused { menuAction(.resume) }
            return
        }
        if mode == .levelUp && levelUpScreen.locked { return }
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
        switch a {
        case .resume:
            audio?.play(.click, pos: nil, listener: listener())
            resume()
        case .sound:
            settings.setMuted(!settings.muted)
            audio?.master = settings.masterVolume
            audio?.play(.click, pos: nil, listener: listener())
            menu.showPause(size: size, state: pauseState, layoutCheck: options.layoutCheck, insets: insets)
        case .volume:
            settings.cycleVolume()
            if settings.muted { settings.setMuted(false) }
            audio?.master = settings.masterVolume
            audio?.play(.click, pos: nil, listener: listener())
            menu.showPause(size: size, state: pauseState, layoutCheck: options.layoutCheck, insets: insets)
        case .quality:
            let order = ["auto", "low", "med", "high"]
            let k = order.firstIndex(of: settings.quality) ?? 0
            settings.setQuality(order[(k + 1) % order.count])
            applyQuality()
            audio?.play(.click, pos: nil, listener: listener())
            menu.showPause(size: size, state: pauseState, layoutCheck: options.layoutCheck, insets: insets)
            AppLog.info("quality \(settings.quality) bugCap=\(game?.bugCap ?? 0) next=\((QualityTier(rawValue: qualityName) ?? .med).bugCap)")
        case .haptics:
            settings.setHaptics(!settings.haptics)
            haptics.enabled = settings.haptics
            audio?.play(.click, pos: nil, listener: listener())
            haptics.play(.select)
            menu.showPause(size: size, state: pauseState, layoutCheck: options.layoutCheck, insets: insets)
        case .tutorial:
            // «Обучение»: the current class again, with «Учебная высадка» (the abandoned mission is not committed)
            audio?.play(.click, pos: nil, listener: listener())
            startMission(selectedClass, MissionOptions(coach: true))
        case .quit:
            // web endGame(false, true): the defeat sting, no error haptic
            surrendered = true
            menu.hide()
            audio?.play(.click, pos: nil, listener: listener())
            audio?.play(.defeat, pos: nil, listener: listener())
            showEnd()
        case .again, .newStation:
            // (no «Новая станция» while generated stations are off: same station either way)
            audio?.play(.click, pos: nil, listener: listener())
            startMission(selectedClass)
        case .changeClass:
            audio?.play(.click, pos: nil, listener: listener())
            showTitle()
        case .chip:
            // «Попробуйте «Новобранец»» (only on the report of a loss): the pick becomes Новобранец, same class again
            guard mode == .ended, report?.won == false else { return }
            settings.setDiff(0)
            audio?.play(.click, pos: nil, listener: listener())
            startMission(selectedClass)
        }
    }

    // ---------------------------------------------------------------- frame
    private func listener() -> Vec2 {
        guard let g = game else { return Vec2(0, 0) }
        return Vec2(g.player.x, g.player.z)
    }

    /// One display-link tick (SKRenderer.update → here): simulation, events, camera, the world frame (built only when
    /// FrameLoop holds a free slot), HUD, audio.
    override func update(_ currentTime: TimeInterval) {
        if startTime < 0 { startTime = currentTime; lastTime = currentTime; lastFrameTime = currentTime; fpsWindowStart = currentTime; lastHeartbeat = currentTime }
        let dt = Float(min(0.1, max(0, currentTime - lastTime)))
        lastTime = currentTime
        frameCount += 1
        let frameDt = currentTime - lastFrameTime
        worstDt = max(worstDt, frameDt)
        lastFrameTime = currentTime
        // long ticks (> 50 ms) with a wall-clock stamp (CI correlates them with its screenshot times): upd / draw = the
        // tick before: scene update (+ world build), then nextDrawable / world encode / composite + HUD / commit; skip =
        // ticks that did not draw since the last such line (no free frame slot / no free drawable); cb = the slowest recent command buffer,
        // commit → done (waiting to be scheduled, GPU time): far more than its GPU time = the GPU was held up outside
        // the app
        if AppLog.diagnostics && frameDt > 0.05 && readyTime > 0 && hitchLogs < 60, let h = host {
            hitchLogs += 1
            let lt = h.lastTick
            let slots = h.slotMissTotal - skipsSeen.0, draws = h.noDrawableTotal - skipsSeen.1
            skipsSeen = (h.slotMissTotal, h.noDrawableTotal)
            AppLog.info(String(format: "hitch %.0f ms td=%.2f wall=%.3f ", frameDt * 1000, currentTime - readyTime,
                               Date().timeIntervalSince1970) + lt.summary + String(format: " skip=%d/%d ", slots, draws)
                        + h.timeline.worstRecent() + " vis=\(world?.stats.visibleBugs ?? 0) parts=\(world?.stats.particles ?? 0)")
        }
        guard let g = game, let r = world, mode != .loading else {
            advanceLoading()
            heartbeat(currentTime)
            return
        }
        updateCover(currentTime)
        sceneTimer.begin()

        // hit-stop slows the whole world (simulation + effects) for a few frames
        var ts: Float = demo?.timeScale ?? 1
        if hitStopCd > 0 { hitStopCd -= dt }
        if hitStopT > 0 { hitStopT -= dt; ts *= hitStopK; if hitStopT <= 0 { hitStopK = 1 } }
        let running = mode == .playing || mode == .title
        let t0 = FrameTimer.now()
        if running {
            if mode == .playing {
                let c = input.command()
                g.setPlayerInput(move: c.move, aim: c.aim, fire: c.fire, ability: c.ability, dash: c.dash, assist: c.assist)
                input.consumePresses()
            }
            demo?.sinceReady = readyTime > 0 ? currentTime - readyTime : -1
            demo?.frame(game: g, dt: dt)
            if let pr = demo?.probe { runProbe(pr, g) }
            if let rq = demo?.request {
                switch rq {
                case .pause: pause()
                case .surrender: if mode == .playing { pause(); menuAction(.quit) }
                case .end: if mode == .playing { showEnd() }
                case .layoutSizes: LayoutSizes.run(game: g, station: stationName)
                }
            }
            acc += Double(dt * ts)
            var steps = 0
            let step = Double(SIM_DT)
            while acc >= step && steps < 4 { g.tick(); acc -= step; steps += 1 }
            if acc > step { acc = step * 0.5 }
        }
        let t1 = FrameTimer.now()
        simMs += ((t1 - t0) * 1000 - simMs) * 0.05
        sceneTimer.mark()

        drainEvents(g, r)
        sceneTimer.mark()

        if mode == .playing { trackV11(g, dt) }
        // -layoutCheck in a mission: the HUD on this phone, once, a second into the measured window
        if options.layoutCheck && !hudChecked && mode == .playing && readyTime > 0 && lastTime - readyTime >= 1 {
            hudChecked = true
            hud.checkLayout()
        }
        if rankUpHapticAt > 0 && lastTime >= rankUpHapticAt { rankUpHapticAt = -1; haptics.play(.success) }
        if mode == .playing && g.wantsLevelUp && !g.autoPickUpgrades { openLevelUp() }
        // the report comes up at once over the frozen world, like the web endGame()
        if mode == .playing && g.phase != .playing && demo == nil { showEnd() }
        if mode == .ended && menu.endPending && lastTime > endBegunAt { stepPendingReport() }
        // low armour heartbeat (app side, like the web audioUpdate): faster as the armour falls
        heartT -= dt
        let P0 = g.player
        if mode == .playing && !P0.downed && P0.hp < P0.maxHp * 0.3 && heartT <= 0 {
            heartT = 0.55 + 0.5 * P0.hp / (P0.maxHp * 0.3)
            audio?.play(.heart, pos: nil, listener: listener())
        }

        let live = mode == .playing || mode == .title
        let alpha: Float = live ? Float(max(0, min(1, acc / Double(SIM_DT)))) : 1
        let vdt: Float = live ? dt * ts : 0
        renderTime += vdt
        let P = g.player
        let feet = (P.px + (P.x - P.px) * alpha, g.level.groundY(P.x, P.z), P.pz + (P.z - P.pz) * alpha)
        let near = g.bugCountNear(Vec2(cameraCtl.tx, cameraCtl.tz))
        cameraCtl.update(game: g, feet: feet, dt: max(dt, 0.0001), viewSize: size, title: mode == .title, liftRise: g.liftRise, bugsNear: near)
        sceneTimer.mark()
        let t1r = FrameTimer.now()
        r.update(game: g, alpha: alpha, dt: vdt, time: renderTime, camera: cameraCtl, viewSize: size, frozen: !live)
        sceneTimer.mark()
        if mode != .title {
            hud.covered = mode == .paused || mode == .ended || mode == .levelUp
            hud.update(game: g, dt: dt, projection: r, input: input, keyboard: input.keyboardMode)
        }
        sceneTimer.mark()
        audio?.update(dt: dt, game: g, bugsNear: near, listener: listener(), title: mode == .title, live: live)
        sceneTimer.mark()
        let t2 = FrameTimer.now()
        renderMs += ((t2 - t1r) * 1000 - renderMs) * 0.05
        // debug text 4× a second (every new string renders a new label texture)
        if hud.showDebug && currentTime - lastDebugText >= 0.25 {
            lastDebugText = currentTime
            let st = r.stats
            hud.setDebug(String(format: "fps %.0f sim %.1f мир %.1f enc %.1f gpu %.1f ms ", fps, simMs, renderMs, st.encodeMs,
                                host?.timeline.gpuEmaMs ?? 0) + mode.rawValue
                         + String(format: "\nжуки %d/%d част %d вызовы %d инст %d тр %dk", g.bugsAlive, st.visibleBugs,
                                  st.particles, st.drawCalls, st.instances, st.triangles / 1000))
        }
        heartbeat(currentTime)
    }

    private func drainEvents(_ g: Game, _ r: MetalWorld) {
        let lis = listener()
        let inMission = mode != .title
        let diag = AppLog.diagnostics
        let endPendingDrain = mode == .ended && menu.endPending
        g.drainEvents { e in
            let te = diag ? FrameTimer.now() : 0
            defer {
                // CI attribution of multi-second stalls inside the event drain (579f726: 7–9 s once per run)
                if diag {
                    let ms = (FrameTimer.now() - te) * 1000
                    // (the mission-end tick, which also builds the profile and the report model: anything over 3 ms)
                    if ms > (endPendingDrain ? 3 : 40) {
                        AppLog.info(String(format: "slow event %.0f ms: ", ms) + String(String(describing: e).prefix(80)))
                    }
                }
            }
            r.handle(e, game: g)
            switch e {
            case .combo(let c):
                comboForSound = c
            case .sound(let id, let pos, let loud):
                // the combo chime climbs with the counter (web: 520 Hz · 1.06^min(24, combo / 5))
                let rate: Float = id == .combo ? powf(1.06, Float(min(24, comboForSound / 5))) : 1
                audio?.play(id, pos: pos, listener: lis, loud: loud, rate: rate)
            case .shake(let a):
                cameraCtl.addShake(a)
            case .hitStop(let d, let k):
                if hitStopCd <= 0 { hitStopT = max(hitStopT, d); hitStopK = min(hitStopK, k); hitStopCd = d + 0.8 }
            case .screenFlash(let a):
                if inMission { hud.screenFlash(a) }
                noteFirst(0, "screenFlash")
            case .damageFlash(let a):
                if inMission { hud.damageFlash(a) }
            case .hordeFlash:
                if inMission { hud.hordeFlash() }
            case .toast(let text, let kind):
                if inMission { hud.toast(text, kind: kind) }
                noteFirst(1, "toast")
            case .banner(let title, let sub, let teal):
                if inMission { hud.showBanner(title: title, subtitle: sub, teal: teal) }
                noteFirst(2, "banner")
            case .haptic(let k):
                if inMission { haptics.play(k) }
            case .victory, .defeat:
                AppLog.info("phase \(g.phase) at t=\(formatTime(g.time)) kills=\(g.kills)")
            case .explosion(let kind, _, _):
                noteFirst(10 + kind.rawValue, "explosion.\(kind)")
            case .ability(_, let kind, _, _):
                noteFirst(20 + kind.rawValue, "ability.\(kind)")
            case .telegraph(_, let shape, _, _):
                noteFirst(30 + shape.rawValue, "telegraph.\(shape)")
            case .acidLaunched:
                noteFirst(3, "acid")
            case .levelUp:
                noteFirst(4, "levelUp")
            case .hordeStarted:
                noteFirst(5, "horde")
            case .downed:
                noteFirst(6, "downed")
            case .queenKilled:
                // v1.1: the Матка's death always gets its hit-stop (the core emits it right after this event)
                hitStopCd = 0
                logQueen("kill", g)
            case .queenWarning:
                logQueen("warn", g)
            case .queenSpawned:
                logQueen("spawn", g)
            case .queenEnraged:
                logQueen("enrage", g)
            case .coachStep(let k):
                if diag { AppLog.info("v11 coach step=\(k)") }
            case .coachSeen:
                // «Учебная высадка» seen enough: never forced again (memory only in demos)
                settings.setTutSeen()
                if diag { AppLog.info("v11 coach seen") }
            case .coachEnded:
                if diag { AppLog.info("v11 coach end") }
            default:
                break
            }
        }
    }

    /// v1.1 per frame while playing: diagnostics lines on threat / lift-lock changes, and the thumb-stick seconds
    /// (stored per whole second until 6, then the resting sticks fade: VX-5 ghost sticks).
    private func trackV11(_ g: Game, _ dt: Float) {
        if AppLog.diagnostics {
            let ts = g.threatState.rawValue
            if ts != threatLogged {
                threatLogged = ts
                AppLog.info(String(format: "v11 threat %d t=%.1f", ts, g.time) + String(format: " pressure=%.1f", g.pressure))
            }
            let locked = g.liftLocked
            if locked != liftLockLogged {
                liftLockLogged = locked
                if locked { AppLog.info(String(format: "v11 lift locked t=%.1f", g.time)) }
            }
        }
        if stickUse < 6 && (input.left != nil || input.right != nil) {
            stickUse += dt
            let whole = Int(stickUse)
            if whole > settings.stickSeconds { settings.setStickSeconds(whole) }
            if stickUse >= 6 { hud.sticksLearned = true }
        }
    }

    /// «v11 queen warn|spawn|enrage|kill t= uid= hp=» (diagnostics; her health from the core's threat view).
    private func logQueen(_ what: String, _ g: Game) {
        guard AppLog.diagnostics else { return }
        let td = g.threatDebug
        AppLog.info(String(format: "v11 queen %@ t=%.1f uid=%d hp=%.0f", what, g.time, Int(g.queen.uid), td.queenHpMax)
                    + " tier=\(g.difficulty.id)")
    }

    /// `-demo probe`: one ingredient of a horde at a time, logged, so CI can tell which one hitches.
    private func runProbe(_ p: DemoScript.Probe, _ g: Game) {
        let td = readyTime > 0 ? lastTime - readyTime : -1
        AppLog.info("probe " + p.rawValue + String(format: " td=%.2f wall=%.3f", td, Date().timeIntervalSince1970))
        switch p {
        case .overlay: hud.hordeFlash()
        case .banner: hud.showBanner(title: "ОРДА!", subtitle: "РОЙ ПРОРЫВАЕТСЯ ИЗ БЕЗДНЫ", teal: false)
        case .shake: cameraCtl.addShake(0.25)
        case .sounds:
            audio?.play(.siren, pos: nil, listener: listener())
            audio?.play(.hordeRoar, pos: nil, listener: listener())
        case .haptic: haptics.play(.warning)
        case .horde: g.debugHorde(300)
        }
    }

    /// Diagnostics: the first time an event kind shows up (mid-game hitches are usually first uses). Keyed by a
    /// small code; the name is only formatted that first time.
    private var firstSeen = [Bool](repeating: false, count: 48)
    private func noteFirst(_ code: Int, _ name: @autoclosure () -> String) {
        guard AppLog.diagnostics, code >= 0, code < firstSeen.count, !firstSeen[code] else { return }
        firstSeen[code] = true
        let td = readyTime > 0 ? lastTime - readyTime : -1
        AppLog.info("first " + name() + String(format: " td=%.2f", td))
    }

    /// Keep the cover up after loading while the HUD's overlays and the first effects are drawn once behind it and until
    /// the GPU has finished a few world frames, then fade it out; its disappearance is "scene ready".
    private var coverStage = 0
    /// Menu warm-up step behind the cover: 1 pause, 2 report, 3 level-up cards.
    private var menuWarm = 0
    private var coverFadeFrom = 0
    private func updateCover(_ currentTime: TimeInterval) {
        guard cover.parent != nil else { return }
        // only ticks that draw count: the first world frames can take a few hundred ms to come back (first submission,
        // residency) and the loop does not draw while both frame slots are busy
        if host?.frameOpen ?? true { coverFrames += 1 }
        let hold = 20
        // warm-up behind the cover: every HUD overlay, a banner, toasts, and every explosion / kill / frost / acid effect
        // once, then a few clean frames
        if coverStage == 0 && coverFrames >= 2 {
            coverStage = 1
            hudWasVisible = hud.visible
            hud.visible = true
            hud.warmUp(true)
            if let g = game { world?.warmUp(game: g, at: Vec2(cameraCtl.tx, cameraCtl.tz)) }
            // the menus too (their first build + first draw cost 40–80 ms: CI pause / end): pause, then the report,
            // then level-up cards, each drawn a few frames under the cover
            if mode == .playing || mode == .title { menu.showPause(size: size, state: pauseState) }
            // the title with its tier row and profile line is on screen behind the cover in a normal launch already
            menuWarm = 1
        }
        // (a menu the game itself opened meanwhile — a slow first launch, a demo — is left alone)
        let menuUp = mode == .levelUp || mode == .paused || mode == .ended
        // the report once: a first evacuation (strip, breakdown, rank-up, medal, a tip, the goal)
        if coverStage == 1 && menuWarm == 1 && coverFrames >= 6, let g = game {
            if !menuUp { menu.showEnd(size: size, insets: insets, report: DemoFixtures.warmReport(cls: selectedClass, stats: g.stats, station: g.stationName)) }
            menuWarm = 2
        }
        if coverStage == 1 && menuWarm == 2 && coverFrames >= 10 {
            if !menuUp {
                menu.hide()
                levelUpScreen.show(level: 2, offer: Array(UPGRADES.prefix(3)), counts: [:], cls: selectedClass, size: size, insets: insets)
            }
            menuWarm = 3
        }
        if coverStage == 1 && coverFrames >= hold - 5 {
            coverStage = 2
            hud.warmUp(false)
            hud.visible = hudWasVisible
            if mode != .paused && mode != .ended { menu.hide() }
            if mode != .levelUp { levelUpScreen.hide() }
            world?.reset()
        }
        if coverStage == 2 && coverFrames >= hold {
            let done = (host?.timeline.completedFrames ?? 0) - coverDoneBase
            guard done >= hold || currentTime - coverStart > 6 else { return }
            coverStage = 3
            coverFadeFrom = coverFrames
            loadingLabel?.node.removeFromParent()
            loadingSub?.node.removeFromParent()
        }
        if coverStage == 3 {
            cover.alpha = max(0, 1 - CGFloat(coverFrames - coverFadeFrom) / 12)
            if cover.alpha <= 0 {
                cover.removeFromParent()
                readyTime = currentTime
                worstDt = 0
                skipsSeen = (host?.slotMissTotal ?? 0, host?.noDrawableTotal ?? 0)
                _ = host?.timeline.takeWindow()
                AppLog.info(String(format: "loading took %.2f s (from the first frame)", currentTime - startTime))
                AppLog.info("scene ready mode=\(mode.rawValue) size=\(Int(size.width))x\(Int(size.height)) renderer=metal")
            }
        }
    }

    private func heartbeat(_ currentTime: TimeInterval) {
        if currentTime - fpsWindowStart >= 1.0 {
            fps = Double(frameCount) / max(0.001, currentTime - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = currentTime
        }
        if AppLog.diagnostics && currentTime - lastHeartbeat >= 1.0 {
            let span = max(0.001, currentTime - lastHeartbeat)
            lastHeartbeat = currentTime
            // CPU utilisation since the last heartbeat (% of one core): whole process / main thread
            let cp = CPUTime.process(), cm = CPUTime.thread()
            let cpuPct = cpuProcLast > 0 ? (cp - cpuProcLast) / span * 100 : 0
            let mainPct = cpuMainLast > 0 ? (cm - cpuMainLast) / span * 100 : 0
            cpuProcLast = cp
            cpuMainLast = cm
            let t = currentTime - startTime
            // demo time runs from "scene ready" (the end of loading); fps statistics skip its first 1.2 s
            let td = readyTime > 0 ? currentTime - readyTime : -1
            let worst = worstDt * 1000
            worstDt = 0
            // GPU side of the same second: frames completed (drawn), the longest gap between two of them, the slowest
            // command buffer (commit → done), GPU time; loop side: ticks without a free slot, drawable waits
            let tw = host?.timeline.takeWindow() ?? GPUTimeline.Window()
            let cn = host?.takeCounters() ?? (slotMisses: 0, noDrawable: 0, drawableMaxMs: 0)
            let hs = host?.takeHUDStats() ?? FrameLoop.HUDStats()
            let drawn = Double(tw.completed) / span
            if let g = game, let r = world, readyTime > 0 {
                if td > 1.2 {
                    fpsSum += fps; fpsSamples += 1; fpsMin = min(fpsMin, fps); worstMs = max(worstMs, worst)
                    drawnSum += drawn; drawnMin = min(drawnMin, drawn); gapWorst = max(gapWorst, tw.maxGapMs)
                }
                let st = r.stats
                AppLog.info(String(format: "hb t=%.1f td=%.1f fps=%.1f worst=%.0fms drawn=%.0f gap=%.0fms sim=%.2fms world=%.2fms ",
                                   t, td, fps, worst, drawn, tw.maxGapMs, simMs, renderMs)
                            + "mode=\(mode.rawValue) bugs=\(g.bugsAlive) vis=\(st.visibleBugs) parts=\(st.particles) stage=\(g.stage.rawValue) "
                            + "hp=\(Int(g.player.hp)) kills=\(g.kills) " + Memory.summary + " demo=\(demo?.name ?? "-") rend=metal"
                            + String(format: " cpu=%.0f main=%.0f dc=%d inst=%d tris=%d enc=%.2fms gpu=%.2fms gpumax=%.1fms skip=%d nodraw=%d drw=%.0fms cbmax=%.0fms",
                                     cpuPct, mainPct, st.drawCalls, st.instances, st.triangles, st.encodeMs, host?.timeline.gpuEmaMs ?? 0,
                                     tw.gpuMaxMs, cn.slotMisses, cn.noDrawable, cn.drawableMaxMs, tw.worst.latencyMs)
                            + String(format: " sk=%.0fms/%d skcpu=%.0fms skslow=%d/%d", hs.maxMs, hs.labelsAtMax, hs.cpuAtMax, hs.slowWithText, hs.slowNoText))
                AppLog.info("hb ms " + sceneTimer.summary + " | " + r.timer.summary + " | sfx \(audio?.played ?? 0)"
                            + " | max " + sceneTimer.takeMax() + " / " + r.timer.takeMax())
            } else {
                AppLog.info(String(format: "hb t=%.1f fps=%.1f drawn=%.0f ", t, fps, drawn) + "mode=\(mode.rawValue) demo=\(demo?.name ?? "-")")
            }
            if let s = options.seconds, !reportedDone, td >= s {
                reportedDone = true
                let avg = fpsSamples > 0 ? fpsSum / Double(fpsSamples) : fps
                let davg = fpsSamples > 0 ? drawnSum / Double(fpsSamples) : drawn
                // fps / worstFrame: the game loop (simulation, input, HUD, audio); drawn / worstGap: frames the GPU
                // completed and the longest time the screen kept one image
                AppLog.info(String(format: "demo done after %.0fs avgFps=%.1f minFps=%.1f worstFrame=%.0fms drawnAvg=%.1f drawnMin=%.1f worstGap=%.0fms",
                                   s, avg, fpsMin == 999 ? fps : fpsMin, worstMs, davg, drawnMin == 999 ? drawn : drawnMin, gapWorst)
                            + " " + Memory.summary)
            }
        }
    }
}
