import XCTest
import Foundation
@testable import IceHiveCore

/// v1.1 «Ставки» meta: profile load / sanitize (T10), score, ranks, medals (T11), the mission report model (T12),
/// tier selection (T13), the new SettingsStore keys (T15).

func runSummary(_ cls: MarineClass = .assault, won: Bool, surrendered: Bool = false, time: Float, kills: Int, beacons: Int,
                queen: Bool? = nil, downs: Int = 0, downBy: DamageSource = .environment, tier: Int, stage: MissionStage? = nil,
                pressureLoss: Bool = false) -> RunSummary {
    let d = Difficulty.tier(tier)
    return RunSummary(cls: cls, won: won, surrendered: surrendered, time: time, playerKills: kills, beaconsDone: beacons,
                      queenSpawned: queen != nil, queenDone: queen ?? false, downs: downs, downBy: downBy, tierIndex: tier,
                      tierMul: d.scoreMul, tierName: d.name, stage: stage ?? (won ? .extract : .beacons), pressureLoss: pressureLoss,
                      shots: 1000, hits: 640, accuracy: 64, bestCombo: 37, level: 12, station: "Кельвин-9")
}

func missionStats(_ r: RunSummary) -> MissionStats {
    MissionStats(time: r.time, kills: r.playerKills * 2, playerKills: r.playerKills, accuracy: r.accuracy, bestCombo: r.bestCombo, level: r.level,
                 won: r.won, downs: r.downs, downBy: r.downBy, tierIndex: r.tierIndex, beaconsDone: r.beaconsDone, queenSpawned: r.queenSpawned,
                 queenDone: r.queenDone, stage: r.stage)
}

/// The demo «returning / veteran» fixture (spec §3).
func veteranProfile() -> Profile { MetaFixture.returning.profile }

final class ProfileTests: XCTestCase {
    func testLoadAndSanitize() {
        XCTAssertEqual(Profile.load(raw: nil, legacyBest: nil), Profile.fresh())
        XCTAssertEqual(Profile.load(raw: "{bad", legacyBest: nil).runs, 0)
        XCTAssertEqual(Profile.load(raw: "{\"v\":1,\"runs\":\"x\"}", legacyBest: nil).runs, 0)
        XCTAssertEqual(Profile.load(raw: "{\"v\":1,\"runs\":true,\"wins\":2}", legacyBest: nil).runs, 0, "a boolean is not a number")
        XCTAssertEqual(Profile.load(raw: "{\"v\":1,\"runs\":true,\"wins\":2}", legacyBest: nil).wins, 2)
        XCTAssertEqual(Profile.load(raw: "{\"v\":2,\"runs\":5}", legacyBest: nil).runs, 0, "unknown version")
        XCTAssertEqual(Profile.load(raw: "42", legacyBest: nil).runs, 0)
        XCTAssertEqual(Profile.load(raw: "[1,2]", legacyBest: nil).runs, 0)
        let big = "{\"v\":1,\"runs\":7,\"pad\":\"" + String(repeating: "x", count: 50_000) + "\"}"
        XCTAssertEqual(Profile.load(raw: big, legacyBest: nil).runs, 0, "a 50 KB value is not ours")
        let p = Profile.load(raw: "{\"v\":1,\"runs\":3,\"wins\":1,\"cls\":{\"pyro\":{\"xp\":-5,\"ev\":[1,\"y\",0]},\"tank\":{\"xp\":9}}}", legacyBest: nil)
        XCTAssertEqual(p.runs, 3); XCTAssertEqual(p.wins, 1)
        XCTAssertEqual(p.record(.pyro).xp, 0); XCTAssertEqual(p.record(.pyro).ev, [1, 0, 0])
        XCTAssertEqual(p.cls.count, 4, "only the four classes")
        let r = Profile.load(raw: "{\"v\":1,\"runs\":2.6,\"earned\":5e12,\"cls\":{\"cryo\":{\"ev\":\"no\",\"best\":12.4}}}", legacyBest: nil)
        XCTAssertEqual(r.runs, 3, "rounded like the web")
        XCTAssertEqual(r.earned, 1_000_000_000, "clamped to 1e9")
        XCTAssertEqual(r.record(.cryo).ev, [0, 0, 0]); XCTAssertEqual(r.record(.cryo).best, 12)
    }

