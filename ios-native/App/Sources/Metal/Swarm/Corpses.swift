import Foundation
import IceHiveCore

// ================================================================
//  CORPSES — bug bodies left on the deck (owned by WP3 «Рой»; from the
//  web's addCorpse in 07-fx.js). A corpse is the dead bug itself: the
//  same creature mesh and LOD, playing one of its type's death clips
//  from the moment of death (faded in from the bug's last live pose,
//  WorldSwarm links the two by the exact death position) and held on
//  the clip's last row afterwards — no corpse-mesh swap, no pop. The
//  value band darkens and desaturates through the clip (Swarm.metal
//  fs_chitin `dead`). Two rings (small bugs, brutes) sized by the
//  quality tier; bodies on the lift deck ride up with it during the
//  extraction. WorldSwarm draws them in the swarm's own per-type × LOD
//  draws (no extra draw call); MetalEffects.bugDeath calls add() with
//  its own random sequence (two draws per body, as before: the effects
//  stay deterministic for a seed).
//  native-vx-swarm-life — deaths by cause and direction: WorldSwarm tells
//  the link how the bug died (Cause: the shot's direction, burning,
//  chilled, or thrown by a blast — its velocity), and the corpse takes
//  the matching death clip (a bullet: thrown back from the front,
//  crumpled forward from behind, rolled away from a side shot; fire:
//  `death_burn`; frost: `death_frost`, stiff; a blast: thrown and
//  spinning) and its knock-back: a slide along the hit, a blast's hop
//  and tumble through the air, a burning bug's last spin. The body keeps
//  the cause on it for a while (char and embers, a frost crust).
// ================================================================
/// How a bug died (WorldSwarm decides from the dying bug's state).
enum DeathCause: UInt8 {
    case bullet = 0, fire = 1, frost = 2, blast = 3
}

/// What the dying bug hands its corpse (WorldSwarm.buildCorpses → Corpses.link).
struct CorpseLink {
    var pose: ClipSample
    var hasPose: Bool
    var value: Float
    var lod: UInt8
    var seed: Float
    var cause: DeathCause
    /// The push (unit xz: the shot's travel, the blast's push) and its strength (m/s; the blast's knock).
    var dirX: Float, dirZ: Float
    var power: Float
}

struct CorpseRecord {
    var x: Float, y: Float, z: Float
    var heading: Float
    var scale: Float
    /// Pitch along the heading on a ramp (sin, cos).
    var pitchS: Float, pitchC: Float
    var type: UInt8
    var variant: UInt8
    /// Corpses.clock at death.
    var born: Float
    /// Albedo value of the body (the dying bug's variation once linked).
    var value: Float
    var seed: Float
    /// The dying bug's last pose (fade-in), set by WorldSwarm in the frame of death; `linked` once tried.
    var from: ClipSample
    var hasFrom: Bool
    var linked: Bool
    /// LOD the bug was drawn with when it died (255 = unknown), kept until the body has settled.
    var lod: UInt8
    var liftBaseY: Float
    // native-vx-swarm-life
    var cause: UInt8 = 0
    /// Knock-back: slide velocity (m/s), height above the deck and its vertical speed (a blast's hop), spin (rad/s).
    var vx: Float = 0, vz: Float = 0, hop: Float = 0, vy: Float = 0, spin: Float = 0
}

final class Corpses {
    /// The world's corpse store (WorldSwarm draws it): set by the newest Corpses for its level.
    private(set) static weak var active: Corpses?

    let level: Level
    /// Ring 0: runners and spitters, ring 1: brutes (boomers burst, frozen bugs shatter: no body).
    private(set) var rings: [[CorpseRecord]] = [[], []]
    private var ringSize = [320, 40]
    private var head = [0, 0]
    /// Bodies lying on the lift deck (ring, index) once the extraction starts.
    private var liftGore: [(Int, Int)]? = nil
    private var liftRiseLast: Float = 0
    /// Seconds of rendered time (WorldSwarm advances it every built frame): corpse ages.
    private(set) var clock: Float = 0
    /// Corpses added since WorldSwarm last linked them to their dying bugs (ring, index).
    private(set) var pending: [(Int, Int)] = []
    /// Bodies still sliding / tumbling (ring, index).
    private var movers: [(Int, Int)] = []

    /// `store`: kept for the world's call (the bodies are the swarm's creature meshes now).
    init(level: Level, store: MeshStore) {
        self.level = level
        for k in 0..<2 { rings[k].reserveCapacity(520) }
        pending.reserveCapacity(64)
        movers.reserveCapacity(64)
        Corpses.active = self
    }

