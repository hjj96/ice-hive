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
// ================================================================
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

    /// `store`: kept for the world's call (the bodies are the swarm's creature meshes now).
    init(level: Level, store: MeshStore) {
        self.level = level
        for k in 0..<2 { rings[k].reserveCapacity(520) }
        pending.reserveCapacity(64)
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
        liftGore = nil
    }

    func reset() {
        for k in 0..<2 { rings[k].removeAll(keepingCapacity: true); head[k] = 0 }
        liftGore = nil
        liftRiseLast = 0
        pending.removeAll()
    }

    func advance(_ dt: Float) { clock += max(0, dt) }

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
        let r = CorpseRecord(x: x, y: gy + 0.005, z: z, heading: hd, scale: sc, pitchS: sinf(slope), pitchC: cosf(slope),
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
            head[k] = (head[k] + 1) % ringSize[k]
        }
        pending.append((k, idx))
    }

    /// WorldSwarm, once per built frame: the dying bugs still in the core's arrays this frame (`dead` flag set, not yet
    /// compacted) give their last pose, value and LOD to the corpse born at exactly their position; corpses nobody claims
    /// start from their death clip's first row.
    func link(_ find: (Float, Float, UInt8) -> (ClipSample, Float, UInt8)?) {
        if pending.isEmpty { return }
        for (k, i) in pending where i < rings[k].count && !rings[k][i].linked {
            let c = rings[k][i]
            if let (pose, value, lod) = find(c.x, c.z, c.type) {
                rings[k][i].from = pose
                rings[k][i].hasFrom = true
                rings[k][i].value = value
                rings[k][i].lod = lod
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
