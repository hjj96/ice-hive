import Foundation

// ================================================================
//  MISSIONS I ON KELVIN-9 (Stage 1 R7; design §1.6 «Breaker Run», «Vent
//  Purge», §1.4) — two missions of operation Cold Light built from R1's
//  modules (Mission.swift) on Kelvin-9 Mk II — the classic mission's
//  station: R5's overhead routes and R6's interactive props laid
//  (`KelvinStation.missions`). At full length since Stage 2 M1 (design
//  §3.4: 6–9 min, beats that ask more — not a slower game):
//    BREAKER RUN  DARK: the hive cut the main power, every light circuit
//                 starts dead. SWITCH ×4 — the breakers of the three beacon
//                 decks and the hub (2 m rings of 55 s, contested by two
//                 bugs inside them; the hive answers each and pushes three
//                 times; each brings its deck's lamps back, an escalation
//                 step) → HOLD the main generator on the plaza for 90 s
//                 while the rest of the station lights up deck by deck →
//                 EXTRACT.
//    VENT PURGE   SWITCH ×4 — seal rings under the overhead's three duct
//                 mouths (over the pad → hub bridge, over the hub → A
//                 walkway, on the plaza gantry) and on beacon A's deck vent:
//                 open, they pour packs (a duct mouth up onto the routes, a
//                 vent onto the deck), the seal being worked too; a duct
//                 mouth is held shut — its weld fills only while the grille
//                 is shot shut, and the hive chews through it in 10 s;
//                 sealed, they are shut for good and each seal thins the
//                 hive's stream → HOLD the lift for 110 s (its shock pulse)
//                 → EXTRACT.
//  A seal is a duct mouth's (`SwitchSite.duct`: R4's `Game.ducts`, shut for
//  good) or a deck vent's (`SwitchSite.vent`, `Game.sealVent`): the duct
//  mouths first, the vents make up the four (on a station without routes,
//  four vents).
//  Each mission has its own calibration preset, gated in CI on the classic
//  bands (`--preset missions`, calib-missions.jsonl): Recruit ≥ 90 % with
//  ≤ 0.5 downs, Veteran 70–85 %, Nightmare ≤ 30 %, the AFK first downs.
// ================================================================

extension KelvinStation {
    /// The station R7's missions play: «Кельвин-9» as the classic mission has it — Mk II since package R5 (`mk2`: the
    /// overhead routes with their duct mouths and perches, and the interactive props — seven light circuits with their
    /// breakers, the steam valves, the supply locker).
    public static var missions: KelvinStation { .mk2 }
}

extension MissionTemplate {
    /// R7's missions (the title's mission choice after the classic; `all` and the calibration presets).
    public static var missions: [MissionTemplate] { [breakerRun, ventPurge] }

    /// The classic bands every mission of the game calibrates to (design §3.2: Recruit ≥ 90 % with ≤ 0.5 squad downs,
    /// Veteran 70–85 %, Nightmare ≤ 30 %) and the AFK first downs (Veteran ≤ 120 s, Recruit ≤ 270 s).
    static let missionBands = [CalibBand(tier: 0, winLo: 90, downsHi: 0.5), CalibBand(tier: 1, winLo: 70, winHi: 85), CalibBand(tier: 2, winHi: 30)]
    static let missionAFK = [AFKBand(tier: 1, firstDownMax: 120), AFKBand(tier: 0, firstDownMax: 270)]

    /// The gate preset of a mission: 8 runs per class on Recruit and Nightmare, 32 on Veteran, one AFK run per class on
    /// Veteran and Recruit, seeds from its own base. (M1: Veteran's rate is the noisy one — R7 saw single runs swing it by
    /// ±8 points — so it gets 128 runs: about ±7 points of 95 % interval against ±10 with 64.)
    static func missionCalib(_ seedBase: UInt32) -> MissionCalib {
        MissionCalib(tiers: [0, 1, 2], runs: 8, tierRuns: [1: 32], seedBase: seedBase, bands: missionBands, afk: missionAFK, gated: true)
    }

    /// «Breaker Run» (design §1.6): DARK · SWITCH ×4 breakers (each lights a deck; design: three — M1 adds the hub's) → HOLD at
    /// the main generator for 90 s (design: 60) while the decks light up in stages → EXTRACT. Teaches the light.
    public static let breakerRun = MissionTemplate(id: "breaker-run", name: .missionBreakerRun, station: KelvinStation.missions,
                                                   calib: missionCalib(300_000)) { BreakerRun.plan($0) }

    /// «Vent Purge» (design §1.6): SWITCH ×4 seal rings under fire (each seal thins the spawns; M1: the seal being worked
    /// pours, a duct mouth must be held shut) → HOLD → EXTRACT. Teaches the overhead.
    public static let ventPurge = MissionTemplate(id: "vent-purge", name: .missionVentPurge, station: KelvinStation.missions,
                                                  calib: missionCalib(400_000)) { VentPurge.plan($0) }
}