    /// Ring sizes of the quality tier (web QUALITY corpses: low 160, med 320, high 520; brutes 1/8, at least 20).
    func setQuality(fxK k: Float) {
        let n = k < 0.5 ? 160 : (k < 0.85 ? 320 : 520)
        let cr = [n, max(20, n >> 3)]
        for k in 0..<2 where ringSize[k] != cr[k] {
            ringSize[k] = cr[k]
            head[k] = 0
            if rings[k].count > cr[k] { rings[k].removeLast(rings[k].count - cr[k]) }
        }
        pending.removeAll()
        movers.removeAll()
        liftGore = nil
    }

    func reset() {
        for k in 0..<2 { rings[k].removeAll(keepingCapacity: true); head[k] = 0 }
        liftGore = nil
        liftRiseLast = 0
        pending.removeAll()
        movers.removeAll()
    }

    func advance(_ dt: Float) {
        clock += max(0, dt)
        if dt > 0 && !movers.isEmpty { move(min(dt, 0.05)) }
    }

    /// The knock-back of the fresh bodies: a slide with friction on the deck, a hop under gravity, a spin that dies with
    /// the slide; a body stops at the deck's edge (never off a walkable cell).
    private func move(_ dt: Float) {
        var k = 0
        while k < movers.count {
            let (r, i) = movers[k]
            guard i < rings[r].count else { movers.remove(at: k); continue }
            var c = rings[r][i]
            let air = c.hop > 0 || c.vy > 0
            if air {
                c.vy -= 16 * dt
                c.hop = max(0, c.hop + c.vy * dt)
                if c.hop == 0 { c.vy = 0; c.vx *= 0.55; c.vz *= 0.55; c.spin *= 0.6 }
            }
            let nx = c.x + c.vx * dt, nz = c.z + c.vz * dt
            let cell = level.cellOf(nx, nz)
            if cell >= 0 && level.walkValue(cell) != 0 {
                c.x = nx; c.z = nz
                c.y = level.groundY(nx, nz) + (level.isStairCell(cell) ? 0.06 : 0) + 0.005
                c.liftBaseY = c.y
            } else {
                c.vx = 0; c.vz = 0
            }
            c.heading += c.spin * dt
            if !air {
                let sp = (c.vx * c.vx + c.vz * c.vz).squareRoot()
                let ns = max(0, sp - 7 * dt)
                let f = sp > 1e-4 ? ns / sp : 0
                c.vx *= f; c.vz *= f
                c.spin *= max(0, 1 - 5 * dt)
            }
            rings[r][i] = c
            if c.hop == 0 && c.vy <= 0 && c.vx * c.vx + c.vz * c.vz < 1e-4 && abs(c.spin) < 0.05 {
                movers.remove(at: k)
            } else {
                k += 1
            }
        }
    }

    /// The death variant of a cause and direction (SwarmAnimator.deathClip: 0…2 the type's bullet deaths, 3 burned,
    /// 4 frozen stiff). `front`: the push along the bug's facing (−1 = a shot in the face, +1 = from behind); `left`: the push
    /// toward the bug's own left side (the runner's flip rolls onto its left).
    static func variant(type: BugType, cause: DeathCause, front: Float, left: Float, seed: Float) -> UInt8 {
        switch cause {
        case .fire: return 3
        case .frost: return 4
        case .blast: return type == .runner ? 2 : 1
        case .bullet:
            switch type {
            case .runner:
                if front < -0.35 { return 2 }           // thrown back, spinning over
                if front > 0.35 { return 1 }            // crumpled forward onto its belly, sliding
                return left > 0 ? 0 : (seed < 0.5 ? 2 : 1)   // rolled away from the shot
            case .spitter: return front < -0.2 ? 1 : 0  // flipped back / the sac bursts, slumping
            default: return abs(front) > 0.5 ? 0 : 1    // brute: collapses forward / topples onto its side
            }
        }
    }

    /// dy/dz of the floor at (x, z) (ramps run along z).
    private func slopeZ(_ x: Float, _ z: Float) -> Float {
        (level.groundY(x, z + 0.05) - level.groundY(x, z - 0.05)) / 0.1
    }

    /// web addCorpse: the dead bug's body at its death position and heading. `rnd`: the caller's random sequence (two
    /// draws per body on a walkable cell: the death variant, the body's value until it is linked to the dying bug).
    func add(_ x: Float, _ z: Float, _ hd: Float, _ sc: Float, _ type: BugType, rnd: () -> Float) {
        let c0 = level.cellOf(x, z)
        if c0 < 0 || level.walkValue(c0) == 0 { return }
        let gz = slopeZ(x, z)
        let gy = level.groundY(x, z) + (level.isStairCell(c0) ? 0.06 : 0)
        let k = type == .brute ? 1 : 0
        let variant = UInt8(min(2, Int(rnd() * 3)))
        let v = 0.8 + rnd() * 0.4
        // pitch along the heading on a ramp (the body lies on the slope)
        let slope = atanf(gz * cosf(hd))
        // drawn at the live bug's size (WorldSwarm.sizeK: the pose handed over from the dying bug lines up)
        let r = CorpseRecord(x: x, y: gy + 0.005, z: z, heading: hd, scale: sc * WorldSwarm.sizeK[Int(type.rawValue)], pitchS: sinf(slope), pitchC: cosf(slope),
                             type: UInt8(type.rawValue), variant: variant, born: clock, value: v, seed: fmodf(abs(x * 7.13 + z * 3.71), 1),
                             from: .zero, hasFrom: false, linked: false, lod: 255, liftBaseY: gy + 0.005)
        let idx: Int
        if rings[k].count < ringSize[k] {
            rings[k].append(r)
            idx = rings[k].count - 1
        } else {
            idx = head[k]
            rings[k][idx] = r
            forgetLiftGore(k, idx)
            movers.removeAll(where: { $0.0 == k && $0.1 == idx })
            head[k] = (head[k] + 1) % ringSize[k]
        }
        pending.append((k, idx))
    }

