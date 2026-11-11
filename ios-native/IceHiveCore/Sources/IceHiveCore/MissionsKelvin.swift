import Foundation

// ================================================================
//  MISSIONS I ON KELVIN-9 (Stage 1 R7; design §1.6 «Breaker Run», «Vent
//  Purge», §1.4) — two missions of operation Cold Light built from R1's
//  modules (Mission.swift) on Kelvin-9 with R6's interactive props laid
//  (Props.swift, `KelvinStation.missions`):
//    BREAKER RUN  DARK: the hive cut the main power, every light circuit
//                 starts dead. SWITCH ×3 — the breakers of the three beacon
//                 decks (each brings its deck's lamps back, an escalation
//                 step) → HOLD the main generator on the plaza for 60 s
//                 while the rest of the station lights up deck by deck →
//                 EXTRACT.
//    VENT PURGE   SWITCH ×4 — seal rings on four of the station's vents
//                 (one on each outer deck, one on the plaza): open, they
//                 pour packs; sealed, they are shut for good and each seal
//                 thins the hive's stream → HOLD the lift for 60 s (its
//                 shock pulse) → EXTRACT.
//  The duct mouths of the design live up on the overhead (packages R4 /
//  R5); until Kelvin-9 has its routes, Vent Purge seals the deck vents the
//  hive already pours out of (the seam: a seal's `vent`, `Game.sealVent`).
//  Each mission has its own calibration preset, gated in CI on the classic
//  bands (`--preset missions`, calib-missions.jsonl): Recruit ≥ 90 % with
//  ≤ 0.5 downs, Veteran 70–85 %, Nightmare ≤ 30 %, the AFK first downs.
// ================================================================

extension KelvinStation {
    /// The station R7's missions play: «Кельвин-9» as the classic mission has it, with its interactive props laid
    /// (`PropLayout.kelvin`: seven light circuits with their breakers, the steam valves, the supply locker).
    public static var missions: KelvinStation {
        var k = KelvinStation()
        k.props = .kelvin
        return k
    }
}

extension MissionTemplate {
    /// R7's missions (the title's mission choice after the classic; `all` and the calibration presets).
    public static var missions: [MissionTemplate] { [breakerRun, ventPurge] }

    /// The classic bands every mission of the game calibrates to (design §3.2: Recruit ≥ 90 % with ≤ 0.5 squad downs,
    /// Veteran 70–85 %, Nightmare ≤ 30 %) and the AFK first downs (Veteran ≤ 120 s, Recruit ≤ 270 s).
    static let missionBands = [CalibBand(tier: 0, winLo: 90, downsHi: 0.5), CalibBand(tier: 1, winLo: 70, winHi: 85), CalibBand(tier: 2, winHi: 30)]
    static let missionAFK = [AFKBand(tier: 1, firstDownMax: 120), AFKBand(tier: 0, firstDownMax: 270)]

    /// The gate preset of a mission: 8 runs per class on Recruit and Nightmare, 16 on Veteran, one AFK run per class on
    /// Veteran and Recruit, seeds from its own base.
    static func missionCalib(_ seedBase: UInt32) -> MissionCalib {
        MissionCalib(tiers: [0, 1, 2], runs: 8, tierRuns: [1: 16], seedBase: seedBase, bands: missionBands, afk: missionAFK, gated: true)
    }

    /// «Breaker Run» (design §1.6): DARK · SWITCH ×3 breakers (each lights a deck) → HOLD at the main generator for 60 s
    /// while the decks light up in stages → EXTRACT. Teaches the light.
    public static let breakerRun = MissionTemplate(id: "breaker-run", name: .missionBreakerRun, station: KelvinStation.missions,
                                                   calib: missionCalib(300_000)) { BreakerRun.plan($0) }

    /// «Vent Purge» (design §1.6): SWITCH ×4 seal rings under fire (each seal thins the spawns) → HOLD → EXTRACT.
    public static let ventPurge = MissionTemplate(id: "vent-purge", name: .missionVentPurge, station: KelvinStation.missions,
                                                  calib: missionCalib(400_000)) { VentPurge.plan($0) }
}

/// Breaker Run's plan on a station with light circuits (Kelvin-9's `PropLayout.kelvin`).
public enum BreakerRun {
    /// Seconds of the generator hold (design: 60 s).
    public static let holdTime: Float = 60
    /// The generator's zone radius (m).
    public static let zoneRadius: Float = 3.5
    /// Seconds in a main breaker's ring after the blackout (R6's breaker ring is 6 s: at 6 s the whole mission took two
    /// minutes and no tier lost one — the breakers are the mission's beats, defended like small beacons).
    public static let breakerTime: Float = 30
    /// The hive's stream on Recruit, Veteran, Nightmare (no Queen here: Nightmare gets its edge from the stream).
    public static let tierStream: [Float] = [1.12, 0.95, 1.18]

