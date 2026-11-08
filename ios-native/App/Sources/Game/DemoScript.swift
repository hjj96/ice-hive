import Foundation
import IceHiveCore

// ================================================================
//  DEMO SCRIPTS — scripted scenarios for CI screenshots / perf logs:
//    -demo combat   mission (assault unless -class), squad invulnerable, autopilot, a crowd spawned around the
//                   squad and kept topped up: 600, but never more than the mission's live cap (native-vx-feel: 250 on
//                   Medium — the wave pacing's peak; `-bugs N` asks for N past the cap: the renderer stress runs)
//    -demo beacon   mission started next to beacon «Alpha» with a crowd (350, under the live cap like combat)
//    -demo title    the title screen (attract mode behind)
//    -demo calm     mission start with the director off: no bugs, the squad idles on the
//                   landing pad (lighting / station look)
//    -demo layout   like calm; 1 s after «scene ready» every screen is laid out and checked on the four
//                   landscape phones (LayoutSizes: «layout ok|FAIL …», «layout sizes: N ok, M FAIL»)
//    -demo smoke    alias of combat (the original CI scenario name)
//    -demo probe    combat, plus one horde ingredient every 4 s (overlay, banner, shake, sounds,
//                   haptic, then a real horde) — CI hitch attribution
//    -demo hold     beacons skipped, the squad on the lift holding out against the hold's own swarm (native-vx-feel:
//                   nothing spawned by the demo — the director's opening horde, a third of it over the lift's rim)
//    -demo extract  like hold, then the lift rises and stays at extract + 2 s (gore rides along)
//    -demo queen    like hold, and the Queen (v1.1 boss of the hold) climbs up 2 s after «scene ready» (1 000 000 HP
//                   unless -queenHp, so she stays on the deck for the screenshot)
//    -demo queenlock  queen, then the lift countdown runs out 1.5 s later: «Lift locked — the Queen lives»
//    -demo coach    the first mission ever on the fresh demo profile: «Учебная высадка» runs (autopilot off, so the
//                   steps advance by their timeouts; -coachStep N jumps), the next step 1.5 s after «scene ready»,
//                   then time almost stopped so the screenshot shows that step
//    -demo pressure Ветеран, nobody touches the screen: fast-forward to 15.5 s, the hive pressure then pinned in the
//                   amber band (-pressure amber), or amber until 1.5 s after «scene ready» and then red
//    -demo report   the mission report of a fixture (-report first|win|loss|chip): the run's outcome is forced and
//                   committed into the demo's in-memory profile 2 s after «scene ready»
//    -demo levelup  a forced level-up 2 s after «scene ready»: the upgrade cards
//    -demo pause    the pause menu 2 s after «scene ready»
//    -demo end      surrender 2 s after «scene ready»: the mission report (record highlight on)
//  (the v1.1 state changes come inside the frame gate's window, from 1.2 s after «scene ready»: their first draw is
//  measured, not hidden in the first second)
//    -demo swarmshot  the App Store 2-swarm moment (harness/scenarios/store-shots.mjs (b)):
//                   gunner, 12 s into the mission, the squad at the crossing (0, -5), a few
//                   steps, a crowd around it (the store's 600 under the live cap: 350 on «high»),
//                   the player aiming up-left and firing for 1.6 s, then time almost frozen (×0.02)
//                   for the screenshot
//  WP7 «Режиссура» (look-dev, cinematics, device capture):
//    -demo stress1400  the device capture: 1400 live bugs around the squad (-bugs N), «высокая» (High), kept topped up —
//                   `hb gpu` per-pass lines on a device; A/B with -noSwarmDraw / -noStation / -fxSim off / -nocones
//    -demo bugsheet  every bug type × clip around the camera focus (WorldSwarm's sheet; -bugsheet [scale],
//                   -bugsheetGame, -bugsheetT s, -bugstrip <type> [scale] as on `-demo calm`), director off
//    -demo punchin  the squad in beacon «Alpha»'s ring with a crowd; 1.5 s after «scene ready» the beacon comes on →
//                   Cinematics' punch-in (push-in at the game yaw, ×0.3 time for ≈ 0.45 s, 2.4 s); at 4.6 s it plays
//                   again and holds at its peak (0.95 s in) with the world nearly frozen, for the screenshot
//    -demo extract-cine  the hold on the lift with a crowd; at 1.5 s the lift leaves → the extraction shot from the
//                   shaft wall; the lift pinned 2.8 s into its rise for the screenshot
//  Every demo drives Cinematics (mood, shot EV, dilation) until GameScene does; `-cine off` keeps the game camera.
//  native-vx-feel (wave pacing):
//    -demo waves    the game's own swarm, nothing spawned by the demo: the squad in beacon «Beta»'s ring (`-waveBeacon k`
//                   picks another), the defence's opening horde from 3–4 sides, the ring charged to 27 % so the hive's
//                   first push (30 %) lands 2 s later; time almost frozen (×0.02) at `-waveFreeze` s (6.5) after «scene
//                   ready» for the screenshot. Logs `demo waves: td=… alive … near16 … pushes …` once a second.
//  native-vx-swarm-life (a living swarm — the CI bursts burst-pack / burst-mix, A/B with -swarmLegacy):
//    -demo swarmpack  the squad on beacon «Alpha»'s platform (open deck, as `beacon`), a runner pack (60) spread over
//                   the deck 5–11 m around it rushing in, kept topped up from the walkways (11–17 m); the director off,
//                   the player idle, the squad firing (deaths by cause: shots, flames, frost, grenades)
//    -demo swarmmix   the same with a mixed pack (75, every type)
//  feel build A3 (the actions):
//    -demo defeat   a crowd round the squad (200, under the live cap), then the squad goes down one by one from 2.0 s
//                   after «scene ready» (0.6 s apart, the player last, invulnerability off for it): the core loses the
//                   mission, GameScene plays the defeat beat (the deaths, Cinematics' push-in, 2.8 s) and the report
//                   comes up — the CI burst burst-defeat and the screenshot after it
//    No demo shows more live bugs than the game itself can: every forced crowd is clamped to the mission's live cap
//    (`crowd(_:)`; the wave pacing's High 350 / Medium 250 / Low 220 under the device class), the hold demos play the
//    director's own hold. Only the declared renderer stress runs go past it — stress1400 (1400) and an explicit
//    `-bugs N` (CI `swarm` / `swarm3x`: 1400).
// ================================================================
final class DemoScript {
    let name: String
    private var t: Float = 0
    private var topUpT: Float = 0
    private var target = 600
    /// `-bugs N`: swarm size of the combat / beacon demos (renderer stress runs).
    private var override: Int?
    /// Live-bug cap of the mission (set in `begin`): the forced crowds stay under it (`crowd`).
    private var cap = Int.max

