import Foundation
import IceHiveCore

// ================================================================
//  CINEMATICS (WP7 «Режиссура») — the scripted cameras, the time
//  dilation, and the grade mood / shot exposure of the moment.
//    punch-in    a beacon comes on (its state turns 2): the camera
//                pushes in on the mast at the game's yaw (45°), pitch
//                57° → 33°, ≈ 33 → 10 m, while the world slows to
//                ×0.3 for ≈ 0.45 s (smooth edges); it holds, then
//                eases back to the game camera (2.4 s in all)
//    extraction  the lift rises: the camera sits on the shaft wall on
//                the game camera's side (+20°), 3 m outside the
//                platform and 2.6 m above its deck, and rides up with it
//                — a little slower, so at the top it looks up across the
//                railing at the squad; fov 36°. Won (R0 film fixes):
//                the core stops with the ride, but the lift — and the
//                camera on it — eases to a stop (`afterRise`: the ride's
//                last speed decaying over `afterTau` s) instead of
//                halting dead, under the report
//    defeat      (feel build A3) the squad is lost: the world stops,
//                the marines die where they lie (MarineRig's deaths),
//                and the camera pushes in on the player's marine (a
//                fifth of the way to the squad) — 55 % closer and
//                a little lower over `defeatLength` s, the field of view
//                narrowing — then GameScene brings the report up
//    title       attract mode: a lower, closer orbit on the squad
//                (pitch 44°, 24 m, fov 34°), composed into the free
//                space top right, above the subtitle and the class cards
//    boss intro  (Stage 2 B3) a boss comes: its warning arms the shot
//                (the arrival point: the rim edge the Queen climbs
//                over, a point spawn's point), which starts `lead` sim
//                seconds before the warning ends, so the arrival lands
//                on its beat (0.6 s in): the camera pushes in at the
//                game's yaw (pitch 57° → 38°, ≈ 30 → 17 m, fov 38°, a
//                4° orbit), the look point drawn 45 % toward the squad
//                and slid in the view plane so the boss stays between
//                the top band and the banner's low slot, while the
//                world slows to ×0.3 (from 0.15 s, eased; back by
//                2.15 s); the boss rises in slow motion with its name
//                (the core's arrival banner: H1's low slot, chosen for
//                the game camera's view), then the camera eases back
//                to the game camera (from 1.75 s; 2.6 s in all). Input
//                stays live (the stick keeps the game's 45° mapping:
//                the shot keeps the game's yaw), and the squad, the
//                swarm and the boss simply run at the world's ×0.3.
//                Reduce Motion: half of everything — half the length,
//                half the push (the camera goes half the way), half the
//                slowdown (×0.65). A boss with no warning (a debug
//                spawn) gets it from its arrival. Timing and framing
//                per boss kind (`BossIntro.of`): the Queen's row; any
//                other kind derived from its spec until its renderer
//                package tunes it (B5: the Threader)
//  Every shot keeps its eye out of the four flashlight cones (the
//  beams' 28.6° half-angle + ≈ 3.4° margin, 32 m — VolumeCones): after
//  0.3 s inside one (a marine sweeping its aim past the camera does not
//  swing it) the yaw swings ±15° / 30° / 45° (then the pitch rises 12°)
//  until the eye is outside every beam, easing there at 45°/s.
//  Mood (grade LUT + EV, PostChain): "title" in attract mode,
//  "extraction" while the lift rises, "beacon" while a beacon charges
//  or a punch-in runs, else "gameplay". A mood's EV step is eased:
//  `shotEV` takes the difference at the switch and fades it over
//  `transition` s (Look/exposure.json); each shot adds its own EV
//  ("shots") by its blend weight; `-exposure EV` stays on top.
//  Driver: GameScene in play — or a DemoScript in demos until the
//  scene drives it — calls update() once per tick with the wall dt
//  (the time scale of the world is an output, never an input; the
//  scene's own scale — hit-stop, a demo's freeze — comes in only to
//  be counted: a boss's warning-to-arrival wall time is logged split
//  into the intro's slowdown, the game's hit-stops and the tick
//  clock); MetalWorld asks camera(...) after its own camera and hands
//  mood / shotEV to PostChain (README «Режиссура» → seams).
//  `-cine off` turns the scripted cameras and the dilation off (the
//  mood and its EV stay; a boss intro is still logged, with no
//  effect: the world keeps its time exactly — 0.00 s of the intro's
//  slowdown between the warning and the arrival).
// ================================================================
final class Cinematics {
    static let shared = Cinematics()

    enum Kind: String { case punchIn = "punchin", extraction, title, defeat, bossIntro = "bossintro" }