/// Breaker Run's plan on a station with light circuits (Kelvin-9's `PropLayout.kelvin`).
public enum BreakerRun {
    /// Seconds of the generator hold (design: 60 s; M1: 90 s in three stages — the dark circuits come back one by one).
    public static let holdTime: Float = 90
    /// The generator's zone radius (m).
    public static let zoneRadius: Float = 3.5
    /// Seconds in a main breaker's ring after the blackout (R6's breaker ring is 6 s: at 6 s the whole mission took two
    /// minutes and no tier lost one — the breakers are the mission's beats, defended like small beacons; R7: 30 s; M1: 55 s,
    /// contested, three pushes — a beat of about a minute).
    public static let breakerTime: Float = 55
    /// M1: bugs inside a breaker's 2 m ring that contest it (it fills at 30 % while they do: «Clear the ring»).
    public static let contestedAt = 2
    /// The hive's stream on Recruit, Veteran, Nightmare (no Queen here; Recruit's lifts its AFK first down — R7). M1: the
    /// rings' bigger fights carry the edge — Nightmare's own tier loses them; the generator hold finishes the rest.
    public static let tierStream: [Float] = [1.12, 0.92, 1.0]
    /// M1: the fourth breaker on Kelvin-9 — the hub's, the junction between the pad, beacon A's catwalk and the stairs down to
    /// the plaza (under the Spine Rack's cable span, by the hub → A duct mouth).
    static let kelvinHub = Vec2(-1, 28)

    /// The breakers of the circuits that light the station's beacon decks, in beacon order (Kelvin-9: A, B, C), then (M1) the
    /// hub's on Kelvin-9.
    public static func breakers(_ lv: Level) -> [SwitchSite] {
        let C = lv.layout.props.circuits
        var out: [SwitchSite] = []
        func add(_ x: Float, _ z: Float) {
            guard let c = C.first(where: { $0.claims(x, z) }) else { return }
            if out.contains(where: { $0.x == c.x && $0.z == c.z }) { return }
            out.append(SwitchSite(x: c.x, z: c.z, radius: c.radius, time: c.time, kind: .breaker))
        }
        for b in lv.layout.beacons { add(b.x, b.z) }
        if lv.layout.name == .kelvin { add(kelvinHub.x, kelvinHub.y) }
        return out
    }

    /// The main generator: on Kelvin-9's plaza (the central deck, between the beacon decks and the head of the stairs down to
    /// the lift) at (−3, −8): every point within 3.8 m of it is open deck (the crates and the plaza breaker stay outside the
    /// zone) and the nearest railing is 4.9 m away — the hold's hordes come over the decks, none climbs straight into the
    /// zone over its rim as at the lift (which has its shock pulse); another station: the first clear disc near there.
    public static func generator(_ lv: Level) -> Vec2 {
        let p = Vec2(-3, -8)
        if lv.layout.name == .kelvin && lv.canStand(p.x, p.y) { return p }
        return lv.openSpot(near: p, from: 0, to: 9, clearance: zoneRadius - 0.4) ?? p
    }

    public static func plan(_ lv: Level) -> MissionPlan {
        var sw = SwitchStep(sites: breakers(lv).map { var s = $0; s.time = breakerTime; return s })
        // each breaker lights a deck: an escalation step of the director, like a beacon; the hive answers each one with a
        // surge from two sides and pushes again at 30 / 60 / 85 % (the last from three sides); two bugs in the 2 m ring slow it
        // to 30 % («Clear the ring»), it drains while nobody holds it
        sw.escalates = true
        sw.alarm = PacingValue(legacy: 180, waves: 45)
        sw.pushes = [0.3, 0.6, 0.85]
        sw.pushK = 1
        sw.drains = 0.5
        sw.contestedAt = contestedAt
        sw.lineText = .objRestorePower
        sw.throwText = .objHoldBreaker
        sw.names = StepNames(approach: "breakers", active: "breaker")
        sw.stripText = .reportStripBreaker
        sw.scoreText = .scoreBreakers
        sw.score = 375
        let g = generator(lv)
        var hold = HoldStep(zone: .circle(x: g.x, z: g.y, r: zoneRadius), time: holdTime)
        hold.relights = true
        // (M1: a 90 s hold on open deck without the lift's pulse — the trickle × 1.5 and the hordes × 0.8 of a lift hold's)
        hold.stageMul = PacingValue(legacy: 2.4, waves: 1.5)
        hold.hordeK = 0.8
        hold.callBanner = BannerText(title: .bannerBreakersLive, sub: .bannerBreakersLiveSub)
        hold.holdBanner = BannerText(title: .bannerGenerator, sub: .bannerGeneratorSub)
        hold.approachText = .objToGenerator
        hold.holdText = .objHoldGenerator
        hold.names = StepNames(approach: "toGenerator", active: "generator")
        hold.stripText = .reportStripGenerator
        hold.outHint = .hintBackToGenerator
        var ex = ExtractStep()
        ex.stripText = .reportStripExtract
        var plan = MissionPlan(id: "breaker-run", steps: [.switches(sw), .hold(hold), .extract(ex)], modifiers: [.dark],
                               briefing: BannerText(title: .bannerBreakerRun, sub: .bannerBreakerRunSub))
        plan.tierStream = tierStream
        return plan
    }
}