    /// A forced crowd of `n` as the game could have it: at most the mission's live cap (the wave pacing's peak), unless
    /// `-bugs N` asks for a renderer stress crowd past it.
    private func crowd(_ n: Int) -> Int { override ?? min(n, cap) }

    private let options: LaunchOptions
    /// Seconds since «scene ready» (the scene sets it before every frame; -1 while loading). Also published as
    /// `sceneClock` for the squad look-dev (feel build A2): its scripted beats then land in the CI bursts' windows, which
    /// count from «scene ready» too (the render clock starts under the loading cover, a few seconds earlier).
    var sinceReady: Double = -1 { didSet { DemoScript.sceneClock = sinceReady } }
    /// The running demo's `sinceReady` (-1 with no demo or while loading).
    private(set) static var sceneClock: Double = -1
    private var queenSet = false, coachStepped = false
    private var defeatStep = 0
    /// `-demo report`: the fixture whose outcome the mission gets.
    let reportFixture: DemoFixtures.Report?

    private init(name: String, options: LaunchOptions, bugs: Int? = nil) {
        self.name = name
        self.options = options
        override = bugs
        reportFixture = name == "report" ? DemoFixtures.report(options.report) : nil
        if name == "report" && reportFixture == nil { AppLog.error("unknown -report \(options.report ?? "?")") }
    }