    /// Stage 2 B3: a boss's intro — when its arrival lands in the shot, how the world slows, how the camera frames it.
    /// Times are wall seconds into the shot. `BossIntro.of(kind, spec)` gives a boss kind its row: the Queen's is tuned on
    /// CI's queen runs; any other kind gets one derived from its spec until its renderer package tunes it (B5: the
    /// Threader, by data — its case below).
    struct BossIntro {
        /// The whole shot; the camera's ease in (cubic ease-out); the beat — where the boss's arrival lands (the shot starts
        /// `lead` sim seconds before its warning ends: the warning's last moment and the climb play slowed); the camera's
        /// way back to the game camera from `releaseAt` to `length`.
        var length: Float = 2.6, pushIn: Float = 0.7, beat: Float = 0.6, releaseAt: Float = 1.75
        /// World time × `slow` between `slowIn` and `slowOut`, smooth edges of `slowEdge` s.
        var slow: Float = 0.3, slowIn: Float = 0.15, slowOut: Float = 1.75, slowEdge: Float = 0.4
        /// How far the camera goes from the game camera toward the shot (1 all the way; Reduce Motion half).
        var reach: Float = 1
        /// Framing: the game camera's yaw (+ `yawDeg`, orbiting `orbitDeg` over the shot), `pitchDeg`, `dist` from the look
        /// point, `fovDeg`. The look point: `lookUp` m over the arrival point, drawn `toSquad` of the way toward the squad's
        /// centre; then the camera slides in its view plane so the arrival point stays at or above `footNDC` (NDC y) and the
        /// boss's top (`height` m over it) at or below `topNDC` — clear of the banner's low slot and of the top band.
        var pitchDeg: Float = 38, dist: Float = 17, fovDeg: Float = 38, yawDeg: Float = 0, orbitDeg: Float = 4
        var lookUp: Float = 1.2, toSquad: Float = 0.45, height: Float = 2.8
        var footNDC: Float = 0, topNDC: Float = 0.66

        /// The row of a boss kind. Its height at the arrival comes from the spec's body (a bug: 0.67 × its draw scale — the
        /// Queen's 4.2 → 2.8 m; a chain: its head's).
        static func of(_ kind: BossKind, _ spec: BossSpec) -> BossIntro {
            var b = BossIntro()
            switch spec.body {
            case .bug(_, _, let scale): b.height = 0.67 * scale
            case .chain(let c): b.height = max(1, c.head.scale)
            }
            switch kind {
            case .queen:
                break   // the defaults are hers
            case .threader:
                // (until B5 tunes it: a chain boss arriving at its point up in the pipes, framed wider and from further away
                // for its long body; B5 sets this case's numbers — see README «Заставка босса»)
                if case .chain(let c) = spec.body {
                    b.dist = 17 + 0.3 * c.length; b.fovDeg = 42; b.pitchDeg = 34; b.toSquad = 0.3; b.lookUp = 0
                }
            }
            return b
        }

        /// Reduce Motion: half of everything — every time × 0.5 (half the length), half the push (the camera goes half the
        /// way from the game camera), half the slowdown (× 0.65 instead of × 0.3).
        var halved: BossIntro {
            var b = self
            b.length *= 0.5; b.pushIn *= 0.5; b.beat *= 0.5; b.releaseAt *= 0.5
            b.slowIn *= 0.5; b.slowOut *= 0.5; b.slowEdge *= 0.5
            b.slow = 1 - (1 - slow) * 0.5
            b.reach = reach * 0.5
            return b
        }

        /// The shot's blend over the game camera at `t`.
        func weight(_ t: Float) -> Float {
            let u = clampf(t / pushIn, 0, 1)
            let wi = 1 - (1 - u) * (1 - u) * (1 - u)
            let wo = 1 - smooth01f((t - releaseAt) / max(0.01, length - releaseAt))
            return min(wi, wo) * reach
        }

        /// World time scale at `t`.
        func timeScale(_ t: Float) -> Float {
            let d = smooth01f((t - slowIn) / slowEdge) * (1 - smooth01f((t - slowOut) / slowEdge))
            return 1 - (1 - slow) * d
        }

        /// Sim seconds from the shot's start to its beat (the world slowing on the way in; `dilated` false: `beat`).
        func lead(dilated: Bool) -> Float {
            guard dilated else { return beat }
            var s: Float = 0, t: Float = 0
            let h: Float = 1.0 / 240
            while t < beat - 1e-6 {
                let step = min(h, beat - t)
                s += timeScale(t + step * 0.5) * step
                t += step
            }
            return s
        }
    }
    /// Who calls update(): once the scene does, the demos' calls are ignored (one update per tick).
    enum Driver { case scene, demo }

    /// A camera: eye, look-at point, vertical field of view.
    struct Pose {
        var eye: F3
        var target: F3
        var fovDeg: Float
    }

    // ---- timing (s, wall)
    static let punchInLength: Float = 2.4
    static let punchInEase: Float = 0.35, punchInOutStart: Float = 1.5
    /// Time dilation of the punch-in: ×slow between `dilate.0` and `dilate.1` s into the shot, smooth edges of `edge` s.
    static let dilate: (Float, Float) = (0.08, 0.53), dilateEdge: Float = 0.1, dilateSlow: Float = 0.3
    static let extractionEase: Float = 0.6
    /// The defeat beat (A3): the deaths and the push-in before the report (GameScene holds the report this long).
    static let defeatLength: Float = 2.8
    static let defeat = (push: Float(0.55), drop: Float(0.15), fovDeg: Float(6), ease: Float(0.9))