    /// The breakers of the circuits that light the station's beacon decks, in beacon order (Kelvin-9: A, B, C).
    public static func breakers(_ lv: Level) -> [SwitchSite] {
        let C = lv.layout.props.circuits
        var out: [SwitchSite] = []
        for b in lv.layout.beacons {
            guard let c = C.first(where: { $0.claims(b.x, b.z) }) else { continue }
            if out.contains(where: { $0.x == c.x && $0.z == c.z }) { continue }
            out.append(SwitchSite(x: c.x, z: c.z, radius: c.radius, time: c.time, kind: .breaker))
        }
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
        // each breaker lights a deck: an escalation step of the director, like a beacon; the hive answers each one and
        // pushes again halfway; the ring drains while nobody holds it
        sw.escalates = true
        sw.alarm = PacingValue(legacy: 120, waves: 30)
        sw.pushes = [0.5]
        sw.pushK = 0.8
        sw.drains = 0.5
        sw.lineText = .objRestorePower
        sw.throwText = .objHoldBreaker
        sw.names = StepNames(approach: "breakers", active: "breaker")
        sw.stripText = .reportStripBreaker
        sw.scoreText = .scoreBreakers
        sw.score = 500
        let g = generator(lv)
        var hold = HoldStep(zone: .circle(x: g.x, z: g.y, r: zoneRadius), time: holdTime)
        hold.relights = true
        hold.callBanner = BannerText(title: .bannerBreakersLive, sub: .bannerBreakersLiveSub)
        hold.holdBanner = BannerText(title: .bannerGenerator, sub: .bannerGeneratorSub)
        hold.approachText = .objToGenerator
        hold.holdText = .objHoldGenerator
        hold.names = StepNames(approach: "toGenerator", active: "generator")
        hold.stripText = .reportStripGenerator
        var ex = ExtractStep()
        ex.stripText = .reportStripExtract
        var plan = MissionPlan(id: "breaker-run", steps: [.switches(sw), .hold(hold), .extract(ex)], modifiers: [.dark],
                               briefing: BannerText(title: .bannerBreakerRun, sub: .bannerBreakerRunSub))
        plan.tierStream = tierStream
        return plan
    }
}

/// Vent Purge's plan: four of the station's vents to seal.
public enum VentPurge {
    /// Seconds of the lift hold.
    public static let holdTime: Float = 75
    /// Seconds in a seal's ring.
    public static let sealTime: Float = 15
    /// The hive's stream on Recruit, Veteran, Nightmare.
    public static let tierStream: [Float] = [1, 1.4, 1.7]
    /// Where Kelvin-9's seals are: the vents on beacon A's deck, beacon B's, beacon C's and the plaza (the station's vent
    /// nearest to each, within 3 m).
    static let kelvinPicks: [Vec2] = [Vec2(-27, 21), Vec2(35, -3), Vec2(-29, -4), Vec2(7, -9)]

    /// The seal rings: one on each picked vent (a 2.2 m ring, 5 s of standing in it).
    public static func seals(_ lv: Level) -> [SwitchSite] {
        let V = lv.layout.vents
        var out: [SwitchSite] = []
        for w in kelvinPicks {
            var best = -1
            var bd: Float = 3
            for (k, v) in V.enumerated() {
                let d = hypotf2(v.x - w.x, v.y - w.y)
                if d < bd { bd = d; best = k }
            }
            if best < 0 || out.contains(where: { $0.vent == best }) { continue }
            out.append(SwitchSite(x: V[best].x, z: V[best].y, radius: 2.2, time: sealTime, kind: .seal, vent: best))
        }
        return out
    }

    public static func plan(_ lv: Level) -> MissionPlan {
        var sw = SwitchStep(sites: seals(lv))
        sw.escalates = true
        sw.alarm = PacingValue(legacy: 96, waves: 24)
        sw.pushes = [0.6]
        sw.pushK = 0.7
        sw.drains = 0.5
        // open vents pour; each seal shuts one for good and thins the stream
        sw.pour = PacingValue(legacy: 32, waves: 8)
        sw.pourGap = 10
        sw.thins = 0.1
        sw.lineText = .objSealVents
        sw.throwText = .objHoldSeal
        sw.doneToast = .toastVentSealed
        sw.names = StepNames(approach: "vents", active: "seal")
        sw.stripText = .reportStripVent
        sw.scoreText = .scoreVents
        sw.score = 375
        var hold = HoldStep(zone: .lift, time: holdTime, pulse: true, boss: nil, releaseWithPlayer: true)
        hold.hordeK = 1.25
        hold.stripText = .reportStripLift
        var ex = ExtractStep()
        ex.stripText = .reportStripExtract
        var plan = MissionPlan(id: "vent-purge", steps: [.switches(sw), .hold(hold), .extract(ex)],
                               briefing: BannerText(title: .bannerVentPurge, sub: .bannerVentPurgeSub))
        plan.tierStream = tierStream
        return plan
    }
}
