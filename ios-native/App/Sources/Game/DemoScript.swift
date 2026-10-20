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
//    -demo smoke    alias of combat (the original CI scenario name)
//    -demo probe    combat, plus one horde ingredient every 4 s (overlay, banner, shake, sounds,
//                   haptic, then a real horde) — CI hitch attribution
//    -demo hold     beacons skipped, the squad on the lift holding out against a crowd
//    -demo extract  like hold, then the lift rises and stays at extract + 2 s (gore rides along)
//    -demo queen    like hold, and the Матка (v1.1 boss of the hold) climbs up at once (1 000 000 HP unless
//                   -queenHp, so she stays on the deck for the screenshot)
//    -demo queenlock  queen, then the lift countdown runs out after 3 s: «Лифт заблокирован — Матка жива»
//    -demo coach    the first mission ever on the fresh demo profile: «Учебная высадка» runs (autopilot off, so the
//                   steps advance by their timeouts; -coachStep N jumps), time almost stopped after a moment so the
//                   screenshot shows that step
//    -demo pressure Ветеран, nobody touches the screen: fast-forward to 15.5 s (-pressure amber) / 26 s (red), the
//                   hive pressure then pinned in that state
//    -demo report   the mission report of a fixture (-report first|win|loss|chip): the run's outcome is forced and
//                   committed into the demo's in-memory profile after 1.5 s
//    -demo levelup  a forced level-up after 1.5 s: the upgrade cards
//    -demo pause    the pause menu after 1.5 s
//    -demo end      surrender after 1.5 s: the mission report (record highlight on)
//    -demo swarmshot  the App Store 2-swarm moment (harness/scenarios/store-shots.mjs (b)):
//                   gunner, 12 s into the mission, the squad at the crossing (0, -5), a few
//                   steps, 600 bugs around it, the player aiming up-left and firing for 1.6 s,
//                   then time almost frozen (×0.02) for the screenshot — the renderer A/B
//                   against store/screenshots/6.3/2-swarm.png
// ================================================================
final class DemoScript {
    let name: String
    private var t: Float = 0
    private var topUpT: Float = 0
    private var target = 600
    /// `-bugs N`: swarm size of the combat / beacon demos (renderer stress runs).
    private var override: Int?

    private let options: LaunchOptions
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
             "swarmshot":
            return DemoScript(name: d, options: options)
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

    /// Graphics tier the demo forces without touching the saved setting (the store shots are taken on «высокая»).
    var preferredQuality: String? { name == "swarmshot" ? "high" : nil }

    /// World time scale the scene applies on top of hit-stop (swarmshot: ~frozen after the staging).
    private(set) var timeScale: Float = 1
    private var shotStage = 0

    /// Called right after the mission starts.
    func begin(game: Game) {
        game.godMode = true
        game.autopilot = true
        game.autoPickUpgrades = true
        switch name {
        case "calm":
            game.autopilot = false
            game.directorEnabled = false
            target = 0
            AppLog.info("demo calm: director off, squad idle")
        case "hold", "holdhint", "extract", "queen", "queenlock":
            var guardN = 0
            while game.stage == .beacons && guardN < 6 { game.debugSkip(); guardN += 1 }
            if game.stage == .toLift { game.debugSkip() }
            target = 260
            let n = game.debugSpawn(target, type: nil, minRadius: 5, maxRadius: 18)
            AppLog.info("demo \(name): stage \(game.stage.rawValue), spawned \(n) bugs around the lift")
            if name == "queen" || name == "queenlock" {
                // (the scene logs «v11 queen spawn …» from her event)
                let uid = game.debugQueen(hp: options.queenHp ?? 1_000_000)
                if uid == 0 { AppLog.info("demo \(name): the Матка did not come (stage \(game.stage.rawValue))") }
            }
        case "coach":
            // a novice who does not touch the screen: every step ends by its timeout
            game.autopilot = false
            target = 0
            if let k = options.coachStep { game.debugCoachStep(k) }
            AppLog.info("demo coach: coach \(game.coach.active ? "on" : "off") step \(game.coach.step) tier=\(game.difficulty.id)")
        case "pressure":
            game.autopilot = false
            target = 0
            let red = options.pressure != "amber"
            game.fastForward(seconds: red ? 26 : 15.5)
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
    /// Screen changes the scene performs for a demo (one frame).
    enum Request { case pause, surrender, end }
    private(set) var request: Request? = nil
    private var requested = false
    private let probeSteps: [Probe] = [.overlay, .banner, .shake, .sounds, .haptic, .horde]
    private var probeIndex = 0
    private(set) var probe: Probe? = nil

    /// Per frame while the mission runs: keep the swarm at `target` (the squad kills ~100 bugs a second, so
    /// replacements arrive twice a second from 12–30 m away and walk in).
    func frame(game: Game, dt: Float) {
        if name == "swarmshot" { swarmShot(game); return }
        if name == "coach" || name == "pressure" { holdState(game, dt); return }
        if !startsMission || target == 0 { return }
        t += dt
        probe = nil
        request = nil
        if !requested && t >= 1.5 {
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
        if name == "queenlock" && !lockSet && t >= 3 {
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
            if timeScale == 1 && t >= (options.coachStep != nil ? 1.2 : 2.5) {
                timeScale = 0.02
                AppLog.info(String(format: "demo coach: frozen at t=%.1f step %d", game.time, game.coach.step))
            }
        } else {
            let g = game.difficulty.pressureGrace
            game.debugSetPressure(options.pressure == "amber" ? g - 7 : g + 5)
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
            timeScale = 0.02
            shotStage = 2
            AppLog.info("demo swarmshot: spawned \(n), alive \(game.bugsAlive), kills \(game.kills), player at (\(game.player.x), \(game.player.z))")
        default:
            // keep the trigger down (the scene sets the empty touch command before this every frame)
            game.setPlayerInput(move: Vec2(0, 0), aim: aim, fire: true, ability: false, dash: false, assist: 0.75)
        }
    }
}