/// Vent Purge's plan: four seals — the station's duct mouths, then deck vents.
public enum VentPurge {
    /// Seconds of the lift hold (R7: 75 s; M1: 110 s — the classic's is 100 s with the Queen in it).
    public static let holdTime: Float = 110
    /// Seconds in a seal's ring (R7: 15 s; M1: 50 s — a duct seal's weld fills only while its mouth is shot shut).
    public static let sealTime: Float = 50
    /// M1: a seal's duct mouth shot shut opens again after this many seconds while the step runs (R4's 45 s elsewhere).
    public static let ductShut: Float = 10
    /// M1: the seal being worked pours a pack every this many seconds (± 1 s) while it is open.
    public static let workPourGap: Float = 9
    /// × the lift hold's periodic hordes (R7: 1.8 — its edge; M1: the seals carry it).
    public static let hordeK: Float = 1.3
    /// The hive's stream on Recruit, Veteran, Nightmare. R7's 1 / 1.5 / 1.85 ran into the live and route caps (Veteran's swarm
    /// at the 250 cap in four runs of five); M1 keeps it near 1, under the caps — the edge is the seals' pressure: Nightmare's
    /// own tier loses at the seals.
    public static let tierStream: [Float] = [1, 1.02, 1.0]
    /// Where Kelvin-9's deck seals are, in order after the duct mouths until there are four: the vents on beacon A's deck,
    /// beacon B's, beacon C's and the plaza (the station's vent nearest to each, within 3 m; Mk II takes beacon A's).
    static let kelvinPicks: [Vec2] = [Vec2(-27, 21), Vec2(35, -3), Vec2(-29, -4), Vec2(7, -9)]

    /// The seal rings (2.2 m, `sealTime` s): four. The overhead's duct mouths first (package R4's; Kelvin-9 Mk II has three):
    /// a ring on the open deck nearest under each (within 6 m), the duct shut for good when it is thrown; then the picked
    /// vents, none within 8 m of a ring (Mk II: beacon A's; a station without routes: all four).
    public static func seals(_ lv: Level) -> [SwitchSite] {
        let V = lv.layout.vents
        var out: [SwitchSite] = []
        if let G = lv.overhead {
            for (d, n) in G.ducts.enumerated() where out.count < 4 {
                let p = G.nodePos(n)
                guard let c = lv.openSpot(near: Vec2(p.x, p.z), from: 0, to: 6, clearance: 1.2) else { continue }
                if out.contains(where: { hypotf2($0.x - c.x, $0.z - c.y) < 8 }) { continue }
                out.append(SwitchSite(x: c.x, z: c.y, radius: 2.2, time: sealTime, kind: .seal, duct: d))
            }
        }
        for w in kelvinPicks where out.count < 4 {
            var best = -1
            var bd: Float = 3
            for (k, v) in V.enumerated() {
                let d = hypotf2(v.x - w.x, v.y - w.y)
                if d < bd { bd = d; best = k }
            }
            if best < 0 || out.contains(where: { $0.vent == best || hypotf2($0.x - V[best].x, $0.z - V[best].y) < 8 }) { continue }
            out.append(SwitchSite(x: V[best].x, z: V[best].y, radius: 2.2, time: sealTime, kind: .seal, vent: best))
        }
        return out
    }

    public static func plan(_ lv: Level) -> MissionPlan {
        var sw = SwitchStep(sites: seals(lv))
        sw.escalates = true
        sw.alarm = PacingValue(legacy: 96, waves: 24)
        sw.pushes = [0.35, 0.7]
        sw.pushK = 0.7
        sw.drains = 0.5
        // open vents pour; each seal shuts one for good and thins the stream
        sw.pour = PacingValue(legacy: 32, waves: 8)
        sw.pourGap = 10
        sw.thins = 0.1
        // M1: the seal being worked pours too; a duct mouth must be held shut — shot shut, it opens again after `ductShut` s,
        // and its weld fills only while it is shut
        sw.workPourGap = workPourGap
        sw.ductShut = ductShut
        sw.weldShut = true
        sw.shutText = .objShutDuct
        sw.lineText = .objSealVents
        sw.throwText = .objHoldSeal
        sw.doneToast = .toastVentSealed
        sw.names = StepNames(approach: "vents", active: "seal")
        sw.stripText = .reportStripVent
        sw.scoreText = .scoreVents
        sw.score = 375
        var hold = HoldStep(zone: .lift, time: holdTime, pulse: true, boss: nil, releaseWithPlayer: true)
        hold.hordeK = hordeK
        hold.stripText = .reportStripLift
        var ex = ExtractStep()
        ex.stripText = .reportStripExtract
        var plan = MissionPlan(id: "vent-purge", steps: [.switches(sw), .hold(hold), .extract(ex)],
                               briefing: BannerText(title: .bannerVentPurge, sub: .bannerVentPurgeSub))
        plan.tierStream = tierStream
        return plan
    }
}
