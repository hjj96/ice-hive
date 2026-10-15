import Foundation
import IceHiveCore

// ================================================================
//  DEMO SCRIPTS — scripted scenarios for CI screenshots / perf logs:
//    -demo combat   mission (assault unless -class), squad invulnerable, autopilot,
//                   ~600 bugs spawned around the squad and topped up
//    -demo beacon   mission started next to beacon «Альфа» with a crowd
//    -demo title    the title screen (attract mode behind)
//    -demo smoke    alias of combat (the original CI scenario name)
// ================================================================
final class DemoScript {
    let name: String
    private var t: Float = 0
    private var topUpT: Float = 0
    private var target = 600

    private init(name: String) { self.name = name }

    static func make(options: LaunchOptions) -> DemoScript? {
        guard let d = options.demo else { return nil }
        switch d {
        case "combat", "smoke", "default": return DemoScript(name: d == "default" ? "combat" : d)
        case "beacon", "title": return DemoScript(name: d)
        default:
            AppLog.error("unknown demo \(d), using combat")
            return DemoScript(name: "combat")
        }
    }

    var startsMission: Bool { name != "title" }

    /// Called right after the mission starts.
    func begin(game: Game) {
        game.godMode = true
        game.autopilot = true
        game.autoPickUpgrades = true
        switch name {
        case "beacon":
            if let b = game.beacons.first {
                game.debugTeleport(b.x + 3, b.z - 3.5)
            }
            target = 260
            let n = game.debugSpawn(target, type: nil, minRadius: 7, maxRadius: 24)
            AppLog.info("demo beacon: squad at beacon \(game.beacons.first?.name ?? "?"), spawned \(n) bugs")
        default:
            target = 600
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 26)
            AppLog.info("demo \(name): spawned \(n) bugs around the squad")
        }
    }

    /// Per frame while the mission runs: keep the swarm topped up so screenshots stay busy.
    func frame(game: Game, dt: Float) {
        if !startsMission { return }
        t += dt
        topUpT -= dt
        if topUpT <= 0 {
            topUpT = 3
            let alive = game.bugsAlive
            if alive < target * 3 / 4 {
                let n = game.debugSpawn(min(200, target - alive), type: nil, minRadius: 10, maxRadius: 26)
                if n > 0 { AppLog.info("demo \(name): +\(n) bugs (alive \(alive))") }
            }
        }
    }
}