    static func make(options: LaunchOptions) -> DemoScript? {
        guard let d = options.demo else { return nil }
        switch d {
        case "combat", "smoke", "default": return DemoScript(name: d == "default" ? "combat" : d, options: options, bugs: options.bugs)
        case "beacon": return DemoScript(name: d, options: options, bugs: options.bugs)
        case "title", "calm", "probe", "hold", "holdhint", "extract", "queen", "queenlock", "coach", "pressure", "report", "levelup", "pause", "end",
             "swarmshot", "layout", "bugsheet", "punchin", "extract-cine", "waves", "swarmpack", "swarmmix", "defeat":
            return DemoScript(name: d, options: options)
        case "stress1400": return DemoScript(name: d, options: options, bugs: options.bugs ?? 1400)
        default:
            AppLog.error("unknown demo \(d), using combat")
            return DemoScript(name: "combat", options: options)
        }
    }

    /// Mission tier of the demo unless `-tier` says otherwise: the report fixture's, the first-run rule for the coach
    /// (nil = the scene asks the demo profile), else Ветеран.
    var defaultTier: Int? {
        if let r = reportFixture { return r.tier }
        return name == "coach" ? nil : 1
    }

    var startsMission: Bool { name != "title" }

    /// Class the demo plays unless `-class` says otherwise (the store shot is the gunner's).
    var preferredClass: String? { name == "swarmshot" ? "gunner" : nil }

    /// Graphics tier the demo forces without touching the saved setting (the store shots and the WP7 cinematics are
    /// taken on «высокая»; stress1400 is the plan's High budget run).
    var preferredQuality: String? {
        ["swarmshot", "stress1400", "punchin", "extract-cine"].contains(name) ? "high" : nil
    }

    /// World time scale the scene applies on top of hit-stop: the demo's freeze (swarmshot, coach, the held punch-in:
    /// ×0.02) × the punch-in's time dilation while the demo drives Cinematics.
    var timeScale: Float {
        let c = Cinematics.shared
        return freeze * (c.drivenByScene ? 1 : c.timeScale)
    }
    private var freeze: Float = 1
    private var shotStage = 0
    private var cineStep = 0