    // ---- framing
    static let punchIn = (pitchDeg: Float(33), dist: Float(10.5), push: Float(1.0), fovDeg: Float(38), orbitDeg: Float(4))
    static let extraction = (out: Float(3.0), relY0: Float(2.6), relY1: Float(0.9), fovDeg: Float(36), yawOffDeg: Float(20))
    /// (the squad sits higher than MetalCamera's title spot: closer, it would otherwise run into the subtitle and the cards)
    static let title = (pitchDeg: Float(44), dist: Float(24), fovDeg: Float(34), swayDeg: Float(12), ndcX: Float(0.5), ndcY: Float(0.66))
    /// Beams: the eye stays this far (cos) outside a cone's 28.6° edge; it moves only after `coneDwell` s inside one
    /// (a marine sweeping its aim across the camera does not swing it), at `coneRate` °/s.
    static let coneMargin: Float = 0.03, coneDwell: Float = 0.3, coneRate: Float = 45

    /// Scripted cameras and the dilation run (off: `-cine off`, or a setting once the menu has one).
    var camerasOn: Bool
    /// Reduced motion (the scene's setting): no time dilation, half the punch-in's push; half of the boss intro.
    var reducedMotion = false

    private(set) var kind: Kind? = nil
    /// Seconds into the current shot (wall time).
    private(set) var t: Float = 0
    /// Blend of the shot over the game camera, 0…1.
    private(set) var weight: Float = 0
    /// World time scale the scene applies (the punch-in's dilation); 1 otherwise.
    private(set) var timeScale: Float = 1
    /// Grade mood for PostChain.setMood.
    private(set) var mood = "gameplay"
    /// EV for PostChain.shotEV: the launch `-exposure`, the eased mood step and the shot's own EV.
    private(set) var shotEV: Float = 0
    /// GameScene calls update() (from then on the demos only trigger shots).
    var drivenByScene: Bool { sceneDrives }
    /// Shots started since the last reset (logs / CI).
    private(set) var started = 0
    /// R0 (film fixes): the weight of a close scripted shot on screen (punch-in, extraction, defeat; not the title's orbit)
    /// — the squad's faint class rim and the brighter accent read in it (WorldSquad).
    var closeShotWeight: Float { camerasOn && kind != nil && kind != .title ? weight : 0 }
    /// R0: the extraction shot's weight — the bugs' near-lens fade (WorldSwarm).
    var extractionWeight: Float { camerasOn && kind == .extraction ? weight : 0 }
    /// R0: how far the lift has gone past the core's rise since the mission was won on it (m). The core stops ticking at
    /// the win and the lift — with the extraction camera riding it — halted dead for the ~2 s before the report in the
    /// feel build's film; now it keeps the ride's last speed, decaying over `afterTau` s. Every reader of the rise takes
    /// `liftRise(_:)`.
    private(set) var afterRise: Float = 0
    static let afterTau: Float = 0.8
    /// Won on the lift, the shot drifts on under the report: a slow orbit round the squad and a lift of the eye, eased in
    /// and out over `time` s (with the camera riding the platform the world would otherwise stand nearly still in frame).
    static let afterDrift = (time: Float(5), yawDeg: Float(9), rise: Float(1.1))
    /// The lift's rise as drawn: the core's, plus the eased overrun after a win.
    func liftRise(_ g: Game) -> Float { g.liftRise + afterRise }
    /// The eye's yaw offset that keeps it out of the beams (degrees, eased) and how often it had to move.
    private(set) var coneYawDeg: Float = 0
    private(set) var coneMoves = 0

    private var hold: Float? = nil
    private var beaconIndex = -1
    private var beaconStates: [Int] = []
    private var sceneDrives = false
    private var known = false
    private var moodEVs: [String: Float] = [:]
    private var shotEVs: [String: Float] = [:]
    private var transition: Float = 0.8
    private var carryEV: Float = 0
    private let launchEV: Float
    private var coneWantDeg: Float = 0
    private var conePitchDeg: Float = 0
    private var clock: Float = 0
    private var logT: Float = 0
    // R0: the ride's speed (m/s, the chord over the last core tick) and the time since the win on the lift
    private var riseV: Float = 0
    private var riseE: Float = -1, riseR: Float = 0
    private var afterT: Float = 0
    /// The camera observes the game before the frame's ticks, so during the ride it trails the drawn lift by one tick of
    /// travel; after the win that trail fades with the speed instead of snapping shut (a framing jump at the win).
    private var afterLag: Float = 0

    // ---- the game, as of the last update
    private var beaconPos = F3(0, 0, 0)
    private var centroid = F3(0, 0, 0)
    /// Where the defeat shot looks: the player's marine (the last one standing goes down with the mission), between it
    /// and the squad's centre by a fifth.
    private var squadCentre = F3(0, 0, 0)
    private var spots: [(pos: F3, dir: F3)] = []
    private var lift = (c: F3(0, 0, 0), r: Float(10))
    private var rise: Float = 0
    private var extractU: Float = 0

