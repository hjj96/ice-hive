import Foundation

// ================================================================
//  THE QUEEN (Матка) — the boss of the lift hold (v1.1 «Ставки», web
//  08b-threat.js queenEdge / queenWarn / queenSpawn / queenTick /
//  queenKilled / queenSkip), on the boss framework since Stage 2 B1
//  (Boss.swift, GameBoss.swift). She is a BUG BODY: a brute instance scaled
//  up (radius 1.5, scale 4.2) — the renderer draws her with the brute mesh,
//  the brute AI does her walk, her bite (×1.6 on her own clock) and her ram
//  (on her own clock). Her rows (Difficulty.queen, Tuning.swift) are built
//  here; everything she does is the framework's generic machinery:
//    warning   2 s of red ring at a rim edge on the far side of her arena
//              (the step's zone; the classic hold: the lift), then she
//              climbs 3 m up over it
//    moves     brood (runners burst from her body), acid volley (a glob at
//              every standing marine within 18 m, aimed 0.8 s ahead ± 1.2 m,
//              a ring + fill each), ram (the brute's red lane and charge,
//              only on her clock)
//    phases    below half health she enrages once: ×1.35 speed, the brood
//              ×0.7 and the volley / ram ×0.75 apart, and the hive answers
//              with a horde («QUEEN ENRAGED»)
//    immune    never freezes, chill ≤ 0.5, the lift's pulse passes her by
//    hooks     the hold cannot end while she lives (BossRider.locks), its
//              hordes pause, the trickle thins (× 0.4 / 0.4 / 0.6)
//    death     a blast (8 m, 300, the player's kills), two medkits, +60 XP
//  The classic mission replays bit for bit on the framework (calib.jsonl
//  byte-identical): every number, random draw and event comes in the old
//  order.
// ================================================================
extension BossSpec {

    /// The Queen on one tier (web TH.q*): her warning comes `at` s into the counted hold (∞: never), `hp` × the director's HP
    /// multiplier at her spawn, `speed`; a ram every `ramT` s, a volley every `volleyT` s, a brood of `broodN` runners every
    /// `broodT` s (enraged: ×0.75, ×0.75, ×0.7); the horde of her rage; × `trickle` on the hold's stream while she lives.
    public static func queen(at: Float, hp: Float, speed: Float, ramT: Float, volleyT: Float, broodT: Float, broodN: Int,
                             horde: Float, trickle: Float) -> BossSpec {
        var brood = BossMove("brood", .brood, first: 4, cooldown: broodT)
        brood.count = broodN; brood.addType = .runner; brood.exclusive = false
        var volley = BossMove("volley", .volley, first: 3, cooldown: volleyT)
        volley.range = 18; volley.lead = 0.8; volley.spread = 1.2; volley.exclusive = false
        var ram = BossMove("ram", .bodyCharge, first: 6, cooldown: ramT)
        ram.exclusive = false
        // (the enraged cooldowns by move: brood, volley, ram)
        var rage = BossPhase(below: 0.5)
        rage.enraged = true; rage.speedK = 1.35; rage.cooldownK = [0.7, 0.75, 0.75]
        // (the web passes '' as the rage horde's subtitle, which falls back to the horde line: no title of her own there)
        rage.horde = horde; rage.hordeWavesK = 0.5; rage.hordeRate = 50; rage.hordeTitle = .bannerQueenRage
        var s = BossSpec(at: at, hp: hp, speed: speed, body: .bug(type: .brute, radius: 1.5, scale: 4.2),
                         spawn: .rim(depth: 3, margin: 1.5, backZ: -4), phases: [BossPhase(below: 1), rage], moves: [brood, volley, ram],
                         source: .queen)
        s.warn = 2; s.warnRing = 3
        s.immune.freeze = true; s.immune.chillCap = 0.5; s.immune.pulse = true
        s.bite = 1.6
        s.trickle = trickle; s.pausesHordes = true
        s.deathBlast = BossBlast(r: 8, dmg: 300, src: 0, kind: .frag)
        s.reward = BossReward(xp: 60, medkits: [Vec2(1, 0), Vec2(-1, 0)])
        s.banner = BannerText(title: .bannerQueen, sub: .bannerQueenSub)
        s.deathBanner = BannerText(title: .bannerQueenDead, sub: .bannerQueenDeadSub)
        s.roar = .queen; s.arrivalShake = 0.4
        return s
    }

    /// No Queen on this tier (the hidden legacy v1.0 row): her structure, every number 0, she never comes.
    public static let queenNone = BossSpec.queen(at: .infinity, hp: 0, speed: 0, ramT: 0, volleyT: 0, broodT: 0, broodN: 0, horde: 0, trickle: 1)

    // ---- her numbers by their v1.1 names (tests, the calibration `--th` keys qRamT / qVolleyT / qBroodT / qBroodN / qHorde)
    /// Seconds between rams / acid volleys / broods (calm), runners per brood, the horde of her rage (her second phase's).
    public var ramT: Float { move("ram")?.cooldown ?? 0 }
    public var volleyT: Float { move("volley")?.cooldown ?? 0 }
    public var broodT: Float { move("brood")?.cooldown ?? 0 }
    public var broodN: Int { move("brood")?.count ?? 0 }
    public var horde: Float { phases.count > 1 ? phases[1].horde : 0 }
}

extension Game {
    /// The Queen's own per-tick behaviour: none — the framework's phases and moves are all of her.
    @inline(__always) func queenOwnTick(_ dt: Float) {}

    /// The lift timer is out and the boss still lives: the lift waits (HUD «Lift locked — the Queen lives»).
    public var liftLocked: Bool { stage == .hold && boss.alive && liftT <= 0.011 }
}
