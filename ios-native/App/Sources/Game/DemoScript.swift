import Foundation
import IceHiveCore

// ================================================================
//  DEMO SCRIPTS — scripted scenarios for CI screenshots / perf logs:
//    -demo combat   mission (assault unless -class), squad invulnerable, autopilot,
//                   600 bugs spawned around the squad and kept at ~600 alive (like the
//                   web harness swarm screenshots)
//    -demo beacon   mission started next to beacon «Альфа» with a crowd
//    -demo title    the title screen (attract mode behind)
//    -demo calm     mission start with the director off: no bugs, the squad idles on the
//                   landing pad (lighting / station look)
//    -demo layout   like calm; 1 s after «scene ready» every screen is laid out and checked on the four
//                   landscape phones (LayoutSizes: «layout ok|FAIL …», «layout sizes: N ok, M FAIL»)
//    -demo smoke    alias of combat (the original CI scenario name)
//    -demo probe    combat, plus one horde ingredient every 4 s (overlay, banner, shake, sounds,
//                   haptic, then a real horde) — CI hitch attribution
//    -demo hold     beacons skipped, the squad on the lift holding out against a crowd
//    -demo extract  like hold, then the lift rises and stays at extract + 2 s (gore rides along)
//    -demo queen    like hold, and the Матка (v1.1 boss of the hold) climbs up 2 s after «scene ready» (1 000 000 HP
//                   unless -queenHp, so she stays on the deck for the screenshot)
//    -demo queenlock  queen, then the lift countdown runs out 1.5 s later: «Лифт заблокирован — Матка жива»
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
//                   steps, 600 bugs around it, the player aiming up-left and firing for 1.6 s,
//                   then time almost frozen (×0.02) for the screenshot — the renderer A/B
//                   against store/screenshots/6.3/2-swarm.png
//  WP7 «Режиссура» (look-dev, cinematics, device capture):
//    -demo stress1400  the device capture: 1400 live bugs around the squad (-bugs N), «высокая» (High), kept topped up —
//                   `hb gpu` per-pass lines on a device; A/B with -noSwarmDraw / -noStation / -fxSim off / -nocones
//    -demo bugsheet  every bug type × clip around the camera focus (WorldSwarm's sheet; -bugsheet [scale],
//                   -bugsheetGame, -bugsheetT s, -bugstrip <type> [scale] as on `-demo calm`), director off
//    -demo punchin  the squad in beacon «Альфа»'s ring with a crowd; 1.5 s after «scene ready» the beacon comes on →
//                   Cinematics' punch-in (push-in at the game yaw, ×0.3 time for ≈ 0.45 s, 2.4 s); at 4.6 s it plays
//                   again and holds at its peak (0.95 s in) with the world nearly frozen, for the screenshot
//    -demo extract-cine  the hold on the lift with a crowd; at 1.5 s the lift leaves → the extraction shot from the
//                   shaft wall; the lift pinned 2.8 s into its rise for the screenshot
//  Every demo drives Cinematics (mood, shot EV, dilation) until GameScene does; `-cine off` keeps the game camera.
//  `-video` (test branch native-vx-video, FilmCapture): the demos play out for a gameplay film instead of stopping for
//  a screenshot, every one on «высокая»: punchin — the beacon comes on at `-punchAt` s (9) and the shot plays once;
//  extract-cine — the lift leaves at `-liftAt` s (1.5) and rises to the end; queen — the finale: the Матка climbs up
//  at `-queenAt` s (7) with `-queenHp` (1100), dies by the squad's guns (or at `-queenKillBy` s (9) after she came),
//  and the lift leaves `-liftDelay` s (2.5) after her death; combat / stress1400 with `-videoAt k`: the squad starts at
//  beacon k (0 Альфа, 1 Бета, 2 Гамма) instead of the landing pad.
// ================================================================
final class DemoScript {
    let name: String
    private var t: Float = 0
    private var topUpT: Float = 0
    private var target = 600
    /// `-bugs N`: swarm size of the combat / beacon demos (renderer stress runs).
    private var override: Int?

    private let options: LaunchOptions
    /// Seconds since «scene ready» (the scene sets it before every frame; -1 while loading).
    var sinceReady: Double = -1
    private var queenSet = false, coachStepped = false
    /// `-demo report`: the fixture whose outcome the mission gets.
    let reportFixture: DemoFixtures.Report?

