import Foundation
import IceHiveCore

// ================================================================
//  MANIFOLD DECOR — the Manifold's deck pieces (Stage 2 B5; B2's kit:
//  tools/blender/kit/manifold.py; B4's layout): the pump housing — four
//  `mf_pump` quarters about its centre over B4's 4 × 4 × 2.6 m cover box
//  (its roof machinery rises to 3.24 m) — instead of a crate, and two
//  `mf_bridge_truss` under every radial bridge at the island's edge
//  (±1.4 m off the bridge's axis, +x outward along it). Built into the
//  station mesh with WorldLevel's props (its cells, its one pipeline: no
//  new draw call).
// ================================================================
enum ManifoldDecor {
    /// The crate of the layout that is the Manifold's pump housing (WorldLevel draws the pump in its place).
    static func isPump(_ c: CrateSpec, _ A: ManifoldArena) -> Bool {
        abs(c.x0 - A.pump.x) < 0.01 && abs(c.z0 - A.pump.y) < 0.01
    }

    static func build(_ L: WorldLevel, _ A: ManifoldArena) {
        let cx = (A.pump.x + A.pump.z) / 2, cz = (A.pump.y + A.pump.w) / 2
        if let p = L.piece("mf_pump") {
            let y = L.level.groundY(cx, cz)
            for k in 0..<4 { L.cell(cx, cz).place(p, at: F3(cx, y, cz), yaw: Float(k) * Float.pi / 2, caster: true) }
        }
        if let p = L.piece("mf_bridge_truss") {
            for b in A.bridges {
                let alongX = (b.z - b.x) > (b.w - b.y)
                for side: Float in [-1, 1] {
                    if alongX {
                        let out = b.x + b.z > 2 * A.center.x
                        let x = out ? b.x : b.z
                        let at = F3(x, L.level.groundY(x, (b.y + b.w) / 2), (b.y + b.w) / 2 + side * 1.4)
                        L.cell(at.x, at.z).place(p, at: at, yaw: out ? 0 : Float.pi)
                    } else {
                        let out = b.y + b.w > 2 * A.center.y
                        let z = out ? b.y : b.w
                        let at = F3((b.x + b.z) / 2 + side * 1.4, L.level.groundY((b.x + b.z) / 2, z), z)
                        L.cell(at.x, at.z).place(p, at: at, yaw: out ? -Float.pi / 2 : Float.pi / 2)
                    }
                }
            }
        }
    }
}