    // ---- B3: the boss intro
    /// A boss's warning was seen and its shot waits for its moment (`bossLead` s of warning left).
    private var bossArmed = false
    /// The boss it is for, its arrival point (x, its height — the deck, a point spawn's height —, z), its row (halved
    /// under Reduce Motion) and the sim seconds from the shot's start to its beat.
    private var bossKind = BossKind.queen
    private var bossAt = F3(0, 0, 0)
    private(set) var bossShot = BossIntro()
    private var bossLead: Float = 0
    /// How the running intro started (`warning`, or `arrival` for a boss that came with no warning).
    private var bossFrom = "warning"
    /// The warning's wall clock and sim time (-1: none pending); seconds into the shot when the boss came (-1: not yet).
    private var bossWarnClock: Float = -1, bossWarnSim: Float = -1
    private var bossArrivedAt: Float = -1
    /// Since the warning, the wall seconds the world's slowdowns cost: the intro's own (Σ dt · (1 − its scale)) and, under
    /// it, the game's (hit-stops, a demo's freeze: Σ dt · its scale · (1 − the scene's)). The rest of wall − sim is the tick
    /// clock (the accumulator's part of a tick, a host frame past four ticks). `-cine off`: the intro's is 0 exactly.
    private var bossSlowIntro: Float = 0, bossSlowGame: Float = 0

    private init() {
        let a = LaunchOptions.current.unknown
        func value(_ k: String) -> String? { a.firstIndex(of: k).flatMap { i in i + 1 < a.count ? a[i + 1] : nil } }
        camerasOn = value("-cine") != "off"
        launchEV = value("-exposure").flatMap { Float($0) }.map { min(max($0, -4), 4) } ?? 0
        shotEV = launchEV
        loadTable()
    }

    /// Look/exposure.json: the moods' EV (also read by PostChain), "shots": EV per shot, "transition": s.
    private func loadTable() {
        guard let u = Bundle.main.url(forResource: "exposure", withExtension: "json", subdirectory: "Look")
                ?? Bundle.main.url(forResource: "exposure", withExtension: "json"),
              let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        for (k, v) in j {
            if let n = v as? NSNumber { moodEVs[k] = n.floatValue }
        }
        if let s = j["shots"] as? [String: Any] {
            for (k, v) in s { if let n = v as? NSNumber { shotEVs[k] = n.floatValue } }
        }
        if let c = j["cine"] as? [String: Any], let n = c["transition"] as? NSNumber { transition = max(0.05, n.floatValue) }
    }

    /// New mission / title: forget the shot and the beacon states (the next update takes them as they are).
    func reset() {
        kind = nil; t = 0; weight = 0; timeScale = 1; hold = nil
        beaconIndex = -1; beaconStates = []; known = false
        coneYawDeg = 0; coneWantDeg = 0; conePitchDeg = 0; coneLift = 0; coneMoves = 0
        started = 0
        mood = "gameplay"; carryEV = 0; shotEV = launchEV
        riseV = 0; riseE = -1; riseR = 0; afterT = 0; afterRise = 0; afterLag = 0
        bossArmed = false; bossWarnClock = -1; bossWarnSim = -1; bossArrivedAt = -1
        bossSlowIntro = 0; bossSlowGame = 0
    }

    // ---------------------------------------------------------------- per tick
    /// Once per tick, wall `dt` (before any time scale). `worldScale`: the scale the scene puts on the world besides this
    /// one's this tick (hit-stop × a demo's freeze) — only counted (B3: where a boss's warning-to-arrival wall time goes).
    func update(game g: Game, dt: Float, by driver: Driver, worldScale: Float = 1) {
        if driver == .scene { sceneDrives = true } else if sceneDrives { return }
        let dt = max(0, min(0.1, dt))
        clock += dt
        // triggers: a beacon came on → punch-in; the lift leaves → extraction; attract → title
        if g.attract {
            if kind != .title { start(.title) }
        } else if g.phase == .lost {
            if kind != .defeat { start(.defeat) }
        } else if g.stage == .extract {
            if kind != .extraction { start(.extraction) }
        } else {
            if kind == .title || kind == .extraction || kind == .defeat { kind = nil; weight = 0 }
            for k in 0..<g.beacons.count {
                let s = g.beacons[k].state
                if known && k < beaconStates.count && beaconStates[k] != 2 && s == 2 { beaconIndex = k; start(.punchIn) }
            }
            // B3: an armed boss intro starts `bossLead` s before the warning ends (at once when it is shorter, or when the
            // boss is already there)
            if bossArmed && kind != .bossIntro
                && (g.boss.spawned || (g.boss.warning >= 0 && g.boss.warning <= bossLead + SIM_DT * 0.5)) {
                startBossIntro(from: g.boss.spawned ? "arrival" : "warning", warningLeft: max(0, g.boss.warning))
            }
        }
        beaconStates = g.beacons.map { $0.state }
        known = true
        // R0: the ride's speed while it runs; won on the lift, the eased overrun (the core's rise stands still from then on)
        if g.stage == .extract && g.phase == .playing {
            let e = g.extractT
            if riseE >= 0 && e > riseE + 1e-4 { riseV = max(0, (g.liftRise - riseR) / (e - riseE)) }
            if e != riseE { riseE = e; riseR = g.liftRise }
            afterT = 0; afterRise = 0; afterLag = 0
        } else if g.phase == .won && g.stage == .extract {
            afterT += dt
            let fade = expf(-afterT / Cinematics.afterTau)
            afterRise = riseV * Cinematics.afterTau * (1 - fade)
            afterLag = riseV * SIM_DT * fade
        } else if g.phase != .won {
            riseE = -1; afterT = 0; afterRise = 0; afterLag = 0
        }
        observe(g)
        advance(dt)
        // B3: from a boss's warning to its arrival, the wall time this tick's slowdowns cost — the intro's and the game's
        // under it (the scene steps the world by dt × worldScale × timeScale after this)
        if bossWarnClock >= 0 {
            bossSlowIntro += dt * (1 - timeScale)
            bossSlowGame += dt * timeScale * (1 - min(1, max(0, worldScale)))
        }
        setMood(g, dt)
        if let k = kind, AppLog.diagnostics {
            logT -= dt
            if logT <= 0 {
                logT = 1
                AppLog.info(String(format: "hb cine %@ t=%.2f w=%.2f ts=%.2f mood=%@ ev=%+.2f coneYaw=%+.0f pitch+%.0f moves=%d",
                                   k.rawValue, t, weight, timeScale, mood, shotEV, coneYawDeg, conePitchDeg, coneMoves)
                            + (g.phase == .won && k == .extraction ? String(format: " won+%.1fs lift+%.2fm v=%.2fm/s", afterT, afterRise,
                                                                             riseV * expf(-afterT / Cinematics.afterTau)) : ""))
            }
        }
    }