    /// `-video`: the film timings (see the header).
    private let video: Bool
    private let punchAt: Double, liftAt: Double, queenAt: Double, queenKillBy: Double, liftDelay: Double
    private let videoAt: Int

    private init(name: String, options: LaunchOptions, bugs: Int? = nil) {
        self.name = name
        self.options = options
        override = bugs
        let u = options.unknown
        func num(_ k: String, _ d: Double) -> Double {
            guard let i = u.firstIndex(of: k), i + 1 < u.count, let v = Double(u[i + 1]) else { return d }
            return v
        }
        video = u.contains("-video")
        punchAt = num("-punchAt", 9)
        liftAt = num("-liftAt", 1.5)
        queenAt = num("-queenAt", 7)
        queenKillBy = num("-queenKillBy", 9)
        liftDelay = num("-liftDelay", 2.5)
        videoAt = Int(num("-videoAt", -1))
        reportFixture = name == "report" ? DemoFixtures.report(options.report) : nil
        if name == "report" && reportFixture == nil { AppLog.error("unknown -report \(options.report ?? "?")") }
    }

    static func make(options: LaunchOptions) -> DemoScript? {
        guard let d = options.demo else { return nil }
        switch d {
        case "combat", "smoke", "default": return DemoScript(name: d == "default" ? "combat" : d, options: options, bugs: options.bugs)
        case "beacon": return DemoScript(name: d, options: options, bugs: options.bugs)
        case "title", "calm", "probe", "hold", "holdhint", "extract", "queen", "queenlock", "coach", "pressure", "report", "levelup", "pause", "end",
             "swarmshot", "layout", "bugsheet", "punchin", "extract-cine":
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
        video || ["swarmshot", "stress1400", "punchin", "extract-cine"].contains(name) ? "high" : nil
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
        game.godMode = true
        game.autopilot = true
        game.autoPickUpgrades = true
        Cinematics.shared.reset()
        if video && (name == "combat" || name == "stress1400") && videoAt >= 0 && videoAt < game.beacons.count {
            let b = game.beacons[videoAt]
            game.debugTeleport(b.x + 3, b.z - 3.5)
            AppLog.info("demo \(name) (video): squad at beacon \(b.name)")
        }
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
            target = 260
            let n = game.debugSpawn(target, type: nil, minRadius: 5, maxRadius: 18)
            AppLog.info("demo \(name): stage \(game.stage.rawValue), spawned \(n) bugs around the lift")
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
            target = 300
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 24)
            AppLog.info("demo report \(reportFixture?.name ?? "-"): spawned \(n) bugs, tier=\(game.difficulty.id)")
        case "swarmshot":
            game.autopilot = false
            target = 0
            AppLog.info("demo swarmshot: staging the store 2-swarm moment")
        case "levelup", "pause", "end":
            if name == "levelup" { game.autoPickUpgrades = false }
            target = 300
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 24)
            AppLog.info("demo \(name): spawned \(n) bugs")
        case "stress1400":
            target = override ?? 1400
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 30)
            AppLog.info("demo stress1400: spawned \(n) bugs (target \(target), cap \(game.bugCap)), quality high — device capture: hb gpu per-pass lines")
        case "punchin":
            // inside beacon «Альфа»'s ring (the squad charges it; the demo then completes it)
            if let b = game.beacons.first { game.debugTeleport(b.x + 1.5, b.z - 1.5) }
            target = 300
            let n = game.debugSpawn(target, type: nil, minRadius: 8, maxRadius: 24)
            AppLog.info("demo punchin: squad in beacon \(game.beacons.first?.name ?? "?")'s ring, spawned \(n) bugs")
        case "beacon":
            if let b = game.beacons.first {
                game.debugTeleport(b.x + 3, b.z - 3.5)
            }
            target = override ?? 350
            let n = game.debugSpawn(min(target, 600), type: nil, minRadius: 7, maxRadius: 24)
            AppLog.info("demo beacon: squad at beacon \(game.beacons.first?.name ?? "?"), spawned \(n) bugs")
        default:
            target = override ?? 600
            let n = game.debugSpawn(min(target, 900), type: nil, minRadius: 6, maxRadius: 26)
            AppLog.info("demo \(name): spawned \(n) bugs around the squad")
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
        if !startsMission || target == 0 { return }
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
        if (name == "queen" || name == "queenlock") && !queenSet && sinceReady >= (video ? queenAt : 2) {
            queenSet = true
            // (the scene logs «v11 queen spawn …» from her event)
            let uid = game.debugQueen(hp: options.queenHp ?? (video ? 1100 : 1_000_000))
            if uid == 0 { AppLog.info("demo \(name): the Матка did not come (stage \(game.stage.rawValue))") }
            if video { AppLog.info(String(format: "demo queen (video): the Матка climbs up td=%.2f uid=%d", sinceReady, Int(uid))) }
        }
        if video && name == "queen" && queenSet { finale(game) }
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
        if topUpT <= 0 {
            topUpT = 0.5
            let alive = game.bugsAlive
            if alive < target - 10 {
                let n = game.debugSpawn(min(300, target - alive), type: nil, minRadius: 12, maxRadius: 30)
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
    private var lockSet = false

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
    /// fast(12) → tp(0, -5) → left stick (+50, -20) px for 1.5 s → 1.5 s idle → spawn(600) → right stick (-40, -45) px,
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
            let n = game.debugSpawn(600, type: nil, minRadius: 6, maxRadius: 26)
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

    // ---------------------------------------------------------------- WP7 cinematics
    /// punchin: the beacon comes on 1.5 s after «scene ready» (the punch-in plays out inside the measured window), at
    /// 4.6 s the shot plays again and holds 0.95 s in (past the dilation, at its peak), the world frozen ×0.02 from 5.3 s.
    private func punchIn(_ game: Game) {
        let c = Cinematics.shared
        switch cineStep {
        case 0 where sinceReady >= (video ? punchAt : 1.5):
            cineStep = 1
            if game.stage == .beacons { game.debugSkip() }
            AppLog.info(String(format: "demo punchin: beacon on at td=%.2f (beacons done %d)", sinceReady, game.beaconsDone))
        case 1 where c.kind == .punchIn:
            cineStep = 2
            AppLog.info(String(format: "demo punchin: shot started td=%.2f", sinceReady))
        case 2 where sinceReady >= 4.6 && !video:
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
        case 0 where sinceReady >= (video ? liftAt : 1.5):
            cineStep = 1
            if game.stage == .hold { game.debugSkip() }
            AppLog.info(String(format: "demo extract-cine: lift leaves td=%.2f stage %d", sinceReady, game.stage.rawValue))
        case 1 where game.stage == .extract && game.extractT >= 2.8:
            cineStep = 2
            AppLog.info(String(format: "demo extract-cine: pinned at %.2f s td=%.2f", game.extractT, sinceReady))
        default: break
        }
        if cineStep == 2 && !video { game.debugPinExtract(2.8) }
    }

    /// `-video` queen: once the Матка is dead (shot down, or killed at queenAt + queenKillBy), the lift leaves
    /// `liftDelay` s later (the squad stands on it: the extraction shot follows, then the mission is won).
    private var queenDeadAt: Double = -1
    private var liftSent = false
    private func finale(_ game: Game) {
        if queenDeadAt < 0 {
            if game.queen.spawned && !game.queen.alive {
                queenDeadAt = sinceReady
                AppLog.info(String(format: "demo queen (video): the Матка died td=%.2f (lived %.1f s)", sinceReady, game.queen.killT))
            } else if game.queen.alive && sinceReady >= queenAt + queenKillBy {
                game.debugKillQueen()
                queenDeadAt = sinceReady
                AppLog.info(String(format: "demo queen (video): the Матка killed by the script td=%.2f", sinceReady))
            } else if !game.queen.spawned && sinceReady >= queenAt + 1 {
                queenDeadAt = sinceReady
                AppLog.info("demo queen (video): no Матка (stage \(game.stage.rawValue)), the lift goes anyway")
            }
        } else if !liftSent && sinceReady >= queenDeadAt + liftDelay {
            liftSent = true
            game.debugSetLiftTime(0.01)
            AppLog.info(String(format: "demo queen (video): the lift leaves td=%.2f stage %d", sinceReady, game.stage.rawValue))
        }
    }
}