    /// WorldSwarm, once per built frame: the dying bugs still in the core's arrays this frame (`dead` flag set, not yet
    /// compacted) give their last pose, value and LOD to the corpse born at exactly their position; corpses nobody claims
    /// start from their death clip's first row.
    func link(_ find: (Float, Float, UInt8) -> CorpseLink?) {
        if pending.isEmpty { return }
        for (k, i) in pending where i < rings[k].count && !rings[k][i].linked {
            let c = rings[k][i]
            if let L = find(c.x, c.z, c.type) {
                rings[k][i].from = L.pose
                rings[k][i].hasFrom = L.hasPose
                rings[k][i].value = L.value
                rings[k][i].lod = L.lod
                // native-vx-feel: the dying bug's variety (WorldSwarm.variety: size, tint; Swarm.metal: pattern, sheen)
                rings[k][i].seed = L.seed
                rings[k][i].scale *= WorldSwarm.variety(L.seed).size
                // native-vx-swarm-life: the death by cause and direction, and its knock-back (not under -swarmLegacy)
                if SwarmAnimator.legacy { rings[k][i].linked = true; continue }
                let ty = BugType(rawValue: Int(c.type)) ?? .runner
                let sh = sinf(c.heading), ch = cosf(c.heading)
                let front = L.dirX * sh + L.dirZ * ch, left = L.dirX * ch - L.dirZ * sh
                rings[k][i].variant = Corpses.variant(type: ty, cause: L.cause, front: front, left: left, seed: L.seed)
                rings[k][i].cause = L.cause.rawValue
                let h = SwarmAnimator.hash(Int32(bitPattern: UInt32(L.seed * 65535)))
                let sgn: Float = h.0 < 0.5 ? -1 : 1
                let heavy: Float = ty == .brute ? 0.35 : 1
                var sp: Float = 0
                switch L.cause {
                case .bullet:
                    sp = (1.1 + 0.7 * h.1) * heavy
                    rings[k][i].spin = sgn * (0.5 + 1.2 * h.2) * heavy
                case .blast:
                    sp = min(0.45 * L.power, 5.5) * heavy
                    rings[k][i].vy = min(0.32 * L.power, 4.2) * heavy
                    rings[k][i].hop = 0.01
                    rings[k][i].spin = sgn * (2.5 + 0.35 * L.power) * heavy
                case .fire:
                    sp = 0.5 + 0.5 * h.1
                    rings[k][i].spin = sgn * (1.6 + 1.6 * h.2) * heavy
                case .frost:
                    sp = 0.35 * heavy
                }
                rings[k][i].vx = L.dirX * sp
                rings[k][i].vz = L.dirZ * sp
                if sp > 0 || rings[k][i].vy > 0 { movers.append((k, i)) }
            }
            rings[k][i].linked = true
        }
        pending.removeAll(keepingCapacity: true)
    }

    /// A ring slot riding the lift was reused for a new body elsewhere: it no longer rides (the web moves it anyway).
    private func forgetLiftGore(_ ring: Int, _ i: Int) {
        if liftGore != nil { liftGore!.removeAll(where: { $0.0 == ring && $0.1 == i }) }
    }

    /// Bodies lying on the lift deck ride up with it (web fxLiftRise).
    func liftRise(_ rise: Float) {
        if rise == liftRiseLast { return }
        liftRiseLast = rise
        if liftGore == nil {
            var list: [(Int, Int)] = []
            for k in 0..<2 {
                for (i, c) in rings[k].enumerated() where level.isLiftCell(level.cellOf(c.x, c.z)) {
                    rings[k][i].liftBaseY = c.y
                    list.append((k, i))
                }
            }
            liftGore = list
        }
        for (ring, i) in liftGore ?? [] where i < rings[ring].count { rings[ring][i].y = rings[ring][i].liftBaseY + rise }
    }

    /// The world's per-frame upload call: nothing to upload — WorldSwarm writes the bodies into the swarm's draws.
    func upload(_ r: MetalRenderer) {}

    var count: Int { rings[0].count + rings[1].count }
}
