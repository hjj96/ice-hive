import Foundation
import IceHiveCore

// ================================================================
//  LIGHT GRID — the lights of the world frame (owned by WP2 «Свет и
//  воздух»; from the web's 03-render.js rig + renderFx updates).
//  Today the fixed rig of the web build: hemisphere sky / ground, the
//  moon, the four flashlights following each marine's aim (the
//  player's brighter; firing, hurt and downed modulate them) and three
//  point lights from the effects' light pool. Writes the light block
//  of FrameUniforms (Lighting.h reads it). WP2 replaces it with the XZ
//  light grid (≤ 32 lights, CPU binning).
// ================================================================
final class LightGrid {
    private var spotPos = [F4](repeating: .zero, count: 4), spotDir = [F4](repeating: .zero, count: 4)
    private var pointPos = [F4](repeating: .zero, count: 3), pointCol = [F4](repeating: .zero, count: 3)

    /// Fill the light block of `F` for this frame.
    func fill(_ F: inout FrameUniforms, game: Game, time: Float, poses: [MetalEffects.MarinePose], fx: MetalEffects) {
        let invPi: Float = 1 / Float.pi
        let sky = linearRGB(0x5a74a0) * (0.42 * invPi), ground = linearRGB(0x05070b) * (0.42 * invPi)
        F.hemiSky = F4(sky.x, sky.y, sky.z, 0)
        F.hemiGround = F4(ground.x, ground.y, ground.z, 0)
        let md = F3(-25, 60, 35) / (F3(-25, 60, 35) * F3(-25, 60, 35)).sum().squareRoot()
        F.moonDir = F4(md.x, md.y, md.z, 0)
        let mc = linearRGB(0x8eaade) * (0.5 * invPi)
        F.moonColor = F4(mc.x, mc.y, mc.z, 0)
        // flashlights follow the aim
        for k in 0..<4 { spotPos[k] = .zero; spotDir[k] = .zero }
        for (k, m) in game.marines.enumerated() where k < 4 {
            let (pos, dir) = WorldSquad.flashlight(m, poses[k])
            let i: Float = m.downed ? 12 * (0.6 + 0.4 * sinf(time * 9 + Float(k)))
                : (m.isPlayer ? 62 : 42) * (m.firing ? 1.12 : 1) * (m.hurtT > 0 ? 0.6 + 0.4 * sinf(time * 60) : 1)
            spotPos[k] = F4(pos.x, pos.y, pos.z, i * invPi)
            spotDir[k] = F4(dir.x, dir.y, dir.z, 0)
        }
        F.spotPos = (spotPos[0], spotPos[1], spotPos[2], spotPos[3])
        F.spotDir = (spotDir[0], spotDir[1], spotDir[2], spotDir[3])
        for k in 0..<3 {
            let l = fx.lights[k]
            pointPos[k] = .zero
            pointCol[k] = .zero
            if l.intensity > 0.01 {
                pointPos[k] = F4(l.pos.x, l.pos.y, l.pos.z, 18)
                let c = l.color * (l.intensity * invPi)
                pointCol[k] = F4(c.x, c.y, c.z, 0)
            }
        }
        F.pointPos = (pointPos[0], pointPos[1], pointPos[2])
        F.pointColor = (pointCol[0], pointCol[1], pointCol[2])
    }
}
