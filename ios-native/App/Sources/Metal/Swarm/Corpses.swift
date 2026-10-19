import Foundation
import IceHiveCore

// ================================================================
//  CORPSES — 3D bug bodies left on the deck (owned by WP3 «Рой»; from
//  the web's addCorpse in 07-fx.js): two ring buffers (generic body,
//  brute body) of flattened, maroon-brown instances drawn as Lambert
//  mesh batches (MetalRenderer's batch service), kept in persistent
//  per-slot buffers and copied only after a change; bodies on the lift
//  deck ride up with it during the extraction. MetalEffects.bugDeath
//  calls add() with its own random sequence, so the effects stay
//  deterministic for a seed.
// ================================================================
final class Corpses {
    let level: Level
    /// (`version` moves on every change: upload() re-copies the rings only then)
    private(set) var rings: [[MeshInstance]] = [[], []] { didSet { version &+= 1 } }
    private(set) var version = 0
    private var xz: [[Vec2]] = [[], []]
    private var ringSize = [320, 40]
    private var head = [0, 0]
    /// Bodies lying on the lift deck (ring, index, base y) once the extraction starts.
    private var liftGore: [(Int, Int, Float)]? = nil
    private var liftRiseLast: Float = 0
    private let generic: MeshBatch, brute: MeshBatch
    private let pools = [EventPool<MeshInstance>("corpses", capacity: 520), EventPool<MeshInstance>("brute corpses", capacity: 65)]

    init(level: Level, store: MeshStore) {
        self.level = level
        generic = MeshBatch(mesh: store.mesh("corpse_generic"), pass: .lambert, roughness: 0.62, metalness: 0.45, glow: 2.2, snow: false,
                            castsShadow: false, receivesShadow: true)
        brute = MeshBatch(mesh: store.mesh("corpse_brute"), pass: .lambert, roughness: 0.62, metalness: 0.45, glow: 2.2, snow: false,
                          castsShadow: false, receivesShadow: true)
        for k in 0..<2 { rings[k].reserveCapacity(520); xz[k].reserveCapacity(520) }
    }

    /// Ring sizes of the quality tier (web QUALITY corpses: low 160, med 320, high 520; brutes 1/8, at least 20).
    func setQuality(fxK k: Float) {
        let n = k < 0.5 ? 160 : (k < 0.85 ? 320 : 520)
        let cr = [n, max(20, n >> 3)]
        for k in 0..<2 where ringSize[k] != cr[k] {
            ringSize[k] = cr[k]
            head[k] = 0
            if rings[k].count > cr[k] { rings[k].removeLast(rings[k].count - cr[k]); xz[k].removeLast(xz[k].count - cr[k]) }
        }
    }

    func reset() {
        for k in 0..<2 { rings[k].removeAll(keepingCapacity: true); xz[k].removeAll(keepingCapacity: true); head[k] = 0 }
        liftGore = nil
        liftRiseLast = 0
    }

    /// dy/dz of the floor at (x, z) (ramps run along z).
    private func slopeZ(_ x: Float, _ z: Float) -> Float {
        (level.groundY(x, z + 0.05) - level.groundY(x, z - 0.05)) / 0.1
    }

    /// web addCorpse: flattened body, maroon-brown tint, 0 = generic ring, 1 = brute ring. `rnd`: the caller's random
    /// sequence (two draws per body on a walkable cell).
    func add(_ x: Float, _ z: Float, _ hd: Float, _ sc: Float, _ type: BugType, rnd: () -> Float) {
        let c0 = level.cellOf(x, z)
        if c0 < 0 || level.walkValue(c0) == 0 { return }
        let gz = slopeZ(x, z)
        let gy = level.groundY(x, z) + (level.isStairCell(c0) ? 0.06 : 0)
        let k = type == .brute ? 1 : 0
        let rot = hd + (rnd() - 0.5) * 1.2
        let c = cosf(rot) * sc, s = sinf(rot) * sc
        let m = Mat4(c0: F4(c, -s * gz, -s, 0), c1: F4(0, sc, 0, 0), c2: F4(s, c * gz, c, 0), c3: F4(x, gy + 0.01, z, 1))
        let v = 1.6 + rnd() * 0.7
        let spit = type == .spitter
        let inst = MeshInstance(model: m, tint: F4(v * (spit ? 0.85 : 1), v * (spit ? 0.95 : 0.72), v * 0.58, 0), emissive: F4(0, 0, 0, 0))
        if rings[k].count < ringSize[k] {
            rings[k].append(inst); xz[k].append(Vec2(x, z))
        } else {
            rings[k][head[k]] = inst; xz[k][head[k]] = Vec2(x, z)
            forgetLiftGore(k, head[k])
            head[k] = (head[k] + 1) % ringSize[k]
        }
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
            var list: [(Int, Int, Float)] = []
            for k in 0..<2 {
                for (i, p) in xz[k].enumerated() where level.isLiftCell(level.cellOf(p.x, p.y)) { list.append((k, i, rings[k][i].model.c3.y)) }
            }
            liftGore = list
        }
        for (ring, i, y) in liftGore ?? [] where i < rings[ring].count { rings[ring][i].model.c3.y = y + rise }
    }

    /// This frame's corpse batches (persistent buffers, copied after a change) into the batch service.
    func upload(_ r: MetalRenderer) {
        generic.region = pools[0].region(rings[0], version: version, renderer: r)
        if generic.region.count > 0 { r.list.batches.append(generic) }
        brute.region = pools[1].region(rings[1], version: version, renderer: r)
        if brute.region.count > 0 { r.list.batches.append(brute) }
    }
}
