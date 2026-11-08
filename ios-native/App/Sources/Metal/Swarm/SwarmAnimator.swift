import Foundation
import IceHiveCore

// ================================================================
//  SWARM ANIMATOR — which clip rows every creature plays this frame
//  (owned by WP3 «Рой»). The GPU blends two clips per instance by
//  matrix lerp (Swarm.metal vs_creature): clip A (two rows + frac) and
//  clip B (two rows + frac, weight wB). This file picks them:
//   locomotion  idle / walk / run by the bug's speed in body lengths,
//               the gait phase advanced by the DISTANCE walked over
//               the clip's stride (× instance scale) — planted feet at
//               any speed, walk and run share one tripod phase so their
//               blend never slides; backward pushes step backward
//   attack      the lunge one-shot when the core lands a bite (its gait
//               odometer jumps 1.5 rad), started a few frames before the
//               mandibles' snap frame so the bite reads on the hit
//   hit         the recoil one-shot on a new hit flash (+ a damped lean
//               spring tipping the body away from the impact: the shot's
//               direction from WorldSwarm, or the nearest marine)
//   states      spitter spit wind-up, brute wind-up and charge, boomer
//               swell — synced to the core's state timers; climbing
//               over the railing runs on the core's own odometer
//   transitions a state change cross-fades from the last pose (0.15 s)
//   deaths      corpses (Corpses.swift): the type's death variant from
//               the moment of death, faded in from the dying bug's last
//               pose, then held on its last row — the same mesh, never
//               swapped
//  Per-bug state lives in a table indexed by uid (direct-mapped, 8192
//  slots: a slot reused by another uid is reset), so compaction of the
//  core's arrays never mixes two bugs' animation.
//  native-vx-swarm-life — a living swarm, not a marching column (at the
//  game camera a bug is 15–40 px: the BODY reads, not the legs):
//   tempo       every bug its own cadence ×0.85–1.15 (by uid, independent
//               of its speed) and its own idle / walk / run thresholds ±10 %
//   variants    by uid: a runner's bounding gallop (run_b) for 40 %, a
//               brute's / boomer's heavier lumber / waddle (walk_b) for 45 %
//   pounce      the runner's leap (the core's leap state, LEAP_T) plays the
//               airborne `pounce` clip, its landing strike after touchdown
//   darting     a feint, a flight from a blast or a burning bug's panic (the
//               core's moods) plays the `skitter` dart with a nervous yaw
//               jitter on the instance (and a flinch kick on a new flight)
//   rear        a hesitation (or a long idle) plays the `rear` threat display
//   banking     roll into turns ∝ heading rate (≤ 15°) and pitch from
//               acceleration (≤ 8°), through the lean channels with the hit
//               spring
//   look        head yaw / pitch and abdomen sway angles per bug (seed, time;
//               a bit livelier when idle, the abdomen swinging out of turns):
//               Swarm.metal turns the head / abdomen groups (LOD0 / LOD1)
//   jostle      the gait phase advances by max(|forward|, 0.5 × lateral)
//               distance, and at least 0.4 × the core's velocity: a bug
//               shoved sideways in a jam keeps stepping
//  Deaths by cause and direction: Corpses picks the variant (bullet by the
//  shot's side, fire `death_burn`, frost `death_frost`, blast thrown).
//  `-swarmLegacy` (CI A/B, the owner's before / after): all of it off — one
//  tempo, one gait, no darting / rear / pounce / banking / look, phase from
//  the distance walked, random deaths without knock-back — as before.
// ================================================================

/// The clips of one creature by role (indices into IHVCreature.clips; -1 = none).
struct ClipSet {
    let idle: Int, walk: Int, run: Int, attack: Int, hit: Int
    let deaths: [Int]
    /// spitter «spit» / brute «wind» / boomer «swell».
    let special: Int
    /// brute «charge» (a locomotion clip); -1 = run.
    let charge: Int
    /// Natural speeds of walk / run (model m/s: stride / period).
    let walkSpeed: Float, runSpeed: Float
    /// native-vx-swarm-life: per-bug variants and deaths by cause (-1 = none for this type).
    let runB: Int, walkB: Int, pounce: Int, skitter: Int, rear: Int, deathBurn: Int, deathFrost: Int

