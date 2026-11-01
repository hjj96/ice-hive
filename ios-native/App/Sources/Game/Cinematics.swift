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
//                the game camera's side, 3 m outside the platform and
//                2.6 m above its deck, and rides up with it — a little
//                slower, so at the top it looks up across the railing
//                at the squad (until the mission ends)
//    title       attract mode: a lower, closer orbit on the squad
//                (pitch 40°, 15 m), composed into the free space right
//                of the «ЛЕДЯНОЙ УЛЕЙ» logo like MetalCamera's title
//  Every shot keeps its eye out of the four flashlight cones (the
//  beams' 28.6° half-angle + 6° margin, 32 m — VolumeCones): the yaw
//  swings ±15° / 30° / 45° (then the pitch rises 12°) until the eye is
//  outside every beam, and eases to that offset (no jumps).
//  Mood (grade LUT + EV, PostChain): "title" in attract mode,
//  "extraction" while the lift rises, "beacon" while a beacon charges
//  or a punch-in runs, else "gameplay". A mood's EV step is eased:
//  `shotEV` takes the difference at the switch and fades it over
//  `transition` s (Look/exposure.json); each shot adds its own EV
//  ("shots") by its blend weight; `-exposure EV` stays on top.
//  Driver: GameScene in play — or a DemoScript in demos until the
//  scene drives it — calls update() once per tick with the wall dt
//  (the time scale of the world is an output, never an input);
//  MetalWorld asks camera(...) after its own camera and hands mood /
//  shotEV to PostChain (README «Режиссура» → seams).
//  `-cine off` turns the scripted cameras and the dilation off (the
//  mood and its EV stay).
// ================================================================
final class Cinematics {
    static let shared = Cinematics()

    enum Kind: String { case punchIn = "punchin", extraction, title }
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

    // ---- framing
    static let punchIn = (pitchDeg: Float(33), dist: Float(10.5), push: Float(1.0), fovDeg: Float(38), orbitDeg: Float(4))
    static let extraction = (out: Float(3.0), relY0: Float(2.6), relY1: Float(0.9), fovDeg: Float(44), yawOffDeg: Float(20))
    static let title = (pitchDeg: Float(40), dist: Float(15), fovDeg: Float(36), swayDeg: Float(14))

    /// Scripted cameras and the dilation run (off: `-cine off`, or a setting once the menu has one).
    var camerasOn: Bool
    /// Reduced motion (the scene's setting): no time dilation, half the punch-in's push.
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

    // ---- the game, as of the last update
    private var beaconPos = F3(0, 0, 0)
    private var centroid = F3(0, 0, 0)
    private var spots: [(pos: F3, dir: F3)] = []
    private var lift = (c: F3(0, 0, 0), r: Float(10))
    private var rise: Float = 0
    private var extractU: Float = 0

    private init() {
        let a = LaunchOptions.current.unknown
        func value(_ k: String) -> String? { a.firstIndex(of: k).flatMap { i in i + 1 < a.count ? a[i + 1] : nil } }
        camerasOn = value("-cine") != "off"
        launchEV = value("-exposure").flatMap { Float($0) }.map { min(max($0, -4), 4) } ?? 0
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
    }