    /// Demos: play the last punch-in again from its start (the same beacon).
    func replayPunchIn() {
        guard beaconIndex >= 0 else { return }
        start(.punchIn)
    }

    /// Demos: freeze the current shot at `seconds` into it (screenshots); nil releases it.
    func hold(at seconds: Float?) { hold = seconds }

    // ---------------------------------------------------------------- B3: the boss intro
    /// GameScene, on `.bossWarning`: arm the boss intro — its row, its arrival point (`pos`: the rim edge it climbs over, a
    /// point spawn's point), its lead; the shot starts `bossLead` s before the warning ends (update).
    func bossWarned(kind k: BossKind, pos: Vec2, game g: Game) {
        bossKind = k
        bossShot = reducedMotion ? BossIntro.of(k, g.bossSpec).halved : BossIntro.of(k, g.bossSpec)
        bossLead = bossShot.lead(dilated: camerasOn)
        bossAt = arrivalPoint(pos, g)
        bossArmed = true
        bossWarnClock = clock; bossWarnSim = g.time; bossArrivedAt = -1
        bossSlowIntro = 0; bossSlowGame = 0
        AppLog.info(String(format: "cine bossintro armed kind=%@ at (%.1f, %.1f, %.1f): its warning %.2f s, the shot from %.2f s before its end",
                           k.rawValue, bossAt.x, bossAt.y, bossAt.z, g.bossSpec.warn, bossLead))
    }

    /// GameScene, on `.bossSpawned`: the boss is there — its moment in the running intro is logged (it should land on the
    /// beat), or, with no intro running (it came with no warning: a debug spawn, a zero warning), the intro starts now.
    func bossArrived(kind k: BossKind, pos: Vec2, game g: Game) {
        if kind != .bossIntro {
            if !bossArmed {
                bossKind = k
                bossShot = reducedMotion ? BossIntro.of(k, g.bossSpec).halved : BossIntro.of(k, g.bossSpec)
                bossLead = 0
                bossAt = arrivalPoint(pos, g)
            }
            startBossIntro(from: "arrival", warningLeft: 0)
        }
        bossArrivedAt = t
        let warned = bossWarnSim >= 0
        // (the wall split: the intro's slowdown — 0.00 with `-cine off` —, the game's hit-stops under it, the tick clock)
        let sim = g.time - bossWarnSim, wall = clock - bossWarnClock
        AppLog.info(String(format: "cine bossintro: %@ there %.2f s into the shot (beat %.2f)", k.rawValue, t, bossShot.beat)
                    + (warned ? String(format: ", %.2f s of sim and %.2f s of wall after its warning (the intro's slowdown %.2f s, the game's hit-stops %.2f s, the tick clock %+.2f s)",
                                       sim, wall, bossSlowIntro, bossSlowGame, wall - sim - bossSlowIntro - bossSlowGame)
                              : ", no warning")
                    + (camerasOn ? "" : " (cameras off)"))
        bossWarnClock = -1; bossWarnSim = -1
    }

    private func startBossIntro(from: String, warningLeft: Float) {
        bossArmed = false
        bossFrom = from
        bossArrivedAt = -1
        start(.bossIntro)
        let B = bossShot
        AppLog.info(String(format: "cine bossintro shot kind=%@ from=%@ warning left %.2f s, lead %.2f s, beat %.2f s, %.2f s in all, ×%.2f, reach %.2f",
                           bossKind.rawValue, from, warningLeft, bossLead, B.beat, B.length, B.slow, B.reach)
                    + (reducedMotion ? " (reduced motion: half the length, half the push, half the slowdown)" : ""))
    }

    /// A boss's arrival point: x, z of `p` at its height — a point spawn's own, an arena spawn's lift over its deck, the
    /// deck's height a step inward from a rim edge (toward the squad: the edge is the deck's last cell).
    private func arrivalPoint(_ p: Vec2, _ g: Game) -> F3 {
        let L = g.level
        switch g.bossSpec.spawn {
        case .point(_, _, let y, _):
            return F3(p.x, y, p.y)
        case .arena(let lift, _):
            return F3(p.x, L.groundY(p.x, p.y) + lift, p.y)
        case .rim:
            var dx = centroid.x - p.x, dz = centroid.z - p.y
            let d = max(1e-3, (dx * dx + dz * dz).squareRoot())
            dx /= d; dz /= d
            return F3(p.x, L.groundY(p.x + dx * 1.5, p.y + dz * 1.5), p.y)
        }
    }