    func testMigrationFromTheV10Best() {
        // the unknown Capacitor schema → a fresh profile from `best`
        let a = Profile.load(raw: "{\"xp\":1200,\"tier\":3}", legacyBest: (kills: 4321, win: 512))
        XCTAssertEqual(a.runs, 1); XCTAssertEqual(a.wins, 1)
        XCTAssertEqual(effectiveTier(diffPick: nil, profile: a), 1, "an evacuation on v1.0 → Ветеран")
        let b = Profile.load(raw: nil, legacyBest: (kills: 800, win: 0))
        XCTAssertEqual(b.runs, 1); XCTAssertEqual(b.wins, 0)
        XCTAssertEqual(effectiveTier(diffPick: nil, profile: b), 0)
        XCTAssertEqual(Profile.load(raw: nil, legacyBest: (kills: 0, win: 0)).runs, 0)
        // a valid stored profile wins over `best`
        XCTAssertEqual(Profile.load(raw: "{\"v\":1,\"runs\":9}", legacyBest: (kills: 1, win: 1)).runs, 9)
    }

    func testEncodeRoundTripAndSize() {
        var p = veteranProfile()
        let s = p.encoded()
        XCTAssertTrue(s.hasPrefix("{\"v\":1,\"runs\":6,\"wins\":3,\"earned\":23000,\"recTip\":0,\"cls\":{\"assault\":{\"xp\":2300,"))
        XCTAssertEqual(Profile.load(raw: s, legacyBest: nil), p)
        for k in 0..<20 {
            p.commit(runSummary(MarineClass(rawValue: k % 4)!, won: k % 3 == 0, time: Float(200 + k * 7), kills: 1000 + k * 37, beacons: k % 4,
                                queen: k % 3 == 0 ? true : nil, tier: k % 3), diffPicked: false)
        }
        let t = p.encoded()
        XCTAssertLessThanOrEqual(t.utf8.count, 4096)
        XCTAssertEqual(Profile.load(raw: t, legacyBest: nil), p)
    }
}

final class ScoreRankTests: XCTestCase {
    func testScoreParts() {
        let w = RunScore.make(runSummary(won: true, time: 405, kills: 1214, beacons: 3, queen: true, tier: 0))
        XCTAssertEqual(w.parts.map { $0.label }, ["Ваши убийства", "Маяки 3/3", "Матка убита", "Эвакуация", "Скорость · 6:45", "Без падений"])
        XCTAssertEqual(w.parts.map { $0.value }, [1214, 1500, 1000, 1500, 375, 500])
        XCTAssertEqual(w.raw, 6089)
        XCTAssertEqual(w.total, 4871, "×0,8 rounded half up")
        let l = RunScore.make(runSummary(won: false, time: 252, kills: 900, beacons: 3, queen: false, downs: 2, tier: 1))
        XCTAssertEqual(l.parts.map { $0.label }, ["Ваши убийства", "Маяки 3/3"])
        XCTAssertEqual(l.total, 2400)
        let n = RunScore.make(runSummary(won: true, time: 600, kills: 101, beacons: 3, queen: true, downs: 1, tier: 2))
        XCTAssertEqual(n.parts.last?.label, "Скорость · 10:00")
        XCTAssertEqual(n.parts.last?.value, 0, "never negative")
        XCTAssertEqual(n.total, Int((Double(n.raw) * 1.5 + 0.5).rounded(.down)))
        // half-up rounding of ×0,8: 1 + 500 = 501 → 400.8 → 401; 3 → 2.4 → 2
        XCTAssertEqual(RunScore.make(runSummary(won: false, time: 30, kills: 1, beacons: 1, tier: 0)).total, 401)
        XCTAssertEqual(RunScore.make(runSummary(won: false, time: 30, kills: 3, beacons: 0, tier: 0)).total, 2)
    }

