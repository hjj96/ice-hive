import Foundation
import IceHiveCore

// ================================================================
//  DEMO FIXTURES — the meta store every demo runs on (v1.1 spec §3:
//  profile, tier pick, coach flag and stick seconds in memory only, so
//  CI never depends on, or changes, the simulator's saved profile) and
//  the mission outcomes of `-demo report -report first|win|loss|chip`.
// ================================================================
enum DemoFixtures {
    /// `-profile fresh|returning|veteran` (default fresh); `-tier N` on top acts as the player's pick.
    static func meta(options: LaunchOptions) -> MetaFixture {
        var f: MetaFixture
        if options.demo == "report", let r = report(options.report) {
            f = r.meta
        } else {
            switch options.profile ?? "fresh" {
            case "returning", "veteran": f = .returning
            case "fresh": f = .fresh
            default:
                AppLog.error("unknown -profile \(options.profile ?? "?"), using fresh")
                f = .fresh
            }
            // the title shows the -tier choice as the player's pick (missions take -tier directly)
            if options.demo == "title", let t = options.tier { f.diffPick = t }
        }
        return f
    }

    /// One report fixture: who the player was before the mission and how the mission went (assault).
    struct Report {
        let name: String
        let meta: MetaFixture
        let tier: Int
        let won: Bool
        let time: Float
        let playerKills: Int
        let beacons: Int
        /// The Матка: nil = never came, true = killed, false = still alive at the end.
        let queenKilled: Bool?
        let stage: MissionStage
        let downs: Int
        let downBy: DamageSource
        let pressure: Float?
        let idleMul: Float?
    }

    /// Spec §3 report fixtures (the screen shows what a real run with these numbers would).
    static func report(_ name: String?) -> Report? {
        switch name ?? "win" {
        case "first":
            // a first evacuation on Новобранец: raw 6 089, ×0,8 → 4 871, +487 выслуги (Рядовой → Ефрейтор), medal, promo
            return Report(name: "first", meta: .fresh, tier: 0, won: true, time: 405, playerKills: 1214, beacons: 3, queenKilled: true,
                          stage: .extract, downs: 0, downBy: .environment, pressure: nil, idleMul: nil)
        case "win":
            // Ветеран: 6 228, a record, the Ветеран medal, rank 2 → 3, goal «До звания «Ст. сержант» — 627 выслуги»
            var m = MetaFixture.returning
            var a = m.profile.record(.assault)
            a.xp = 1750; a.best = 6000; a.ev = [1, 0, 0]
            m.profile.cls[.assault] = a
            return Report(name: "win", meta: m, tier: 1, won: true, time: 402, playerKills: 1838, beacons: 3, queenKilled: true,
                          stage: .extract, downs: 1, downBy: .runner, pressure: nil, idleMul: nil)
        case "loss":
            // lost in the hold to the Матка, 62 s longer than the last loss: the queen tip + «Продержались на 1:02 …»
            var m = MetaFixture.returning
            var a = m.profile.record(.assault)
            a.lastT = 190
            m.profile.cls[.assault] = a
            return Report(name: "loss", meta: m, tier: 1, won: false, time: 252, playerKills: 640, beacons: 3, queenKilled: false,
                          stage: .hold, downs: 2, downBy: .queen, pressure: nil, idleMul: nil)
        case "chip":
            // the second early loss on Ветеран while the hive converged: the pressure tip + «Попробуйте «Новобранец»»
            var m = MetaFixture.returning
            var a = m.profile.record(.assault)
            a.lossEarly = 1
            m.profile.cls[.assault] = a
            m.profile.recTip = 0
            return Report(name: "chip", meta: m, tier: 1, won: false, time: 95, playerKills: 212, beacons: 1, queenKilled: nil,
                          stage: .beacons, downs: 1, downBy: .runner, pressure: 40, idleMul: 2)
        default:
            return nil
        }
    }

    /// Force the fixture's outcome onto a running mission and end it (the scene then shows the report).
    static func apply(_ r: Report, to g: Game) {
        g.debugSetRun(time: r.time, playerKills: r.playerKills, beaconsDone: r.beacons, queenKilled: r.queenKilled, stage: r.stage)
        g.debugSetOutcome(downs: r.downs, downBy: r.downBy, pressure: r.pressure, idleMul: r.idleMul)
        g.debugEnd(won: r.won)
    }

    /// The report pre-built behind the loading cover: a first evacuation (strip, breakdown, rank-up, medal, the promo
    /// tip, the goal). `stats` (the mini row) comes from the game on screen (MissionStats has no public initialiser).
    static func warmReport(cls: MarineClass, stats: MissionStats, station: String) -> MissionReport {
        guard let r = report("first") else { fatalError("report fixture") }
        var p = r.meta.profile
        let d = Difficulty.tier(r.tier)
        let run = RunSummary(cls: cls, won: r.won, surrendered: false, time: r.time, playerKills: r.playerKills, beaconsDone: r.beacons,
                             queenSpawned: r.queenKilled != nil, queenDone: r.queenKilled ?? false, downs: r.downs, downBy: r.downBy,
                             tierIndex: d.index, tierMul: d.scoreMul, tierName: d.name, stage: r.stage, pressureLoss: r.pressure != nil,
                             shots: 2000, hits: 1500, accuracy: 75, bestCombo: 48, level: 9, station: station)
        let res = p.commit(run, diffPicked: false)
        return MissionReport.make(run: run, result: res, profile: p, stats: stats, newStationShown: AppFeatures.generatedStations)
    }
}