    private func start(_ k: Kind) {
        kind = k
        t = 0
        dilMin = 1; dilTime = 0
        coneWantDeg = 0; conePitchDeg = 0; coneInside = 0
        if k == .title { weight = 1 }
        started += 1
        logT = 0
        let td = DemoScript.sceneClock
        AppLog.info("cine \(k.rawValue) start" + (k == .punchIn ? " beacon=\(beaconIndex)" : "")
                    + (k == .bossIntro ? " kind=\(bossKind.rawValue) from=\(bossFrom)" + (td >= 0 ? String(format: " td=%.2f", td) : "") : "")
                    + (camerasOn ? "" : " (cameras off)"))
    }

    private func advance(_ dt: Float) {
        guard let k = kind else { timeScale = 1; weight = 0; return }
        if let h = hold { t = h } else { t += dt }
        switch k {
        case .punchIn:
            if t >= Cinematics.punchInLength && hold == nil {
                kind = nil; weight = 0; timeScale = 1
                AppLog.info(String(format: "cine punchin end dilation x%.2f for %.2f s", dilMin, dilTime))
                return
            }
            let tin = Cinematics.punchInEase, tout = Cinematics.punchInOutStart, len = Cinematics.punchInLength
            let wi = easeOut(t / tin)
            let wo = 1 - smooth01f((t - tout) / (len - tout))
            weight = min(wi, wo)
            let (a, b) = Cinematics.dilate, e = Cinematics.dilateEdge
            let d = smooth01f((t - a) / e) * (1 - smooth01f((t - b) / e))
            timeScale = camerasOn && !reducedMotion ? 1 - (1 - Cinematics.dilateSlow) * d : 1
            if hold == nil {
                dilMin = min(dilMin, timeScale)
                if timeScale < 0.95 { dilTime += dt }
            }
        case .extraction:
            weight = easeOut(t / Cinematics.extractionEase)
            timeScale = 1
        case .title:
            weight = 1
            timeScale = 1
        case .defeat:
            weight = easeOut(t / Cinematics.defeat.ease)
            timeScale = 1
        case .bossIntro:
            let B = bossShot
            if t >= B.length && hold == nil {
                kind = nil; weight = 0; timeScale = 1
                AppLog.info(String(format: "cine bossintro end dilation x%.2f for %.2f s, %.2f s in all, ", dilMin, dilTime, B.length)
                            + (bossArrivedAt >= 0 ? String(format: "the boss there at %.2f s (beat %.2f)", bossArrivedAt, B.beat) : "the boss not there yet")
                            + (camerasOn ? "" : " (cameras off)"))
                return
            }
            weight = B.weight(t)
            timeScale = camerasOn ? B.timeScale(t) : 1
            if hold == nil {
                dilMin = min(dilMin, timeScale)
                if timeScale < 0.95 { dilTime += dt }
            }
        }
        if !camerasOn { weight = 0 }
    }

    private func setMood(_ g: Game, _ dt: Float) {
        let want: String
        if g.attract { want = "title" }
        else if g.stage == .extract { want = "extraction" }
        else if g.activeBeacon >= 0 || kind == .punchIn { want = "beacon" }
        else { want = "gameplay" }
        if want != mood {
            carryEV += (moodEVs[mood] ?? 0) - (moodEVs[want] ?? 0)
            mood = want
        }
        carryEV *= expf(-dt * 3 / transition)
        if abs(carryEV) < 0.002 { carryEV = 0 }
        let shot = kind.map { shotEVs[$0.rawValue] ?? 0 } ?? 0
        shotEV = launchEV + carryEV + shot * weight
    }

    // ---------------------------------------------------------------- the game's state
    private func observe(_ g: Game) {
        let L = g.level
        if beaconIndex >= 0 && beaconIndex < g.beacons.count {
            let b = g.beacons[beaconIndex]
            beaconPos = F3(b.x, L.groundY(b.x, b.z), b.z)
        }
        rise = liftRise(g) - afterLag
        extractU = g.stage == .extract ? smooth01f(g.extractT / 4.5) : 0
        let ls = L.lift
        lift = (F3(ls.x, ls.y + rise, ls.z), ls.r)
        var c = F3(0, 0, 0), n: Float = 0
        spots.removeAll(keepingCapacity: true)
        for m in g.marines {
            let onLift = g.stage == .extract && L.onLift(m.x, m.z)
            let y = L.groundY(m.x, m.z) + (onLift ? rise : 0)
            let p = F3(m.x, y, m.z)
            if !m.downed { c += p; n += 1 }
            // like WorldSquad.flashlight (without the rig's torch socket): 1.75 m up, aimed 9 m ahead onto the deck
            let pos = m.downed ? F3(m.x, y + 0.6, m.z) : F3(m.x + m.ax * 0.3, y + 1.75, m.z + m.az * 0.3)
            let tgt = m.downed ? F3(m.x + m.ax * 2.4, y, m.z + m.az * 2.4) : F3(m.x + m.ax * 9, y, m.z + m.az * 9)
            let d = tgt - pos
            spots.append((pos, d / max(1e-4, length(d))))
        }
        if n > 0 { centroid = c / n } else if let m = g.marines.first { centroid = F3(m.x, L.groundY(m.x, m.z), m.z) }
        var all = F3(0, 0, 0)
        for m in g.marines { all += F3(m.x, L.groundY(m.x, m.z), m.z) }
        if let p = g.marines.first {
            let pp = F3(p.x, L.groundY(p.x, p.z), p.z)
            squadCentre = pp + (all / Float(g.marines.count) - pp) * 0.2
        } else {
            squadCentre = centroid
        }
    }