    func testRanksAndFormatting() {
        XCTAssertEqual(Ranks.thresholds, [0, 300, 900, 1800, 3000, 4600, 6600, 9200, 12500, 16500])
        XCTAssertEqual(Ranks.names.first, "Рядовой"); XCTAssertEqual(Ranks.names.last, "Майор")
        XCTAssertEqual(Ranks.rankOf(0), 0); XCTAssertEqual(Ranks.rankOf(299), 0); XCTAssertEqual(Ranks.rankOf(300), 1)
        XCTAssertEqual(Ranks.rankOf(2300), 3); XCTAssertEqual(Ranks.rankOf(1_000_000), 9)
        XCTAssertEqual(Ranks.fill(xp: 1050), 0.166_666, accuracy: 1e-4)
        XCTAssertEqual(Ranks.fill(xp: 20_000), 1)
        XCTAssertEqual(MetaText.fmtN(9120), "9\u{00A0}120")
        XCTAssertEqual(MetaText.fmtN(1_234_567), "1\u{00A0}234\u{00A0}567")
        XCTAssertEqual(MetaText.fmtN(999), "999")
        XCTAssertEqual(MetaText.fmtMul(0.8), "×0,8"); XCTAssertEqual(MetaText.fmtMul(1), "×1,0"); XCTAssertEqual(MetaText.fmtMul(1.5), "×1,5")
    }

    func testCommitRules() {
        var p = Profile()
        // first run: a loss at 190 s on Ветеран before beacon 2
        let r1 = p.commit(runSummary(won: false, time: 190.4, kills: 600, beacons: 1, tier: 1), diffPicked: false)
        XCTAssertTrue(r1.first); XCTAssertFalse(r1.record); XCTAssertFalse(r1.medal)
        XCTAssertEqual(r1.xp, Int((Double(r1.score.total) / 10 + 0.5).rounded(.down)))
        var c = p.record(.assault)
        XCTAssertEqual(c.lastT, 190); XCTAssertEqual(c.lossEarly, 1); XCTAssertEqual(c.runs, 1); XCTAssertEqual(c.best, r1.score.total)
        XCTAssertFalse(r1.recTip)
        // second early loss on Ветеран → the one-time chip
        let r2 = p.commit(runSummary(won: false, surrendered: true, time: 80, kills: 100, beacons: 0, tier: 1), diffPicked: false)
        XCTAssertTrue(r2.recTip); XCTAssertEqual(p.recTip, 1)
        XCTAssertFalse(r2.first)
        let r3 = p.commit(runSummary(won: false, time: 70, kills: 100, beacons: 0, tier: 1), diffPicked: false)
        XCTAssertFalse(r3.recTip, "only once")
        XCTAssertEqual(p.record(.assault).lossEarly, 3)
        // a win: medal on its tier, bestWin, lastT 0, lossEarly reset, record
        let r4 = p.commit(runSummary(won: true, time: 402.3, kills: 1838, beacons: 3, queen: true, downs: 1, tier: 1), diffPicked: false)
        c = p.record(.assault)
        XCTAssertTrue(r4.medal); XCTAssertTrue(r4.record); XCTAssertFalse(r4.promo, "promo only on Новобранец")
        XCTAssertEqual(c.ev, [0, 1, 0]); XCTAssertEqual(c.bestWin, 402); XCTAssertEqual(c.lastT, 0); XCTAssertEqual(c.lossEarly, 0)
        XCTAssertEqual(p.wins, 1); XCTAssertEqual(p.runs, 4)
        let r5 = p.commit(runSummary(won: true, time: 420, kills: 10, beacons: 3, queen: true, tier: 1), diffPicked: false)
        XCTAssertFalse(r5.medal, "one medal per class and tier")
        XCTAssertEqual(p.record(.assault).bestWin, 402)
        // promo: the first evacuation ever, on Новобранец, without a tier pick
        var f = Profile()
        XCTAssertTrue(f.commit(runSummary(.pyro, won: true, time: 400, kills: 900, beacons: 3, queen: true, tier: 0), diffPicked: false).promo)
        var g = Profile()
        XCTAssertFalse(g.commit(runSummary(.pyro, won: true, time: 400, kills: 900, beacons: 3, queen: true, tier: 0), diffPicked: true).promo)
        XCTAssertEqual(p.earned, [r1, r2, r3, r4, r5].map { $0.score.total }.reduce(0, +))
    }

