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
    /// The entry's LOD last frame (hysteresis), its table slot.
    var lodPrev: UInt8 = 255
    var slot: Int = 0
}

final class SwarmAnimator {
    static let tableSize = 8192
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
        var mode: UInt8 = 0         // 0 locomotion, 1 special (spit / wind / swell), 2 charge, 3 climb
        var lod: UInt8 = 255
        var fromRows: UInt32 = 0
        var fromFrac: Float = 0
        var fromW: Float = 0
        var lastA = ClipSample.zero
        var lastB = ClipSample.zero
        var lastWB: Float = 0
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
            e.pointee = n
        }
        return k
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
    func live(type t: Int, uid: Int32, st: UInt8, stT: Float, ph: Float, x: Float, z: Float, y: Float, hd: Float, scale: Float,
              flash: Float, frozen: Bool, dt: Float, impact: () -> (Float, Float)) -> AnimOut {
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
            o.leanX = e.pointee.leanX; o.leanZ = e.pointee.leanZ
            e.pointee.lastX = x; e.pointee.lastZ = z; e.pointee.lastPH = ph; e.pointee.lastFlash = flash
            return o
        }
        let cs = sets[t], cl = clips[t]
        // ---- distance walked this frame (signed: a bug pushed backward steps backward)
        var dx = x - e.pointee.lastX, dz = z - e.pointee.lastZ
        var d = (dx * dx + dz * dz).squareRoot()
        if d > 1.5 || fresh { d = 0; dx = 0; dz = 0 }
        let fwd = dx * sinf(hd) + dz * cosf(hd)
        let dist = fwd < -0.35 * d ? -d : d
        e.pointee.lastX = x; e.pointee.lastZ = z
        let v = d / dt
        e.pointee.spd += (v - e.pointee.spd) * min(1, dt * 10)
        let rel = e.pointee.spd / max(scale, 0.05)
        let tRun = smoothf(cs.walkSpeed * 1.15, cs.runSpeed * 0.8, rel)
        let tIdle = 1 - smoothf(0.06, 0.45, rel)
        e.pointee.wRun += (tRun - e.pointee.wRun) * min(1, dt * 6)
        e.pointee.wIdle += (tIdle - e.pointee.wIdle) * min(1, dt * 8)
        let sw = cl[cs.walk].stride, sr = cl[cs.run].stride
        let stride = max(0.05, sw + (sr - sw) * e.pointee.wRun) * max(scale, 0.05)
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
        } else if st == BugState.charge.rawValue {
            mode = 2
            let c = cs.charge >= 0 ? cs.charge : cs.run
            e.pointee.u += dist / (max(0.05, cl[c].stride) * max(scale, 0.05))
        } else {
            e.pointee.u += dist / stride
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
        o.leanX = lx; o.leanZ = lz
        // ---- clip A (+ the secondary locomotion clip)
        var secondary = ClipSample.zero
        var wSec: Float = 0
        switch mode {
        case 1:
            o.a = special
        case 2:
            o.a = clipLoop(cl[cs.charge >= 0 ? cs.charge : cs.run], e.pointee.u)
        case 3:
            o.a = clipLoop(cl[cs.run], e.pointee.u)
        default:
            let wi = e.pointee.wIdle, wr = e.pointee.wRun
            let gait = wr < 0.5 ? cs.walk : cs.run
            let other = wr < 0.5 ? cs.run : cs.walk
            let wOther = wr < 0.5 ? wr : 1 - wr
            let idle = clipLoop(cl[cs.idle], e.pointee.idleT / max(cl[cs.idle].duration, 0.1))
            if wi >= 0.5 {
                o.a = idle
                secondary = clipLoop(cl[gait], e.pointee.u); wSec = 1 - wi
            } else {
                o.a = clipLoop(cl[gait], e.pointee.u)
                if wi > wOther { secondary = idle; wSec = wi } else { secondary = clipLoop(cl[other], e.pointee.u); wSec = wOther }
            }
        }
        // ---- clip B: attack > hit > transition > secondary
        var wB: Float = 0
        if e.pointee.atkT >= 0, cs.attack >= 0 {
            let c = cl[cs.attack]
            e.pointee.atkT += dt
            if e.pointee.atkT > c.duration { e.pointee.atkT = -1 } else {
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
        let c = cl[cs.deaths[variant % cs.deaths.count]]
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
        return clips[t][cs.deaths[variant % cs.deaths.count]].duration
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