    // ---------------------------------------------------------------- the camera
    /// The camera of this frame given the game camera's (`base`), or nil when no shot is on. `aspect` = width / height
    /// of the view; `time` = the renderer's clock (title sway).
    func camera(base: Pose, aspect: Float, time: Float) -> Pose? {
        guard let k = kind, weight > 0.001, camerasOn else { return nil }
        let dt = max(0, min(0.1, clock - lastCameraClock))
        lastCameraClock = clock
        var shot: Pose
        switch k {
        case .punchIn: shot = punchInPose()
        case .extraction: shot = extractionPose()
        case .title: shot = titlePose(aspect: aspect, time: time)
        case .defeat: shot = defeatPose(base)
        case .bossIntro: shot = bossIntroPose()
        }
        // (the defeat looks down at marines lying on the deck: their torches point at it, not into the lens)
        if k != .defeat { shot = keepOutOfCones(shot, kind: k, dt: dt) }
        if weight >= 0.999 { return shot }
        let w = weight
        return Pose(eye: base.eye + (shot.eye - base.eye) * w, target: base.target + (shot.target - base.target) * w,
                    fovDeg: base.fovDeg + (shot.fovDeg - base.fovDeg) * w)
    }
    private var lastCameraClock: Float = 0
    /// The punch-in's dilation as it ran (lowest scale, seconds under 0.95) for its end line.
    private var dilMin: Float = 1, dilTime: Float = 0
    /// The shot's own yaw / pitch before the cone offsets (for keepOutOfCones).
    private var shotOrbit = (target: F3(0, 0, 0), yaw: Float(0), pitch: Float(0), dist: Float(10))