    func testLossTipsAndGoals() {
        var p = Profile()
        let res = p.commit(runSummary(won: false, time: 100, kills: 10, beacons: 1, downBy: .spitter, tier: 1, pressureLoss: true), diffPicked: false)
        let run = runSummary(won: false, time: 100, kills: 10, beacons: 1, downBy: .spitter, tier: 1, pressureLoss: true)
        XCTAssertEqual(MetaText.lossTip(run: run, result: res), MetaText.pressTip, "pressure first")
        let plain = runSummary(won: false, time: 100, kills: 10, beacons: 1, downBy: .spitter, tier: 1)
        var q = Profile()
        let rq = q.commit(plain, diffPicked: false)
        XCTAssertEqual(MetaText.lossTip(run: plain, result: rq), "Плевун: уходите из светящихся кругов кислоты")
        for (src, tip) in zip([DamageSource.runner, .brute, .boomer, .queen], [0, 2, 3, 4]) {
            let r = runSummary(won: false, time: 100, kills: 10, beacons: 1, downBy: src, tier: 1)
            var x = Profile()
            XCTAssertEqual(MetaText.lossTip(run: r, result: x.commit(r, diffPicked: false)), MetaText.lossTips[tip])
        }
        let env = runSummary(won: false, time: 100, kills: 10, beacons: 1, downBy: .environment, tier: 1)
        var e = Profile()
        XCTAssertNil(MetaText.lossTip(run: env, result: e.commit(env, diffPicked: false)))
        let sur = runSummary(won: false, surrendered: true, time: 100, kills: 10, beacons: 1, downBy: .queen, tier: 1, pressureLoss: true)
        var s = Profile()
        XCTAssertNil(MetaText.lossTip(run: sur, result: s.commit(sur, diffPicked: false)), "no tip on a surrender")
        // goals
        var g = Profile()
        let rg = g.commit(runSummary(.cryo, won: false, time: 100, kills: 10, beacons: 1, tier: 1), diffPicked: false)
        XCTAssertEqual(MetaText.nextGoal(profile: g, cls: .cryo, result: rg), "Цель: эвакуироваться криотехником (+1\u{00A0}500 очков)")
        var v = veteranProfile()
        var a = v.record(.assault); a.xp = 1750; a.best = 6000; a.ev = [1, 0, 0]; v.cls[.assault] = a
        let rw = v.commit(runSummary(won: true, time: 402, kills: 1838, beacons: 3, queen: true, downs: 1, tier: 1), diffPicked: false)
        XCTAssertEqual(MetaText.nextGoal(profile: v, cls: .assault, result: rw), "До звания «Ст. сержант» — 627 выслуги")
        // the next rank is still > 2 runs away: the medal of the next tier comes first
        var m = veteranProfile()
        var y = m.record(.pyro); y.xp = 3100; m.cls[.pyro] = y
        let rm = m.commit(runSummary(.pyro, won: true, time: 402, kills: 10, beacons: 3, queen: true, tier: 0), diffPicked: false)
        XCTAssertEqual(MetaText.nextGoal(profile: m, cls: .pyro, result: rm), "Нашивка: эвакуируйтесь огнемётчиком на «Ветеране»")
        var near = veteranProfile()
        let rn = near.commit(runSummary(.pyro, won: true, time: 402, kills: 10, beacons: 3, queen: true, tier: 0), diffPicked: false)
        XCTAssertEqual(MetaText.nextGoal(profile: near, cls: .pyro, result: rn), "До звания «Мл. сержант» — 108 выслуги")
        var top = Profile()
        var t = ClassRecord(); t.xp = 20_000; t.wins = 9; t.runs = 9; t.best = 12_345; t.ev = [1, 1, 1]; top.cls[.gunner] = t
        let rt = top.commit(runSummary(.gunner, won: false, time: 100, kills: 10, beacons: 1, tier: 2), diffPicked: false)
        XCTAssertEqual(MetaText.nextGoal(profile: top, cls: .gunner, result: rt), "Побейте свой рекорд: 12\u{00A0}345")
    }