    init(_ c: IHVCreature) {
        func k(_ n: String) -> Int { c.clip(n) ?? -1 }
        let w = k("walk")
        walk = w >= 0 ? w : 0
        idle = k("idle") >= 0 ? k("idle") : walk
        run = k("run") >= 0 ? k("run") : walk
        attack = k("attack")
        hit = k("hit")
        deaths = ["death", "death2", "death3"].compactMap { c.clip($0) }
        special = [k("spit"), k("wind"), k("swell")].first { $0 >= 0 } ?? -1
        charge = k("charge")
        runB = k("run_b"); walkB = k("walk_b"); pounce = k("pounce"); skitter = k("skitter"); rear = k("rear")
        deathBurn = k("death_burn"); deathFrost = k("death_frost")
        let cw = c.clips[walk], cr = c.clips[run]
        walkSpeed = cw.stride > 0 && cw.duration > 0 ? cw.stride / cw.duration : 1
        runSpeed = cr.stride > 0 && cr.duration > 0 ? cr.stride / cr.duration : 2.5
    }
}

/// A clip sampled at a time: packed rows (r0 | r1 << 16) and the lerp fraction.
struct ClipSample {
    var rows: UInt32
    var frac: Float
    static let zero = ClipSample(rows: 0, frac: 0)
}

@inline(__always) func clipLoop(_ c: IHVClip, _ u: Float) -> ClipSample {
    let n = c.frames
    let p = (u - floorf(u)) * Float(n)
    let k = min(n - 1, Int(p))
    return ClipSample(rows: UInt32(c.first + k) | UInt32(c.first + (k + 1) % n) << 16, frac: p - Float(k))
}

@inline(__always) func clipShot(_ c: IHVClip, _ t: Float) -> ClipSample {
    let n = c.frames
    let p = min(max(0, t) * c.fps, Float(n - 1))
    let k = min(n - 1, Int(p))
    return ClipSample(rows: UInt32(c.first + k) | UInt32(c.first + min(k + 1, n - 1)) << 16, frac: p - Float(k))
}