    /// Called right after the mission starts.
    func begin(game: Game) {
        cap = game.bugCap
        game.godMode = true
        game.autopilot = true
        game.autoPickUpgrades = true
        Cinematics.shared.reset()
        switch name {
        case "calm", "layout", "bugsheet":
            game.autopilot = false
            game.directorEnabled = false
            target = 0
            AppLog.info("demo \(name): director off, squad idle")
        case "hold", "holdhint", "extract", "queen", "queenlock", "extract-cine":
            var guardN = 0
            while game.stage == .beacons && guardN < 6 { game.debugSkip(); guardN += 1 }
            if game.stage == .toLift { game.debugSkip() }
            // native-vx-feel: the hold's own swarm — the director's opening horde (packs from the ramp and the deck, a
            // third straight over the lift's rim), a horde every 18–24 s; the extraction shot keeps its crowd (gore on the
            // lift as it rises)
            target = name == "extract-cine" ? crowd(260) : 0
            // (extract-cine: on the lift's two flanks as the extraction camera sees them, 4–9 m out — `crowdFlanks`)
            var n = 0
            if target > 0 {
                if let fl = crowdFlanks {
                    n = game.debugSpawn(target / 2, type: nil, minRadius: 4, maxRadius: 9, sector: fl.0)
                        + game.debugSpawn(target - target / 2, type: nil, minRadius: 4, maxRadius: 9, sector: fl.1)
                } else {
                    n = game.debugSpawn(target, type: nil, minRadius: 5, maxRadius: 18)
                }
            }
            AppLog.info("demo \(name): stage \(game.stage.rawValue), spawned \(n) bugs around the lift (bug cap \(game.bugCap))")
        case "coach":
            // a novice who does not touch the screen: every step ends by its timeout
            game.autopilot = false
            target = 0
            // one step before the asked one (-coachStep N, else step 0 → 1): the step change is drawn inside the gate window
            if let k = options.coachStep, k > 0 { game.debugCoachStep(k - 1) }
            AppLog.info("demo coach: coach \(game.coach.active ? "on" : "off") step \(game.coach.step) tier=\(game.difficulty.id)")
        case "pressure":
            game.autopilot = false
            target = 0
            game.fastForward(seconds: 15.5)
            AppLog.info(String(format: "demo pressure: t=%.1f pressure %.1f threat %d tier=", game.time, game.pressure, game.threatState.rawValue)
                        + game.difficulty.id)
        case "report":
            target = crowd(300)
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 24)
            AppLog.info("demo report \(reportFixture?.name ?? "-"): spawned \(n) bugs, tier=\(game.difficulty.id)")
        case "swarmshot":
            game.autopilot = false
            target = 0
            AppLog.info("demo swarmshot: staging the store 2-swarm moment")
        case "swarmpack", "swarmmix":
            game.autopilot = false
            game.directorEnabled = false
            if let b = game.beacons.first { game.debugTeleport(b.x + 3, b.z - 3.5) }
            target = crowd(name == "swarmpack" ? 60 : 75)
            let n = game.debugSpawn(target, type: packType, minRadius: 5, maxRadius: 11)
            AppLog.info("demo \(name): spawned \(n) bugs (\(packType.map { "\($0)" } ?? "mixed")) on beacon Alpha's deck, swarm "
                        + (SwarmAnimator.legacy ? "legacy" : "life"))
        case "defeat":
            target = crowd(200)
            let n = game.debugSpawn(target, type: nil, minRadius: 7, maxRadius: 22)
            AppLog.info("demo defeat: spawned \(n) bugs, the squad goes down from 2.0 s")
        case "levelup", "pause", "end":
            if name == "levelup" { game.autoPickUpgrades = false }
            target = crowd(300)
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 24)
            AppLog.info("demo \(name): spawned \(n) bugs")
        case "stress1400":
            target = override ?? 1400
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 30)
            AppLog.info("demo stress1400: spawned \(n) bugs (target \(target), cap \(game.bugCap)), quality high — device capture: hb gpu per-pass lines")
        case "punchin":
            // inside beacon «Альфа»'s ring (the squad charges it; the demo then completes it)
            if let b = game.beacons.first { game.debugTeleport(b.x + 1.5, b.z - 1.5) }
            target = crowd(300)
            let n = game.debugSpawn(target, type: nil, minRadius: 8, maxRadius: 24)
            AppLog.info("demo punchin: squad in beacon \(game.beacons.first.map { $0.name.logID } ?? "?")'s ring, spawned \(n) bugs")
        case "waves":
            // the wave director's own swarm: the squad in a beacon's ring, its defence starts on the first tick
            let k = max(0, min(game.beacons.count - 1, Int(demoNum("-waveBeacon", 1))))
            if k < game.beacons.count { let b = game.beacons[k]; game.debugTeleport(b.x + 1.5, b.z - 1.5) }
            target = 0
            AppLog.info("demo waves: squad in beacon \(k)'s ring, the director's own swarm (bug cap \(game.bugCap))")
        case "beacon":
            if let b = game.beacons.first {
                game.debugTeleport(b.x + 3, b.z - 3.5)
            }
            target = crowd(350)
            let n = game.debugSpawn(min(target, 600), type: nil, minRadius: 7, maxRadius: 24)
            AppLog.info("demo beacon: squad at beacon \(game.beacons.first.map { $0.name.logID } ?? "?"), spawned \(n) bugs")
        default:
            target = crowd(600)
            let n = game.debugSpawn(min(target, 900), type: nil, minRadius: 6, maxRadius: 26)
            AppLog.info("demo \(name): spawned \(n) bugs around the squad (target \(target), bug cap \(game.bugCap))")
        }
    }

    /// Probe steps due this frame (executed by the scene: HUD / audio / haptics live there).
    enum Probe: String { case overlay, banner, shake, sounds, haptic, horde }
    /// Screen changes the scene performs for a demo (one frame); `layoutSizes`: `-demo layout` checks every screen on
    /// the four landscape phones (LayoutSizes).
    enum Request { case pause, surrender, end, layoutSizes }
    private(set) var request: Request? = nil
    private var requested = false
    private let probeSteps: [Probe] = [.overlay, .banner, .shake, .sounds, .haptic, .horde]
    private var probeIndex = 0
    private(set) var probe: Probe? = nil

    /// Per frame while the mission runs: keep the swarm at `target` (the squad kills ~100 bugs a second, so
    /// replacements arrive twice a second from 12–30 m away and walk in).
    func frame(game: Game, dt: Float) {
        Cinematics.shared.update(game: game, dt: dt, by: .demo)
        if name == "punchin" { punchIn(game) }
        if name == "extract-cine" { extractCine(game) }
        if name == "swarmshot" { swarmShot(game); return }
        if name == "layout" {
            request = nil
            if !requested && sinceReady >= 1 { requested = true; request = .layoutSizes }
            return
        }
        if name == "coach" || name == "pressure" { holdState(game, dt); return }
        if name == "waves" { waves(game, dt); return }
        if !startsMission { return }
        t += dt
        probe = nil
        request = nil
        if !requested && t >= 1.5 && sinceReady >= 2 {
            switch name {
            case "levelup": requested = true; game.debugLevelUp()
            case "pause": requested = true; request = .pause
            case "end": requested = true; request = .surrender
            case "report":
                requested = true
                if let r = reportFixture { DemoFixtures.apply(r, to: game) }
                request = .end
            default: break
            }
        }
        if name == "defeat" {
            // the squad down one by one (the player last): the core ends the mission when the last one is down
            let at: [Double] = [2.0, 2.6, 3.2, 3.8]
            while defeatStep < 4 && sinceReady >= at[defeatStep] {
                game.godMode = false
                let k = 3 - defeatStep
                game.debugHurt(marine: k, hp: 0)
                defeatStep += 1
                AppLog.info("demo defeat: marine \(k) down")
            }
        }
        if (name == "queen" || name == "queenlock") && !queenSet && sinceReady >= 2 {
            queenSet = true
            // (the scene logs «v11 queen spawn …» from her event)
            let uid = game.debugQueen(hp: options.queenHp ?? 1_000_000)
            if uid == 0 { AppLog.info("demo \(name): the Queen did not come (stage \(game.stage.rawValue))") }
        }
        if name == "queenlock" && !lockSet && queenSet && sinceReady >= 3.5 {
            lockSet = true
            game.debugSetLiftTime(0.01)
            AppLog.info("demo queenlock: lift countdown out, queen alive=\(game.queen.alive)")
        }
        // holdhint: the countdown pinned in its first 8 s, so the tier's lift-pulse hint («Контур бьёт каждые 6 с — …»,
        // two lines on a phone) stays up for the screenshot taken after the measured window (mission time ≥ 7 s)
        if name == "holdhint" && game.stage == .hold { game.debugSetLiftTime(LIFT_TIME - 3) }
        if name == "extract" {
            if game.stage == .hold && t >= 6 { game.debugSkip() }
            if game.stage == .extract { game.debugPinExtract(2.0) }
        }
        if name == "probe" && probeIndex < probeSteps.count && t >= Float(4 * (probeIndex + 1)) {
            probe = probeSteps[probeIndex]
            probeIndex += 1
        }
        topUpT -= dt
        if target > 0 && topUpT <= 0 {
            topUpT = 0.5
            let alive = game.bugsAlive
            if alive < target - 10 {
                let k = min(300, target - alive)
                // (extract-cine: the top-ups climb over the lift's rim on either flank in turn, the hold's own entrance)
                flankTurn.toggle()
                let pack = name == "swarmpack" || name == "swarmmix"
                let n = crowdFlanks.map { game.debugClimbLiftRim(k, sector: flankTurn ? $0.0 : $0.1) }
                    ?? game.debugSpawn(k, type: packType, minRadius: pack ? 11 : 12, maxRadius: pack ? 17 : 30)
                spawned += n
            }
            logT -= 0.5
            if logT <= 0 {
                logT = 5
                AppLog.info("demo \(name): alive \(game.bugsAlive), topped up \(spawned) in the last 5 s")
                spawned = 0
            }
        }
    }
    private var spawned = 0
    private var logT: Float = 5
    /// extract-cine: the crowd (on the deck, 4–9 m out) and its top-ups (over the rim, the hold's own entrance) on the
    /// lift's two flanks as seen from the extraction camera (Cinematics: the eye on the shaft wall at MetalCamera.yaw + 20°),
    /// ±50° around the perpendiculars: the squad fires across the frame, lit side-on, as in the shots before the wave pacing.
    /// (native-vx-feel: with the crowd all round, the squad's flashlights swept the eye and the shot dodged them to its
    /// −45° / +12° limit — median 62.8 on 01c636a, clip 1.24 % on c500515's first shot —; with the crowd on the far side the
    /// squad turned its back and lit only the far deck — near-black 40.9 % on 25f5e4a's first shot; 58e10b3 spawned the
    /// top-ups 12–30 m out, off the lift, and they walked round to the ramp on the camera's side.)
    private var crowdFlanks: ((angle: Float, half: Float), (angle: Float, half: Float))? {
        guard name == "extract-cine" else { return nil }
        let yaw = MetalCamera.yaw + Cinematics.extraction.yawOffDeg * .pi / 180
        let toEye = atan2f(cosf(yaw), sinf(yaw)), half: Float = 50 * .pi / 180
        return ((toEye + .pi / 2, half), (toEye - .pi / 2, half))
    }
    private var flankTurn = false
    private var lockSet = false
    /// swarmpack: runners only; swarmmix: every type.
    private var packType: BugType? { name == "swarmpack" ? .runner : nil }

    /// coach: time almost stops after a moment (the step on screen stays for the screenshot, the card's ghost thumb
    /// keeps moving: it runs on wall time); pressure: the hive pressure pinned inside the amber / red band.
    private func holdState(_ game: Game, _ dt: Float) {
        t += dt
        if name == "coach" {
            if !coachStepped && sinceReady >= 1.5 {
                coachStepped = true
                game.debugCoachStep(options.coachStep ?? (game.coach.step + 1))
                AppLog.info(String(format: "demo coach: step %d at td=%.2f", game.coach.step, sinceReady))
            }
            if freeze == 1 && coachStepped && sinceReady >= 2.5 {
                freeze = 0.02
                AppLog.info(String(format: "demo coach: frozen at t=%.1f step %d", game.time, game.coach.step))
            }
        } else {
            let g = game.difficulty.pressureGrace
            game.debugSetPressure(options.pressure == "amber" || sinceReady < 1.5 ? g - 7 : g + 5)
        }
    }

    /// store-shots.mjs (b), one step per frame so the scene drains (renders) the events of each step:
    /// fast(12) → tp(0, -5) → left stick (+50, -20) px for 1.5 s → 1.5 s idle → spawn(600, under the live cap) → right stick (-40, -45) px,
    /// firing, for 1.6 s → time ×0.02 (the web harness renders the shot at timeScale 0.05 for 4 frames).
    private func swarmShot(_ game: Game) {
        let r = Float(InputController.stickRadius)
        let aimDir = Game.worldFromScreen(-40 / (40 * 40 + 45 * 45).squareRoot(), -45 / (40 * 40 + 45 * 45).squareRoot())
        let aim = Game.angle(of: aimDir)
        switch shotStage {
        case 0:
            game.fastForward(seconds: 12)
            game.debugTeleport(0, -5)
            game.setPlayerInput(move: Game.worldFromScreen(50 / r, -20 / r), aim: nil, fire: false, ability: false, dash: false)
            game.fastForward(seconds: 1.5)
            game.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
            game.fastForward(seconds: 1.5)
            shotStage = 1
        case 1:
            let n = game.debugSpawn(crowd(600), type: nil, minRadius: 6, maxRadius: 26)
            game.setPlayerInput(move: Vec2(0, 0), aim: aim, fire: true, ability: false, dash: false, assist: 0.75)
            game.fastForward(seconds: 1.6)
            freeze = 0.02
            shotStage = 2
            AppLog.info("demo swarmshot: spawned \(n), alive \(game.bugsAlive), kills \(game.kills), player at (\(game.player.x), \(game.player.z))")
        default:
            // keep the trigger down (the scene sets the empty touch command before this every frame)
            game.setPlayerInput(move: Vec2(0, 0), aim: aim, fire: true, ability: false, dash: false, assist: 0.75)
        }
    }

    /// `-<key> <number>` among the launch options the parser did not know (demo staging only), else `fallback`.
    private func demoNum(_ key: String, _ fallback: Double) -> Double {
        let u = options.unknown
        guard let i = u.firstIndex(of: key), i + 1 < u.count, let v = Double(u[i + 1]) else { return fallback }
        return v
    }

    /// waves: the defence of the beacon the squad stands in, as the game plays it — charged to 27 % once it starts (the
    /// hive's first push at 30 % lands inside the window), time almost frozen at `-waveFreeze` s for the screenshot.
    private func waves(_ game: Game, _ dt: Float) {
        t += dt
        if !charged && game.activeBeacon >= 0 {
            charged = true
            game.debugBeaconProgress(0.27)
            AppLog.info(String(format: "demo waves: defence of beacon %d, charged to 0.27 td=%.2f alive %d", game.activeBeacon, sinceReady, game.bugsAlive))
        }
        logT -= dt
        if logT <= 0 {
            logT = 1
            let P = game.player
            let near = game.bugsNear(P.x, P.z, 16)
            AppLog.info(String(format: "demo waves: td=%.1f alive %d near16 %d pushes %d stage %d", sinceReady, game.bugsAlive, near,
                               game.beaconPushesFired, game.stage.rawValue))
        }
        if freeze == 1 && sinceReady >= demoNum("-waveFreeze", 6.5) {
            freeze = 0.02
            AppLog.info(String(format: "demo waves: frozen td=%.2f alive %d pushes %d", sinceReady, game.bugsAlive, game.beaconPushesFired))
        }
    }
    private var charged = false

    // ---------------------------------------------------------------- WP7 cinematics
    /// punchin: the beacon comes on 1.5 s after «scene ready» (the punch-in plays out inside the measured window), at
    /// 4.6 s the shot plays again and holds 0.95 s in (past the dilation, at its peak), the world frozen ×0.02 from 5.3 s.
    private func punchIn(_ game: Game) {
        let c = Cinematics.shared
        switch cineStep {
        case 0 where sinceReady >= 1.5:
            cineStep = 1
            if game.stage == .beacons { game.debugSkip() }
            AppLog.info(String(format: "demo punchin: beacon on at td=%.2f (beacons done %d)", sinceReady, game.beaconsDone))
        case 1 where c.kind == .punchIn:
            cineStep = 2
            AppLog.info(String(format: "demo punchin: shot started td=%.2f", sinceReady))
        case 2 where sinceReady >= 4.6:
            cineStep = 3
            c.replayPunchIn()
            AppLog.info(String(format: "demo punchin: replay + hold td=%.2f", sinceReady))
        case 3 where sinceReady >= 5.55:
            cineStep = 4
            c.hold(at: 0.95)
            freeze = 0.02
            AppLog.info(String(format: "demo punchin: held at 0.95 s, world frozen td=%.2f", sinceReady))
        default: break
        }
    }

    /// extract-cine: the lift leaves 1.5 s after «scene ready» (begin() left the stage at hold), runs 2.8 s into its
    /// rise and is pinned there for the screenshot.
    private func extractCine(_ game: Game) {
        switch cineStep {
        case 0 where sinceReady >= 1.5:
            cineStep = 1
            if game.stage == .hold { game.debugSkip() }
            AppLog.info(String(format: "demo extract-cine: lift leaves td=%.2f stage %d", sinceReady, game.stage.rawValue))
        case 1 where game.stage == .extract && game.extractT >= 2.8:
            cineStep = 2
            AppLog.info(String(format: "demo extract-cine: pinned at %.2f s td=%.2f", game.extractT, sinceReady))
        default: break
        }
        if cineStep == 2 { game.debugPinExtract(2.8) }
    }
}