    func testTitleLines() {
        XCTAssertNil(MetaText.titleProfileLine(profile: Profile(), cls: .assault))
        let v = veteranProfile()
        XCTAssertEqual(MetaText.titleProfileLine(profile: v, cls: .assault), "Штурмовик · Сержант · рекорд 9\u{00A0}120")
        XCTAssertEqual(MetaText.titleProfileLine(profile: v, cls: .gunner), "Вылетов: 6 · эвакуаций: 3")
        XCTAssertEqual(MetaText.rankChip(profile: v, cls: .assault), "ЗВ. 4")
        XCTAssertNil(MetaText.rankChip(profile: v, cls: .cryo))
    }
}

final class ReportModelTests: XCTestCase {
    func report(_ p: inout Profile, _ run: RunSummary, picked: Bool = false, newStation: Bool = false) -> MissionReport {
        let res = p.commit(run, diffPicked: picked)
        return MissionReport.make(run: run, result: res, profile: p, stats: missionStats(run), newStationShown: newStation)
    }

    func testFirstEvacuationOnRecruit() {
        var p = Profile()
        let r = report(&p, runSummary(won: true, time: 405, kills: 1214, beacons: 3, queen: true, tier: 0))
        XCTAssertEqual(r.tag, "Отчёт миссии · Кельвин-9")
        XCTAssertEqual(r.title, "Эвакуация успешна")
        XCTAssertEqual(r.subtitle, "Отряд поднялся над бездной. Кельвин-9 остаётся рою — но вы живы.")
        XCTAssertEqual(r.strip.map { $0.label }, ["Маяк", "Маяк", "Маяк", "Лифт", "Матка", "Эвакуация"])
        XCTAssertTrue(r.strip.allSatisfy { $0.on })
        XCTAssertEqual(r.scoreTotal, "4\u{00A0}871")
        XCTAssertNil(r.scoreNote, "first run of the class")
        XCTAssertTrue(r.parts.contains(ReportLine(label: "Маяки 3/3", value: "+1\u{00A0}500")))
        XCTAssertTrue(r.parts.contains(ReportLine(label: "Эвакуация", value: "+1\u{00A0}500")))
        XCTAssertEqual(r.tierLine, "Новобранец · ×0,8 очков")
        XCTAssertEqual(r.tierDelta, "\u{2212}1\u{00A0}218")
        XCTAssertEqual(r.rankTitle, "Штурмовик · Ефрейтор")
        XCTAssertEqual(r.xpLine, "+487 выслуги")
        XCTAssertEqual(r.rankUp, "Новое звание: Ефрейтор")
        XCTAssertEqual(r.medal, "Новая нашивка: Штурмовик · Новобранец")
        XCTAssertEqual(r.tips, [ReportTip(text: MetaText.promo, good: true)])
        XCTAssertNil(r.chip)
        XCTAssertEqual(r.buttons, [.again, .changeClass])
        XCTAssertEqual(r.primary, .again)
        XCTAssertEqual(r.mini.map { $0.label }, ["Время", "Комбо", "Точность", "Уровень"])
        XCTAssertEqual(r.mini.map { $0.value }, ["6:45", "×37", "64%", "12"])
    }

    func testVeteranWinRecordAndRankUp() {
        var p = veteranProfile()
        var a = p.record(.assault); a.xp = 1750; a.best = 6000; a.ev = [1, 0, 0]; p.cls[.assault] = a
        let r = report(&p, runSummary(won: true, time: 402, kills: 1838, beacons: 3, queen: true, downs: 1, tier: 1))
        XCTAssertEqual(r.scoreTotal, "6\u{00A0}228")
        XCTAssertTrue(r.record); XCTAssertEqual(r.scoreNote, "Новый рекорд")
        XCTAssertEqual(r.tierDelta, "")
        XCTAssertEqual(r.rankUp, "Новое звание: Сержант")
        XCTAssertEqual(r.medal, "Новая нашивка: Штурмовик · Ветеран")
        XCTAssertEqual(r.goal, "До звания «Ст. сержант» — 627 выслуги")
        XCTAssertFalse(r.parts.contains { $0.label == "Без падений" })
        // the stations flag: «Новая станция» is the primary button on a win
        var q = veteranProfile()
        let s = report(&q, runSummary(won: true, time: 402, kills: 100, beacons: 3, queen: true, tier: 1), newStation: true)
        XCTAssertEqual(s.buttons, [.again, .newStation, .changeClass]); XCTAssertEqual(s.primary, .newStation)
        XCTAssertEqual(s.scoreNote, "рекорд 9\u{00A0}120")
    }