@inline(__always) func unorm16(_ x: Float) -> UInt32 { UInt32(max(0, min(1, x)) * 65535 + 0.5) }
@inline(__always) func unorm8(_ x: Float) -> UInt32 { UInt32(max(0, min(1, x)) * 255 + 0.5) }
@inline(__always) func snorm16(_ x: Float) -> UInt32 { UInt32(UInt16(bitPattern: Int16(max(-1, min(1, x)) * 32767))) }
@inline(__always) func smoothf(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

/// What the animator decided for one creature (WorldSwarm packs it into a CreatureInstance).
struct AnimOut {
    var a = ClipSample.zero
    var b = ClipSample.zero
    var wB: Float = 0
    var leanX: Float = 0, leanZ: Float = 0
    var boost: Float = 0
    /// native-vx-swarm-life: a render-only yaw offset (darting jitter), the head look (yaw, pitch) and abdomen sway
    /// angles (radians; Swarm.metal turns the head / abdomen vertex groups on LOD0 / LOD1).
    var yaw: Float = 0
    var lookY: Float = 0, lookP: Float = 0, sway: Float = 0
    /// The entry's LOD last frame (hysteresis), its table slot.
    var lodPrev: UInt8 = 255
    var slot: Int = 0
}

final class SwarmAnimator {
    static let tableSize = 8192
    /// `-swarmLegacy`: the animation as it was before native-vx-swarm-life (A/B of the same demo and seed).
    static let legacy = ProcessInfo.processInfo.arguments.contains("-swarmLegacy")
    /// Seconds of the cross-fade from the last pose (state changes, death).
    static let fade: Float = 0.15

    struct Entry {
        var uid: Int32 = -1
        var frame: UInt32 = 0
        var u: Float = 0            // shared walk / run phase (loops)
        var lastPH: Float = 0       // the core's gait odometer last frame (rad)
        var lastX: Float = 0, lastZ: Float = 0
        var spd: Float = 0          // smoothed ground speed (m/s)
        var wRun: Float = 0, wIdle: Float = 0
        var idleT: Float = 0
        var lastFlash: Float = 0
        var hitT: Float = -1, atkT: Float = -1
        var leanX: Float = 0, leanZ: Float = 0, leanVX: Float = 0, leanVZ: Float = 0
        var mode: UInt8 = 0         // 0 locomotion, 1 special (spit / wind / swell), 2 charge, 3 climb, 4 leap (pounce)
        var lod: UInt8 = 255
        var fromRows: UInt32 = 0
        var fromFrac: Float = 0
        var fromW: Float = 0
        var lastA = ClipSample.zero
        var lastB = ClipSample.zero
        var lastWB: Float = 0
        // native-vx-swarm-life
        var tempo: Float = 1, thr: Float = 1, seed: Float = 0
        var varGait = false         // run_b / walk_b instead of run / walk
        var lastHd: Float = 0, hdRate: Float = 0, accel: Float = 0, lastSpd: Float = 0
        var wSk: Float = 0          // skitter weight
        var rearT: Float = -1, pounceT: Float = -1
        var lastMood: UInt8 = 0
        var stillT: Float = 0       // seconds standing about (a bored threat display)
        var bank: Float = 0, pitch: Float = 0
    }

    let table: UnsafeMutablePointer<Entry>
    private(set) var frame: UInt32 = 0
    let sets: [ClipSet]
    let clips: [[IHVClip]]

    init(library: CreatureLibrary) {
        table = .allocate(capacity: SwarmAnimator.tableSize)
        table.initialize(repeating: Entry(), count: SwarmAnimator.tableSize)
        sets = library.types.map { ClipSet($0) }
        clips = library.types.map { $0.clips }
    }

    deinit { table.deallocate() }

    func beginFrame() { frame &+= 1 }

    /// The entry of `uid` (reset when the slot belonged to another bug or was not seen for a while).
    @inline(__always) func entry(_ uid: Int32, x: Float, z: Float, ph: Float, flash: Float) -> Int {
        let k = Int(UInt32(bitPattern: uid) & UInt32(SwarmAnimator.tableSize - 1))
        let e = table + k
        if e.pointee.uid != uid || frame &- e.pointee.frame > 3 {
            var n = Entry()
            n.uid = uid
            n.u = (ph / (2 * Float.pi)).truncatingRemainder(dividingBy: 1)
            n.lastPH = ph
            n.lastX = x; n.lastZ = z
            n.lastFlash = flash
            n.idleT = n.u * 3
            n.frame = 0
            // native-vx-swarm-life: the bug's own tempo, thresholds, gait variant and noise seed (a hash of its uid)
            let h = SwarmAnimator.hash(uid)
            let lg = SwarmAnimator.legacy
            n.tempo = lg ? 1 : 0.85 + 0.3 * h.0
            n.thr = lg ? 1 : 0.9 + 0.2 * h.1
            n.varGait = !lg && h.2 < 0.42
            n.seed = h.3
            n.lastHd = .nan
            e.pointee = n
        }
        return k
    }

    /// Four independent uniforms in [0, 1) from a uid (integer hash: the same on every platform).
    @inline(__always) static func hash(_ uid: Int32) -> (Float, Float, Float, Float) {
        var x = UInt32(bitPattern: uid) &* 0x9E37_79B9
        x ^= x >> 16; x = x &* 0x85EB_CA6B; x ^= x >> 13; x = x &* 0xC2B2_AE35; x ^= x >> 16
        @inline(__always) func b(_ k: UInt32) -> Float { Float((x >> k) & 255) / 256 }
        return (b(0), b(8), b(16), b(24))
    }

    /// The last pose of a bug seen this frame or the last (corpse fade-in); nil if unknown.
    func lastPose(uid: Int32) -> (ClipSample, UInt8)? {
        let e = table + Int(UInt32(bitPattern: uid) & UInt32(SwarmAnimator.tableSize - 1))
        guard e.pointee.uid == uid, frame &- e.pointee.frame <= 2 else { return nil }
        return (e.pointee.lastA, e.pointee.lod)
    }

    /// One live bug. `st`/`stT`: the core's state and timer; `ph`: its gait odometer; (x, z): the rendered feet;
    /// `hd`: heading; `scale`: instance scale; `flash`: hit flash 0…0.6; `frozen`; `impact`: the hit direction to use
    /// if a new hit starts (unit xz, from the shot or the nearest marine).
    /// native-vx-swarm-life: `mood` the core's wave-pacing mood (BugMood), (vx, vz) its velocity (the jostle floor and the
    /// flinch direction), `time` the world clock (look noise).
    func live(type t: Int, uid: Int32, st: UInt8, stT: Float, ph: Float, x: Float, z: Float, y: Float, hd: Float, scale: Float,
              flash: Float, frozen: Bool, dt: Float, mood: UInt8 = 0, vx: Float = 0, vz: Float = 0, time: Float = 0,
              impact: () -> (Float, Float)) -> AnimOut {
        let slot = entry(uid, x: x, z: z, ph: ph, flash: flash)
        let e = table + slot
        // a new entry, or a bug not drawn last frame (culled): no distance / bite / hit measured from stale values
        let fresh = e.pointee.frame &+ 1 != frame
        e.pointee.frame = frame
        var o = AnimOut()
        o.slot = slot
        o.lodPrev = e.pointee.lod
        if frozen || dt <= 0 {
            // ice holds the pose (and a paused world)
            o.a = e.pointee.lastA; o.b = e.pointee.lastB; o.wB = e.pointee.lastWB
            o.leanX = e.pointee.leanX + e.pointee.bank * cosf(hd) - e.pointee.pitch * sinf(hd)
            o.leanZ = e.pointee.leanZ - e.pointee.bank * sinf(hd) - e.pointee.pitch * cosf(hd)
            e.pointee.lastX = x; e.pointee.lastZ = z; e.pointee.lastPH = ph; e.pointee.lastFlash = flash; e.pointee.lastHd = hd
            return o
        }
        let cs = sets[t], cl = clips[t]
        // ---- distance walked this frame (signed: a bug pushed backward steps backward)
        var dx = x - e.pointee.lastX, dz = z - e.pointee.lastZ
        var d = (dx * dx + dz * dz).squareRoot()
        if d > 1.5 || fresh { d = 0; dx = 0; dz = 0 }
        let sh = sinf(hd), ch = cosf(hd)
        let fwd = dx * sh + dz * ch
        // jostle: a bug shoved sideways keeps stepping (max(|forward|, 0.5 × lateral)), and a bug pushing into a jam at
        // least at 0.4 × the speed it wants (the core's velocity); a backward push steps backward
        let lat = abs(dx * ch - dz * sh)
        let vInt = (vx * vx + vz * vz).squareRoot()
        var adv = max(abs(fwd), 0.5 * lat)
        if !fresh { adv = max(adv, min(0.4 * vInt * dt, 0.3)) }
        if SwarmAnimator.legacy { adv = d }
        let dist = fwd < -0.35 * d ? -adv : adv
        e.pointee.lastX = x; e.pointee.lastZ = z
        let v = d / dt
        e.pointee.spd += (v - e.pointee.spd) * min(1, dt * 10)
        let rel = e.pointee.spd / max(scale, 0.05)
        // per-bug thresholds (±10 %) and gait clips (run_b / walk_b variants)
        let thr = e.pointee.thr
        let tRun = smoothf(cs.walkSpeed * 1.15 * thr, cs.runSpeed * 0.8 * thr, rel)
        let tIdle = 1 - smoothf(0.06 * thr, 0.45 * thr, rel)
        e.pointee.wRun += (tRun - e.pointee.wRun) * min(1, dt * 6)
        e.pointee.wIdle += (tIdle - e.pointee.wIdle) * min(1, dt * 8)
        let walkC = e.pointee.varGait && cs.walkB >= 0 ? cs.walkB : cs.walk
        let runC = e.pointee.varGait && cs.runB >= 0 ? cs.runB : cs.run
        // darting (the core's feint / flight / panic): the skitter dart
        let darting = (mood == BugMood.feint.rawValue || mood == BugMood.flee.rawValue || mood == BugMood.panic.rawValue)
            && cs.skitter >= 0 && st == BugState.move.rawValue && !SwarmAnimator.legacy
        e.pointee.wSk += ((darting ? 1 : 0) - e.pointee.wSk) * min(1, dt * (darting ? 12 : 5))
        let wSk = e.pointee.wSk
        let sw = cl[walkC].stride, sr = cl[runC].stride
        var stride = max(0.05, sw + (sr - sw) * e.pointee.wRun)
        if wSk > 0.01 { stride += (max(0.05, cl[cs.skitter].stride) - stride) * wSk }
        stride *= max(scale, 0.05)
        e.pointee.idleT += dt
        // ---- the core's odometer: a bite jumps it by 1.5 rad; climbing runs on it
        let dPH = ph - e.pointee.lastPH
        e.pointee.lastPH = ph
        let climbing = st == BugState.climb.rawValue || y < -0.05
        // ---- mode by the core's state
        var mode: UInt8 = 0
        var special = ClipSample.zero
        if climbing {
            mode = 3
            e.pointee.u += max(0, min(1.5, dPH)) * 0.09
        } else if st == BugState.wind.rawValue && cs.special >= 0 && t != BugType.boomer.rawValue {
            mode = 1
            let total: Float = t == BugType.brute.rawValue ? 0.8 : 0.5
            special = clipShot(cl[cs.special], (1 - stT / total) * cl[cs.special].duration)
        } else if st == BugState.swell.rawValue && cs.special >= 0 {
            mode = 1
            special = clipShot(cl[cs.special], (1 - stT / 0.8) * cl[cs.special].duration)
        } else if st == BugState.leap.rawValue && (cs.pounce >= 0 || cs.attack >= 0) && !SwarmAnimator.legacy {
            // a runner's leap (wave pacing): the airborne pounce over the flight (to its strike frame), the strike itself
            // after touchdown (pounceT); without a pounce clip the attack lunge (package F's handoff)
            mode = 4
            let p = max(0, min(1, 1 - stT / LEAP_T))
            if cs.pounce >= 0 {
                let c = cl[cs.pounce]
                let land = c.event > 0 ? (Float(c.event) - 0.5) / c.fps : c.duration * 0.66
                special = clipShot(c, p * land)
                e.pointee.pounceT = land
            } else {
                special = clipShot(cl[cs.attack], p * cl[cs.attack].duration * 0.8)
            }
        } else if st == BugState.charge.rawValue {
            mode = 2
            let c = cs.charge >= 0 ? cs.charge : cs.run
            e.pointee.u += dist / (max(0.05, cl[c].stride) * max(scale, 0.05))
        } else {
            e.pointee.u += dist / stride * e.pointee.tempo
        }
        e.pointee.u -= floorf(e.pointee.u)
        if mode != e.pointee.mode {
            if !fresh { e.pointee.fromRows = e.pointee.lastA.rows; e.pointee.fromFrac = e.pointee.lastA.frac; e.pointee.fromW = 1 }
            e.pointee.mode = mode
        }
        e.pointee.fromW = max(0, e.pointee.fromW - dt / SwarmAnimator.fade)
        // ---- overlays: a bite (attack lunge), a hit (recoil)
        if mode == 0 {
            let bite = dPH - (e.pointee.spd * dt * 8 / max(scale, 0.05)) * 1.3 - 0.15
            if cs.attack >= 0 && bite > 1.0 && !fresh && (e.pointee.atkT < 0 || e.pointee.atkT > cl[cs.attack].duration * 0.6) {
                let c = cl[cs.attack]
                e.pointee.atkT = c.event > 0 ? max(0, Float(c.event - 3) / c.fps) : 0
            }
        }
        if flash > e.pointee.lastFlash + 0.05 {
            let hd0 = cs.hit >= 0 ? cl[cs.hit].duration : 0.3
            if e.pointee.hitT < 0 || e.pointee.hitT > hd0 * 0.4 { e.pointee.hitT = 0 }
            let (ix, iz) = impact()
            let kick: Float = t == BugType.brute.rawValue ? 1.6 : 4.2
            e.pointee.leanVX += ix * kick
            e.pointee.leanVZ += iz * kick
        }
        e.pointee.lastFlash = flash
        // a hesitation (or 2.5 s standing about) rears up in a threat display; a new flight flinches away (the blast's
        // push is in the velocity)
        if mode == 0 && cs.rear >= 0 && e.pointee.rearT < 0 && e.pointee.atkT < 0 && !fresh && !SwarmAnimator.legacy {
            let hes = mood == BugMood.hesitate.rawValue && e.pointee.lastMood != mood
            let bored = e.pointee.stillT > 2.5 + 3 * e.pointee.seed
            if hes || bored { e.pointee.rearT = 0; e.pointee.stillT = 0 }
        }
        e.pointee.stillT = e.pointee.wIdle > 0.7 ? e.pointee.stillT + dt : 0
        if mood == BugMood.flee.rawValue && e.pointee.lastMood != mood && vInt > 0.5 && !fresh && !SwarmAnimator.legacy {
            let kick: Float = 2.6 / vInt
            e.pointee.leanVX += vx * kick; e.pointee.leanVZ += vz * kick
        }
        e.pointee.lastMood = mood
        // banking: roll into the turn ∝ heading rate (≤ 15°), pitch back on acceleration / forward on braking (≤ 8°)
        if e.pointee.lastHd.isNaN || fresh { e.pointee.lastHd = hd; e.pointee.lastSpd = e.pointee.spd }
        var dh = hd - e.pointee.lastHd
        dh -= 2 * Float.pi * floorf((dh + Float.pi) / (2 * Float.pi))
        e.pointee.lastHd = hd
        e.pointee.hdRate += (max(-12, min(12, dh / dt)) - e.pointee.hdRate) * min(1, dt * 8)
        e.pointee.accel += (max(-40, min(40, (e.pointee.spd - e.pointee.lastSpd) / dt)) - e.pointee.accel) * min(1, dt * 6)
        e.pointee.lastSpd = e.pointee.spd
        let heavy: Float = t == BugType.brute.rawValue ? 0.45 : 1
        let grounded: Float = (mode == 0 || mode == 2) && !SwarmAnimator.legacy ? 1 : 0
        let bankT = max(-0.26, min(0.26, 0.075 * e.pointee.hdRate * min(1, e.pointee.spd / 1.5))) * heavy * grounded
        let pitchT = max(-0.14, min(0.14, 0.016 * e.pointee.accel)) * heavy * grounded
        e.pointee.bank += (bankT - e.pointee.bank) * min(1, dt * 10)
        e.pointee.pitch += (pitchT - e.pointee.pitch) * min(1, dt * 10)
        // the lean spring (k 160, damping 16: a quick tip and a small overshoot back)
        var lx = e.pointee.leanX, lz = e.pointee.leanZ, vx = e.pointee.leanVX, vz = e.pointee.leanVZ
        var left = min(dt, 0.1)
        while left > 0 {
            let h = min(left, 1 / 120)
            vx += (-160 * lx - 16 * vx) * h; vz += (-160 * lz - 16 * vz) * h
            lx += vx * h; lz += vz * h
            left -= h
        }
        e.pointee.leanX = lx; e.pointee.leanZ = lz; e.pointee.leanVX = vx; e.pointee.leanVZ = vz
        // world lean: the hit spring + the bank toward the turn's centre (d forward / d heading = (cos, -sin)) + the pitch
        // (top back along -forward on acceleration)
        let bk = e.pointee.bank, pt = e.pointee.pitch
        o.leanX = lx + bk * ch - pt * sh; o.leanZ = lz - bk * sh - pt * ch
        // look: head yaw / pitch noise (livelier standing or rearing) and the abdomen's sway, swinging out of turns
        if !SwarmAnimator.legacy {
            let sd = e.pointee.seed * 37.1
            let alive: Float = 1 + 0.8 * e.pointee.wIdle
            o.lookY = (0.26 * sinf(time * (1.6 + 1.4 * e.pointee.seed) + sd) + 0.12 * sinf(time * 4.3 + sd * 1.7)) * alive
            o.lookP = 0.12 * sinf(time * (2.2 + e.pointee.seed) + sd * 2.3) * alive
            o.sway = 0.13 * sinf(time * (2.0 + 0.8 * e.pointee.seed) + sd * 0.7) - 0.9 * bk
            // darting: a nervous yaw jitter on the instance
            if wSk > 0.01 { o.yaw = wSk * (0.32 * sinf(time * 11.3 + sd) + 0.14 * sinf(time * 23.7 + sd * 3.1)) }
        }
        // ---- clip A (+ the secondary locomotion clip)
        var secondary = ClipSample.zero
        var wSec: Float = 0
        switch mode {
        case 1, 4:
            o.a = special
        case 2:
            o.a = clipLoop(cl[cs.charge >= 0 ? cs.charge : cs.run], e.pointee.u)
        case 3:
            o.a = clipLoop(cl[cs.run], e.pointee.u)
        default:
            let wi = e.pointee.wIdle, wr = e.pointee.wRun
            let gait = wr < 0.5 ? walkC : runC
            let other = wr < 0.5 ? runC : walkC
            let wOther = wr < 0.5 ? wr : 1 - wr
            let idle = clipLoop(cl[cs.idle], e.pointee.idleT / max(cl[cs.idle].duration, 0.1))
            if wSk > 0.5 {
                // darting: the skitter over the gait it came from
                o.a = clipLoop(cl[cs.skitter], e.pointee.u)
                secondary = clipLoop(cl[gait], e.pointee.u); wSec = 1 - wSk
            } else if wi >= 0.5 {
                o.a = idle
                secondary = clipLoop(cl[gait], e.pointee.u); wSec = 1 - wi
            } else {
                o.a = clipLoop(cl[gait], e.pointee.u)
                if wSk > max(wi, wOther) { secondary = clipLoop(cl[cs.skitter], e.pointee.u); wSec = wSk }
                else if wi > wOther { secondary = idle; wSec = wi } else { secondary = clipLoop(cl[other], e.pointee.u); wSec = wOther }
            }
        }
        // ---- clip B: attack > pounce strike > hit > rear > transition > secondary
        var wB: Float = 0
        if mode != 4 && e.pointee.pounceT >= 0 && cs.pounce >= 0 {
            // the leap has landed: the pounce's strike to its end over whatever the bug does next
            let c = cl[cs.pounce]
            e.pointee.pounceT += dt
            if e.pointee.pounceT > c.duration || mode != 0 { e.pointee.pounceT = -1 } else {
                o.b = clipShot(c, e.pointee.pounceT)
                wB = 1 - smoothf(c.duration * 0.8, c.duration, e.pointee.pounceT)
            }
        }
        if e.pointee.atkT >= 0, cs.attack >= 0 {
            let c = cl[cs.attack]
            e.pointee.atkT += dt
            if e.pointee.atkT > c.duration { e.pointee.atkT = -1 } else if wB < 0.5 {
                o.b = clipShot(c, e.pointee.atkT)
                wB = smoothf(0, 0.06, e.pointee.atkT) * (1 - smoothf(c.duration * 0.78, c.duration, e.pointee.atkT))
            }
        }
        if e.pointee.hitT >= 0 {
            let dur = cs.hit >= 0 ? cl[cs.hit].duration : 0.3
            e.pointee.hitT += dt
            if e.pointee.hitT > dur { e.pointee.hitT = -1 } else if wB < 0.3, cs.hit >= 0 {
                o.b = clipShot(cl[cs.hit], e.pointee.hitT)
                wB = 0.9 * smoothf(0, 0.03, e.pointee.hitT) * (1 - smoothf(dur * 0.55, dur, e.pointee.hitT))
            }
        }
        if e.pointee.rearT >= 0 {
            let c = cl[cs.rear]
            e.pointee.rearT += dt
            if e.pointee.rearT > c.duration || mode != 0 { e.pointee.rearT = -1 } else if wB < 0.3 {
                o.b = clipShot(c, e.pointee.rearT)
                wB = smoothf(0, 0.1, e.pointee.rearT) * (1 - smoothf(c.duration * 0.85, c.duration, e.pointee.rearT))
            }
        }
        if wB < 0.01 {
            if e.pointee.fromW > 0 {
                o.b = ClipSample(rows: e.pointee.fromRows, frac: e.pointee.fromFrac); wB = e.pointee.fromW
            } else {
                o.b = secondary; wB = wSec
            }
        }
        o.wB = wB
        e.pointee.lastA = o.a; e.pointee.lastB = o.b; e.pointee.lastWB = wB
        return o
    }

    /// Remember the LOD a live bug was drawn with (hysteresis next frame).
    @inline(__always) func setLOD(_ slot: Int, _ lod: UInt8) { table[slot].lod = lod }

    /// A corpse `age` seconds after death: its death variant, faded in from the dying bug's last pose.
    func corpse(type t: Int, variant: Int, age: Float, from: ClipSample, hasFrom: Bool) -> AnimOut {
        var o = AnimOut()
        let cs = sets[t], cl = clips[t]
        guard !cs.deaths.isEmpty else { o.a = clipLoop(cl[cs.idle], 0); return o }
        let c = cl[deathClip(cs, variant)]
        o.a = clipShot(c, age)
        if hasFrom && age < SwarmAnimator.fade {
            o.b = from
            o.wB = 1 - age / SwarmAnimator.fade
        }
        return o
    }

    /// Duration of a type's death variant (s).
    func deathDuration(type t: Int, variant: Int) -> Float {
        let cs = sets[t]
        guard !cs.deaths.isEmpty else { return 0 }
        return clips[t][deathClip(cs, variant)].duration
    }

    /// The death clip of a corpse variant: 0…2 the type's bullet deaths (wrapping), 3 burned, 4 frozen stiff (Corpses.Cause;
    /// a type without them falls back to a bullet death).
    @inline(__always) func deathClip(_ cs: ClipSet, _ variant: Int) -> Int {
        if variant == 3 && cs.deathBurn >= 0 { return cs.deathBurn }
        if variant == 4 && cs.deathFrost >= 0 { return cs.deathFrost }
        return cs.deaths[variant % cs.deaths.count]
    }

    /// A bug-sheet specimen: clip `c` of type `t` at `time` (loops wrap, one-shots play and hold 0.8 s, then repeat).
    func sheet(type t: Int, clip c: Int, time: Float) -> AnimOut {
        var o = AnimOut()
        let k = clips[t][c]
        if k.loop { o.a = clipLoop(k, time / max(k.duration, 0.05)) } else {
            let period = k.duration + 0.8
            o.a = clipShot(k, time - floorf(time / period) * period)
        }
        return o
    }
}