    private func orbit(_ target: F3, yaw: Float, pitch: Float, dist: Float) -> F3 {
        target + F3(sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch)) * dist
    }

    /// The defeat: from the game camera's own direction, pushed in on the whole squad and a little lower.
    private func defeatPose(_ base: Pose) -> Pose {
        let D = Cinematics.defeat
        let u = smooth01f(t / Cinematics.defeatLength) * (reducedMotion ? 0.5 : 1)
        let target = squadCentre + F3(0, 0.45, 0)
        var dir = base.eye - base.target
        dir.y *= 1 - D.drop * u
        return Pose(eye: target + dir * (1 - D.push * u), target: target, fovDeg: base.fovDeg - D.fovDeg * u)
    }

    private func punchInPose() -> Pose {
        let P = Cinematics.punchIn
        let u = min(1, t / Cinematics.punchInLength)
        let mast = beaconPos + F3(0, 1.4, 0)
        let target = mast + (centroid + F3(0, 1.0, 0) - mast) * 0.3
        let yaw = MetalCamera.yaw + P.orbitDeg * u * .pi / 180
        let pitch = P.pitchDeg * .pi / 180
        let dist = P.dist - P.push * u * (reducedMotion ? 0.5 : 1)
        shotOrbit = (target, yaw, pitch, dist)
        return Pose(eye: orbit(target, yaw: yaw, pitch: pitch, dist: dist), target: target, fovDeg: P.fovDeg)
    }

    /// B3: the boss intro's camera — the game's yaw (+ its orbit), `pitchDeg` and `dist` from the look point (the arrival
    /// point lifted `lookUp`, drawn `toSquad` toward the squad), then slid in its view plane so the arrival point stays at
    /// or above `footNDC` and the boss's top at or below `topNDC`.
    private func bossIntroPose() -> Pose {
        let B = bossShot
        let u = min(1, t / max(0.01, B.length))
        let a = F3(bossAt.x, bossAt.y + B.lookUp, bossAt.z)
        var target = a + (centroid + F3(0, 1.0, 0) - a) * B.toSquad
        let yaw = MetalCamera.yaw + (B.yawDeg + B.orbitDeg * u) * .pi / 180
        let pitch = B.pitchDeg * .pi / 180
        var eye = orbit(target, yaw: yaw, pitch: pitch, dist: B.dist)
        // (the slide: the camera down moves the scene up on screen, up moves it down — eye and target together, so the cone
        // dodge's orbit about the target keeps it)
        let f = (target - eye) / max(1e-4, length(target - eye))
        let up = basis(eye: eye, target: target).1
        let th = tanf(B.fovDeg * .pi / 360)
        func ndc(_ p: F3) -> (y: Float, z: Float) {
            let v = p - eye
            let z = max(0.5, Mat4.dot(v, f))
            return (Mat4.dot(v, up) / (z * th), z)
        }
        let nf = ndc(bossAt), nt = ndc(bossAt + F3(0, B.height, 0))
        var slide: Float = 0
        if nf.y < B.footNDC { slide = (B.footNDC - nf.y) * nf.z * th } else if nt.y > B.topNDC { slide = -(nt.y - B.topNDC) * nt.z * th }
        eye = eye - up * slide
        target = target - up * slide
        shotOrbit = (target, yaw, pitch, B.dist)
        return Pose(eye: eye, target: target, fovDeg: B.fovDeg)
    }

    private func extractionPose() -> Pose {
        let X = Cinematics.extraction
        let u = extractU
        // (R0: won on the lift — the slow drift under the report)
        let D = Cinematics.afterDrift
        let dw = afterT > 0 ? smooth01f(afterT / D.time) : 0
        let yaw = MetalCamera.yaw + (X.yawOffDeg + D.yawDeg * dw) * .pi / 180
        let dir = F3(sinf(yaw), 0, cosf(yaw))
        let wall = lift.c + dir * (lift.r + X.out)
        let eye = F3(wall.x, lift.c.y + X.relY0 + (X.relY1 - X.relY0) * u * u + D.rise * dw, wall.z)
        let target = centroid + (lift.c - centroid) * 0.3 + F3(0, 0.7 + 0.5 * u, 0)
        let d = eye - target
        let hd = (d.x * d.x + d.z * d.z).squareRoot()
        shotOrbit = (target, atan2f(d.x, d.z), atan2f(d.y, max(1e-3, hd)), length(d))
        return Pose(eye: eye, target: target, fovDeg: X.fovDeg)
    }

    private func titlePose(aspect: Float, time: Float) -> Pose {
        let T = Cinematics.title
        let yaw = MetalCamera.yaw + sinf(time * 0.05) * T.swayDeg * .pi / 180
        let pitch = T.pitchDeg * .pi / 180
        let s = centroid + F3(0, 0.9, 0)
        // compose: translate the camera across its view plane so the squad lands on MetalCamera.titleSquadNDC
        let eye0 = orbit(s, yaw: yaw, pitch: pitch, dist: T.dist)
        let (right, up) = basis(eye: eye0, target: s)
        let th = tanf(T.fovDeg * .pi / 360)
        let shift = right * (-T.ndcX * th * aspect * T.dist) + up * (-T.ndcY * th * T.dist)
        let target = s + shift
        shotOrbit = (target, yaw, pitch, T.dist)
        return Pose(eye: eye0 + shift, target: target, fovDeg: T.fovDeg)
    }

    private func basis(eye: F3, target: F3) -> (F3, F3) {
        let f = (target - eye) / max(1e-4, length(target - eye))
        var r = Mat4.cross(f, F3(0, 1, 0))
        r = r / max(1e-4, length(r))
        return (r, Mat4.cross(r, f))
    }

    /// The eye outside every flashlight cone: keep the current yaw offset while it is clear, else find the nearest clear
    /// one (±15° steps to ±45°, then the same with the pitch 6° higher) and ease toward it (90°/s).
    /// (feel-build review: the lift was 12° — the raised eye looked down on the lit deck, the extraction's median-62
    /// look shots; the yaw search stays at ±45°, wider swings put the eye beside the bugs climbing the lift's rim)
    private func keepOutOfCones(_ p: Pose, kind: Kind, dt: Float) -> Pose {
        let o = shotOrbit
        func eye(_ yawDeg: Float, _ pitchDeg: Float) -> F3 {
            orbit(o.target, yaw: o.yaw + yawDeg * .pi / 180, pitch: min(1.45, o.pitch + pitchDeg * .pi / 180), dist: o.dist)
        }
        if inCone(eye(coneWantDeg, conePitchDeg)) { coneInside += dt } else { coneInside = 0 }
        // (at a shot's start the eye moves at once: it is still blending in from the game camera)
        if coneInside >= (t < 0.1 ? 0 : Cinematics.coneDwell) && coneInside > 0 {
            coneInside = 0
            var found = false
            search: for pitch in [Float(0), 6] {
                for off in [Float(0), 15, -15, 30, -30, 45, -45] where !inCone(eye(off, pitch)) {
                    coneWantDeg = off; conePitchDeg = pitch; found = true
                    break search
                }
            }
            if found { coneMoves += 1 }
        }
        let step = Cinematics.coneRate * dt
        coneYawDeg += max(-step, min(step, coneWantDeg - coneYawDeg))
        coneLift += max(-step * 0.5, min(step * 0.5, conePitchDeg - coneLift))
        if abs(coneYawDeg) < 0.01 && abs(coneLift) < 0.01 { return p }
        // (a delta, so the title's composition shift — a translation — is kept)
        return Pose(eye: p.eye + eye(coneYawDeg, coneLift) - eye(0, 0), target: p.target, fovDeg: p.fovDeg)
    }
    private var coneLift: Float = 0
    private var coneInside: Float = 0

    /// Inside one of the four beams (with a 6° margin), within its range.
    private func inCone(_ e: F3) -> Bool {
        let cosLimit = VolumeCones.cosOut - Cinematics.coneMargin
        for s in spots {
            let v = e - s.pos
            let d = length(v)
            if d < 0.05 || d > VolumeCones.range { continue }
            if Mat4.dot(v / d, s.dir) > cosLimit { return true }
        }
        return false
    }

    private func easeOut(_ x: Float) -> Float { let u = clampf(x, 0, 1); return 1 - (1 - u) * (1 - u) * (1 - u) }
    private func length(_ v: F3) -> Float { (v * v).sum().squareRoot() }
}