    func testVeteranQueenLossAndLongerLine() {
        var p = veteranProfile()
        var a = p.record(.assault); a.lastT = 190; p.cls[.assault] = a
        let r = report(&p, runSummary(won: false, time: 252, kills: 700, beacons: 3, queen: false, downBy: .queen, tier: 1, stage: .hold))
        XCTAssertEqual(r.title, "Рой победил")
        XCTAssertEqual(r.subtitle, "Последний фонарь погас. Связь с отрядом потеряна.")
        XCTAssertEqual(r.strip.map { $0.on }, [true, true, true, true, false, false])
        XCTAssertEqual(r.tips, [ReportTip(text: MetaText.lossTips[4], good: false),
                                ReportTip(text: "Продержались на 1:02 дольше прошлой попытки", good: true)])
        // a second, shorter loss: no «дольше»
        let r2 = report(&p, runSummary(won: false, time: 200, kills: 500, beacons: 2, downBy: .runner, tier: 1))
        XCTAssertEqual(r2.tips.map { $0.text }, [MetaText.lossTips[0]])
        // a surrender: own subtitle, no tips
        let s = report(&p, runSummary(won: false, surrendered: true, time: 400, kills: 500, beacons: 2, downBy: .runner, tier: 1))
        XCTAssertEqual(s.subtitle, "Отряд отозван. Маяки погасли один за другим.")
        XCTAssertTrue(s.tips.isEmpty)
    }

    func testEarlyLossChip() {
        var p = veteranProfile()
        var a = p.record(.assault); a.lossEarly = 1; p.cls[.assault] = a
        let r = report(&p, runSummary(won: false, time: 95, kills: 300, beacons: 1, downBy: .runner, tier: 1, pressureLoss: true))
        XCTAssertEqual(r.chip, "Попробуйте «Новобранец»")
        XCTAssertEqual(r.tips.first?.text, MetaText.pressTip)
        XCTAssertEqual(p.recTip, 1)
    }
}

final class TierSelectionTests: XCTestCase {
    func testEffectiveTier() {
        var p = Profile()
        XCTAssertEqual(effectiveTier(diffPick: nil, profile: p), 0, "the first mission ever: Новобранец")
        p.commit(runSummary(won: false, time: 100, kills: 10, beacons: 0, tier: 0), diffPicked: false)
        XCTAssertEqual(effectiveTier(diffPick: nil, profile: p), 0)
        p.commit(runSummary(won: true, time: 400, kills: 10, beacons: 3, queen: true, tier: 0), diffPicked: false)
        XCTAssertEqual(effectiveTier(diffPick: nil, profile: p), 1, "after the first evacuation: Ветеран")
        XCTAssertEqual(effectiveTier(diffPick: 2, profile: p), 2)
        XCTAssertEqual(effectiveTier(diffPick: 0, profile: p), 0)
        XCTAssertEqual(effectiveTier(diffPick: 7, profile: Profile()), 2)
    }
}