    // ---------------------------------------------------------------- per tick
    /// Once per tick, wall `dt` (before any time scale).
    func update(game g: Game, dt: Float, by driver: Driver) {
        if driver == .scene { sceneDrives = true } else if sceneDrives { return }
        let dt = max(0, min(0.1, dt))
        clock += dt
        // triggers: a beacon came on → punch-in; the lift leaves → extraction; attract → title
        if g.attract {
            if kind != .title { start(.title) }
        } else if g.stage == .extract {
            if kind != .extraction { start(.extraction) }
        } else {
            if kind == .title || kind == .extraction { kind = nil; weight = 0 }
            for k in 0..<g.beacons.count {
                let s = g.beacons[k].state
                if known && k < beaconStates.count && beaconStates[k] != 2 && s == 2 { beaconIndex = k; start(.punchIn) }
            }
        }
        beaconStates = g.beacons.map { $0.state }
        known = true
        observe(g)
        advance(dt)
        setMood(g, dt)
        if let k = kind, AppLog.diagnostics {
            logT -= dt
            if logT <= 0 {
                logT = 1
                AppLog.info(String(format: "hb cine %@ t=%.2f w=%.2f ts=%.2f mood=%@ ev=%+.2f coneYaw=%+.0f pitch+%.0f moves=%d",
                                   k.rawValue, t, weight, timeScale, mood, shotEV, coneYawDeg, conePitchDeg, coneMoves))
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

    private func start(_ k: Kind) {
        kind = k
        t = 0
        coneWantDeg = 0; conePitchDeg = 0
        if k == .title { weight = 1 }
        started += 1
        logT = 0
        AppLog.info("cine \(k.rawValue) start" + (k == .punchIn ? " beacon=\(beaconIndex)" : "") + (camerasOn ? "" : " (cameras off)"))
    }

    private func advance(_ dt: Float) {
        guard let k = kind else { timeScale = 1; weight = 0; return }
        if let h = hold { t = h } else { t += dt }
        switch k {
        case .punchIn:
            if t >= Cinematics.punchInLength && hold == nil { kind = nil; weight = 0; timeScale = 1; AppLog.info("cine punchin end"); return }
            let tin = Cinematics.punchInEase, tout = Cinematics.punchInOutStart, len = Cinematics.punchInLength
            let wi = easeOut(t / tin)
            let wo = 1 - smooth01f((t - tout) / (len - tout))
            weight = min(wi, wo)
            let (a, b) = Cinematics.dilate, e = Cinematics.dilateEdge
            let d = smooth01f((t - a) / e) * (1 - smooth01f((t - b) / e))
            timeScale = camerasOn && !reducedMotion ? 1 - (1 - Cinematics.dilateSlow) * d : 1
        case .extraction:
            weight = easeOut(t / Cinematics.extractionEase)
            timeScale = 1
        case .title:
            weight = 1
            timeScale = 1
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
        rise = g.liftRise
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
        }
        shot = keepOutOfCones(shot, kind: k, dt: dt)
        if weight >= 0.999 { return shot }
        let w = weight
        return Pose(eye: base.eye + (shot.eye - base.eye) * w, target: base.target + (shot.target - base.target) * w,
                    fovDeg: base.fovDeg + (shot.fovDeg - base.fovDeg) * w)
    }
    private var lastCameraClock: Float = 0
    /// The shot's own yaw / pitch before the cone offsets (for keepOutOfCones).
    private var shotOrbit = (target: F3(0, 0, 0), yaw: Float(0), pitch: Float(0), dist: Float(10))

    private func orbit(_ target: F3, yaw: Float, pitch: Float, dist: Float) -> F3 {
        target + F3(sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch)) * dist
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

    private func extractionPose() -> Pose {
        let X = Cinematics.extraction
        let u = extractU
        let yaw = MetalCamera.yaw + X.yawOffDeg * .pi / 180
        let dir = F3(sinf(yaw), 0, cosf(yaw))
        let wall = lift.c + dir * (lift.r + X.out)
        let eye = F3(wall.x, lift.c.y + X.relY0 + (X.relY1 - X.relY0) * u * u, wall.z)
        let target = centroid + (lift.c - centroid) * 0.3 + F3(0, 1.0 + 0.6 * u, 0)
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
        let n = MetalCamera.titleSquadNDC
        let shift = right * (-n.x * th * aspect * T.dist) + up * (-n.y * th * T.dist)
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
    /// one (±15° steps to ±45°, then the same with the pitch 12° higher) and ease toward it (90°/s).
    private func keepOutOfCones(_ p: Pose, kind: Kind, dt: Float) -> Pose {
        let o = shotOrbit
        func eye(_ yawDeg: Float, _ pitchDeg: Float) -> F3 {
            orbit(o.target, yaw: o.yaw + yawDeg * .pi / 180, pitch: min(1.45, o.pitch + pitchDeg * .pi / 180), dist: o.dist)
        }
        if inCone(eye(coneWantDeg, conePitchDeg)) {
            var found = false
            search: for pitch in [Float(0), 12] {
                for off in [Float(0), 15, -15, 30, -30, 45, -45] where !inCone(eye(off, pitch)) {
                    coneWantDeg = off; conePitchDeg = pitch; found = true
                    break search
                }
            }
            if found { coneMoves += 1 }
        }
        let step = 90 * dt
        coneYawDeg += max(-step, min(step, coneWantDeg - coneYawDeg))
        coneLift += max(-step * 0.5, min(step * 0.5, conePitchDeg - coneLift))
        if abs(coneYawDeg) < 0.01 && abs(coneLift) < 0.01 { return p }
        // (a delta, so the title's composition shift — a translation — is kept)
        return Pose(eye: p.eye + eye(coneYawDeg, coneLift) - eye(0, 0), target: p.target, fovDeg: p.fovDeg)
    }
    private var coneLift: Float = 0

    /// Inside one of the four beams (with a 6° margin), within its range.
    private func inCone(_ e: F3) -> Bool {
        let cosLimit = VolumeCones.cosOut - 0.06
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
