import Foundation
import IceHiveCore

// ================================================================
//  WORLD SQUAD — the four marines (owned by WP4 «Отряд»; from the web's
//  12-main.js renderMarines): interpolated feet, aim smoothing, leg
//  swing along the movement relative to the aim, body bob, gun recoil
//  and the gunner's barrel spin, the downed tilt, hurt / invulnerable
//  flashes; body, two legs and the gun of each class as instanced mesh
//  batches (MetalRenderer's batch service; they cast the flashlight
//  shadow). Also the marines' flashlight placement (the lights and the
//  shadow follow it).
// ================================================================
final class WorldSquad {
    let level: Level
    /// Interpolated feet of each marine this frame (effects, rings and lights attach here).
    private(set) var poses = [MetalEffects.MarinePose](repeating: MetalEffects.MarinePose(x: 0, y: 0, z: 0), count: 4)
    private var walkPh: [Float] = [0, 0, 0, 0]
    private var aimVis: [Float] = [0, 0, 0, 0]
    private var aimInit = false
    private var gunSpin: [Float] = [0, 0, 0, 0]
    /// [class rawValue] → body, leg, gun
    private var batches: [[MeshBatch]] = []

    init(level: Level, store: MeshStore) {
        self.level = level
        for c in MarineClass.allCases {
            batches.append(["body", "leg", "gun"].map {
                MeshBatch(mesh: store.mesh("marine_\(c.id)_\($0)"), pass: .props, roughness: 0.55, metalness: 0.5, glow: 2.2, snow: false,
                          castsShadow: true, receivesShadow: false)
            })
        }
    }

    func reset() { aimInit = false }

    /// Interpolated feet of marine k (world).
    func feet(_ k: Int) -> (Float, Float, Float) {
        k >= 0 && k < poses.count ? (poses[k].x, poses[k].y, poses[k].z) : (0, 0, 0)
    }

    /// Pose the squad for this frame (12-main.js renderMarines).
    func build(game: Game, alpha: Float, dt: Float, time: Float, rise: Float) {
        let liftOn = game.stage == .extract
        if !aimInit {
            aimInit = true
            for (k, m) in game.marines.enumerated() where k < 4 { aimVis[k] = m.aim; walkPh[k] = 0 }
        }
        for b in batches { for x in b { x.instances.removeAll(keepingCapacity: true) } }
        for (k, m) in game.marines.enumerated() where k < 4 {
            let x = m.px + (m.x - m.px) * alpha, z = m.pz + (m.z - m.pz) * alpha
            let y = level.groundY(x, z) + (liftOn && level.onLift(m.x, m.z) ? rise : 0)
            poses[k] = MetalEffects.MarinePose(x: x, y: y, z: z)
            var d = m.aim - aimVis[k]
            while d > Float.pi { d -= TAU }
            while d < -Float.pi { d += TAU }
            aimVis[k] += d * min(1, 22 * dt)
            let sp = (m.vx * m.vx + m.vz * m.vz).squareRoot()
            var rotX: Float = 0, legLx: Float = 0, legRx: Float = 0, legLz: Float = 0, legRz: Float = 0
            var bodyY: Float = 0, gunZ: Float = 0.08, oy: Float = 0
            if m.downed {
                oy = 0.28
                rotX = -1.35
                legLx = 0.2; legRx = -0.1
            } else {
                rotX = m.dashT > 0 ? 0.35 : 0
                walkPh[k] += sp * dt * 2.6
                let w = min(1, sp / 4)
                let sw = sinf(walkPh[k]) * 0.75 * w
                // legs swing along the movement direction relative to where the marine faces
                let rel = cosf(atan2f(m.vx, m.vz) - aimVis[k])
                legLx = sw * rel; legRx = -sw * rel
                legLz = sw * 0.4 * (1 - abs(rel)); legRz = -legLz
                bodyY = abs(sinf(walkPh[k])) * 0.05 * w
                gunZ = 0.08 - (m.muzzle > 0 ? 0.05 : 0) - (m.cls == .gunner && m.firing ? sinf(time * 80) * 0.015 : 0)
                if m.cls == .gunner { gunSpin[k] += m.spin * dt * 40 }
            }
            let hurt: Float = m.hurtT > 0 ? 0.7 : 0
            let inv: Float = m.inv > 0 && !m.downed && m.dashT <= 0 ? 0.12 + 0.1 * sinf(time * 20) : 0
            let em = F4(hurt, inv * 0.8, inv, 0)
            let g = Mat4.translation(x, y + oy, z) * Mat4.rotationY(aimVis[k]) * Mat4.rotationX(rotX) * Mat4.scale(1.12)
            let bt = batches[m.cls.rawValue]
            let tint = F4(1, 1, 1, 0)
            bt[0].instances.append(MeshInstance(model: g * Mat4.translation(0, bodyY, 0), tint: tint, emissive: em))
            bt[1].instances.append(MeshInstance(model: g * Mat4.translation(-0.13, 0.78, 0) * Mat4.rotationX(legLx) * Mat4.rotationZ(legLz), tint: tint, emissive: em))
            bt[1].instances.append(MeshInstance(model: g * Mat4.translation(0.13, 0.78, 0) * Mat4.rotationX(legRx) * Mat4.rotationZ(legRz), tint: tint, emissive: em))
            bt[2].instances.append(MeshInstance(model: g * Mat4.translation(0.2, 1.12, gunZ) * Mat4.rotationZ(gunSpin[k]), tint: tint, emissive: em))
        }
    }

    /// The squad's batches into the batch service.
    func upload(_ r: MetalRenderer) {
        for b in batches { for x in b where !x.instances.isEmpty { x.region = r.upload(x.instances); r.list.batches.append(x) } }
    }

    /// A marine's flashlight (renderFx): from the chest along the aim to a point 9 m ahead on the floor; a downed marine's
    /// lies on the deck pointing 2 m ahead. Returns the position and the unit direction.
    static func flashlight(_ m: Marine, _ p: MetalEffects.MarinePose) -> (F3, F3) {
        let pos: F3, target: F3
        if m.downed {
            pos = F3(p.x, p.y + 0.6, p.z)
            target = F3(p.x + m.ax * 2, p.y, p.z + m.az * 2)
        } else {
            pos = F3(p.x + m.ax * 0.3, p.y + 1.75, p.z + m.az * 0.3)
            target = F3(p.x + m.ax * 9, p.y, p.z + m.az * 9)
        }
        let d = target - pos
        return (pos, d / max(1e-4, (d * d).sum().squareRoot()))
    }
}