final class SettingsStoreV11Tests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "icehive.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testDefaultsAndFirstMission() {
        let s = SettingsStore(defaults: freshDefaults())
        XCTAssertFalse(s.hasBest); XCTAssertEqual(s.profile, Profile())
        XCTAssertNil(s.diffPick); XCTAssertFalse(s.tutSeen); XCTAssertEqual(s.stickSeconds, 0); XCTAssertEqual(s.stationSeed, 0)
        XCTAssertTrue(s.isFirstMission)
        XCTAssertEqual(s.effectiveTier, 0)
    }

    func testNewKeysPersistAndParse() {
        let d = freshDefaults()
        let s = SettingsStore(defaults: d)
        s.setDiff(2); s.setTutSeen(); s.setStickSeconds(9); s.setStationSeed(77)
        var p = Profile(); p.runs = 2; p.wins = 1
        s.saveProfile(p)
        XCTAssertEqual(d.string(forKey: "ledulei.diff"), "2")
        XCTAssertEqual(d.string(forKey: "ledulei.tut"), "1")
        XCTAssertEqual(d.string(forKey: "ledulei.sticks"), "6", "capped at 6")
        XCTAssertEqual(d.string(forKey: "ledulei.seed"), "77")
        let t = SettingsStore(defaults: d)
        XCTAssertEqual(t.diffPick, 2); XCTAssertTrue(t.tutSeen); XCTAssertEqual(t.stickSeconds, 6); XCTAssertEqual(t.stationSeed, 77)
        XCTAssertEqual(t.profile.runs, 2); XCTAssertEqual(t.effectiveTier, 2)
        XCTAssertFalse(t.isFirstMission)
        // the report chip
        t.setDiff(0)
        XCTAssertEqual(SettingsStore(defaults: d).effectiveTier, 0)
    }

    func testCorruptValues() {
        let d = freshDefaults()
        d.set("{bad", forKey: "ledulei.profile")
        d.set("1.5", forKey: "ledulei.diff")
        d.set("\"yes\"", forKey: "ledulei.tut")
        d.set("-4", forKey: "ledulei.sticks")
        d.set("1073741824", forKey: "ledulei.seed")
        var s = SettingsStore(defaults: d)
        XCTAssertEqual(s.profile.runs, 0); XCTAssertNil(s.diffPick); XCTAssertTrue(s.tutSeen, "JS truthiness of a non-empty string")
        XCTAssertEqual(s.stickSeconds, 0); XCTAssertEqual(s.stationSeed, 0)
        XCTAssertEqual(d.string(forKey: "ledulei.profile"), "{bad", "a corrupt value stays until the next commit")
        d.set("true", forKey: "ledulei.diff"); d.set("0", forKey: "ledulei.tut"); d.set("\"\"", forKey: "ledulei.tut")
        s = SettingsStore(defaults: d)
        XCTAssertNil(s.diffPick); XCTAssertFalse(s.tutSeen)
        d.set(Data([1, 2, 3]), forKey: "ledulei.profile")
        d.set(42, forKey: "ledulei.diff")
        s = SettingsStore(defaults: d)
        XCTAssertEqual(s.profile.runs, 0); XCTAssertNil(s.diffPick)
    }

    func testV10BestMigratesToTheProfile() {
        let d = freshDefaults()
        d.set("{\"kills\":4321,\"win\":512}", forKey: "CapacitorStorage.ledulei.best")
        d.set("{\"xp\":1200,\"tier\":3}", forKey: "CapacitorStorage.ledulei.profile")
        let s = SettingsStore(defaults: d)
        XCTAssertTrue(s.hasBest)
        XCTAssertEqual(s.profile.runs, 1); XCTAssertEqual(s.profile.wins, 1)
        XCTAssertEqual(s.effectiveTier, 1)
        XCTAssertFalse(s.isFirstMission)
        XCTAssertEqual(d.string(forKey: "ledulei.profile"), "{\"xp\":1200,\"tier\":3}", "not written until the next commit")
        let k = freshDefaults()
        k.set("{\"kills\":80,\"win\":0}", forKey: "ledulei.best")
        let t = SettingsStore(defaults: k)
        XCTAssertEqual(t.profile.runs, 1); XCTAssertEqual(t.profile.wins, 0); XCTAssertEqual(t.effectiveTier, 0)
    }

    func testVolatileDemoMetaNeverWrites() {
        let d = freshDefaults()
        d.set("{\"v\":1,\"runs\":40,\"wins\":30}", forKey: "ledulei.profile")
        let s = SettingsStore(defaults: d, volatileMeta: .returning)
        XCTAssertEqual(s.profile.runs, 6, "the fixture, not the stored profile")
        XCTAssertEqual(s.effectiveTier, 1)
        s.setDiff(2); s.setTutSeen(); s.setStickSeconds(3); s.setStationSeed(9)
        var p = s.profile; p.runs = 99
        s.saveProfile(p)
        XCTAssertEqual(s.profile.runs, 99); XCTAssertEqual(s.diffPick, 2)
        XCTAssertEqual(d.string(forKey: "ledulei.profile"), "{\"v\":1,\"runs\":40,\"wins\":30}")
        for k in ["diff", "tut", "sticks", "seed"] { XCTAssertNil(d.object(forKey: "ledulei." + k), k) }
        let f = SettingsStore(defaults: freshDefaults(), volatileMeta: .fresh)
        XCTAssertTrue(f.isFirstMission)
    }
}
