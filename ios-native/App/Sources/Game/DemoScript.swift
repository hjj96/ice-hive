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

    private init(name: String, bugs: Int? = nil) { self.name = name; override = bugs }

    static func make(options: LaunchOptions) -> DemoScript? {
        guard let d = options.demo else { return nil }
        switch d {
        case "combat", "smoke", "default": return DemoScript(name: d == "default" ? "combat" : d, bugs: options.bugs)
        case "beacon": return DemoScript(name: d, bugs: options.bugs)
        case "title", "calm", "probe", "hold", "extract", "levelup", "pause", "end", "swarmshot": return DemoScript(name: d)
        default:
            AppLog.error("unknown demo \(d), using combat")
            return DemoScript(name: "combat")
        }
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
        case "hold", "extract":
            var guardN = 0
            while game.stage == .beacons && guardN < 6 { game.debugSkip(); guardN += 1 }
            if game.stage == .toLift { game.debugSkip() }
            target = 260
            let n = game.debugSpawn(target, type: nil, minRadius: 5, maxRadius: 18)
            AppLog.info("demo \(name): stage \(game.stage.rawValue), spawned \(n) bugs around the lift")
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
    enum Request { case pause, surrender }
    private(set) var request: Request? = nil
    private var requested = false
    private let probeSteps: [Probe] = [.overlay, .banner, .shake, .sounds, .haptic, .horde]
    private var probeIndex = 0
    private(set) var probe: Probe? = nil

    /// Per frame while the mission runs: keep the swarm at `target` (the squad kills ~100 bugs a second, so
    /// replacements arrive twice a second from 12–30 m away and walk in).
    func frame(game: Game, dt: Float) {
        if name == "swarmshot" { swarmShot(game); return }
        if !startsMission || target == 0 { return }
        t += dt
        probe = nil
        request = nil
        if !requested && t >= 1.5 {
            switch name {
            case "levelup": requested = true; game.debugLevelUp()
            case "pause": requested = true; request = .pause
            case "end": requested = true; request = .surrender
            default: break
            }
        }
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
