import SpriteKit
import IceHiveCore

// ================================================================
//  MARINE LAYER — the squad: run / strafe / idle / dash / downed frames
//  facing the (smoothed) aim, an additive glow layer (visors, chest
//  lamps), laser sights (additive ribbons in screen space, fading
//  when nothing is hit) and the team rings under their boots.
// ================================================================
final class MarineLayer {
    let root = SKNode()
    private let assets: SpriteAssets
    private var bodies: [SKSpriteNode] = []
    private var glows: [SKSpriteNode] = []
    private var lasersNear: [SKSpriteNode] = []
    private var lasersFar: [SKSpriteNode] = []
    private let turretSight = SKSpriteNode(texture: nil)
    private var laserTex: [SKTexture] = []
    private var walkPh: [Float] = [0, 0, 0, 0]
    private var aimVis: [Float] = [0, 0, 0, 0]
    private var aimInit = false

    /// Interpolated foot positions this frame (world metres), used by the HUD, camera and lights.
    private(set) var feet: [(Float, Float, Float)] = [(0, 0, 0), (0, 0, 0), (0, 0, 0), (0, 0, 0)]
    /// Ring colour per marine (display colour of the laser).
    private(set) var laserColors: [SKColor] = []

    init(assets: SpriteAssets) {
        self.assets = assets
        for _ in 0..<4 {
            let b = SKSpriteNode(texture: nil)
            b.colorBlendFactor = 0
            root.addChild(b)
            bodies.append(b)
            let g = SKSpriteNode(texture: nil)
            g.blendMode = .add
            g.zPosition = ZBand.glow
            root.addChild(g)
            glows.append(g)
            for far in [false, true] {
                let l = SKSpriteNode(texture: nil)
                l.blendMode = .add
                l.anchorPoint = CGPoint(x: 0, y: 0.5)
                l.zPosition = ZBand.beams
                root.addChild(l)
                if far { lasersFar.append(l) } else { lasersNear.append(l) }
            }
        }
        turretSight.blendMode = .add
        turretSight.anchorPoint = CGPoint(x: 0, y: 0.5)
        turretSight.zPosition = ZBand.beams
        turretSight.texture = assets.texture("laser_turret")
        root.addChild(turretSight)
        for c in MarineClass.allCases { laserTex.append(assets.texture("laser_\(c.id)")) }
        for c in MarineClass.allCases {
            let l = Tone.linear(c.spec.laser)
            laserColors.append(Tone.color(l.0, l.1, l.2))
        }
    }

    /// Screen-space ribbon from a to b (world points), `width` in points.
    private func ribbon(_ n: SKSpriteNode, _ a: CGPoint, _ b: CGPoint, width: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        n.position = a
        n.zRotation = CGFloat(atan2(Double(dy), Double(dx)))
        n.size = CGSize(width: max(0.5, len), height: width)
    }

    func update(game: Game, alpha: Float, dt: Float, time: Float, liftRise: Float, ground: GroundFx) {
        let lv = game.level
        let extract = game.stage == .extract
        if !aimInit {
            aimInit = true
            for (k, m) in game.marines.enumerated() where k < 4 { aimVis[k] = m.aim }
        }
        for (k, m) in game.marines.enumerated() where k < 4 {
            let body = bodies[k], glow = glows[k]
            let x = m.px + (m.x - m.px) * alpha, z = m.pz + (m.z - m.pz) * alpha
            let y = lv.groundY(x, z) + (extract && lv.onLift(m.x, m.z) ? liftRise : 0)
            feet[k] = (x, y, z)
            let d = m.aim - aimVis[k]
            let diff = d.isFinite ? atan2f(sinf(d), cosf(d)) : 0
            aimVis[k] += diff * min(1, 22 * dt)
            let dir = Iso.dir16(aimVis[k])
            let ci = m.cls.rawValue
            let sp = (m.vx * m.vx + m.vz * m.vz).squareRoot()
            walkPh[k] += sp * dt * 2.6
            if walkPh[k] > 1000 { walkPh[k] -= 2 * Float.pi * 100 }

            var set: FrameSet
            var frame = 0
            if m.downed {
                set = assets.marineDowned[ci]
            } else if m.dashing {
                set = assets.marineDash[ci]
            } else if sp > 0.4 {
                let rel = cosf(atan2f(m.vx, m.vz) - aimVis[k])
                if abs(rel) < 0.5 {
                    set = assets.marineStrafe[ci]
                    frame = Iso.phaseFrame(walkPh[k], 4)
                } else {
                    set = assets.marineRun[ci]
                    frame = Iso.phaseFrame(walkPh[k], 8)
                    if rel < 0 { frame = 7 - frame }
                }
            } else {
                set = assets.marineIdle[ci]
            }
            if set.frameCount == 0 { continue }
            frame = max(0, min(set.frameCount - 1, frame))
            let tex = set.tex(dir, frame)
            let p = Iso.point(x, y, z)
            body.show(tex, size: set.info.size, anchor: set.info.anchor)
            body.position = p
            body.zPosition = ZBand.object(Iso.nearness(x, y, z)) + 1

            // emissive layer; hurt = red flash, revive invulnerability = blue blink
            glow.position = p
            if m.hurtT > 0 {
                glow.show(tex, size: set.info.size, anchor: set.info.anchor)
                glow.zPosition = ZBand.glowLit
                glow.color = SKColor(red: 1, green: 0.15, blue: 0.1, alpha: 1)
                glow.colorBlendFactor = 1
                glow.alpha = 0.55
            } else if m.invulnerable {
                glow.show(tex, size: set.info.size, anchor: set.info.anchor)
                glow.zPosition = ZBand.glowLit
                glow.color = SKColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
                glow.colorBlendFactor = 1
                glow.alpha = CGFloat(0.15 + 0.12 * sinf(time * 20))
            } else if let gt = set.glow(dir, frame) {
                glow.show(gt, size: set.info.size, anchor: set.info.anchor)
                glow.zPosition = ZBand.glow
                glow.colorBlendFactor = 0
                glow.alpha = 1
            } else {
                glow.alpha = 0
            }

            // team ring
            if !m.downed {
                let l = Tone.linear(m.spec.laser)
                let kk: Float = m.isPlayer ? 0.55 : 0.32
                ground.teamRing(x: x, y: y, z: z, diameter: m.isPlayer ? 1.9 : 1.5,
                                color: Tone.color(l.0 * kk, l.1 * kk, l.2 * kk))
            }

            // laser sight
            let near = lasersNear[k], far = lasersFar[k]
            if m.downed {
                near.isHidden = true; far.isHidden = true
            } else {
                near.isHidden = false; far.isHidden = false
                let mp = game.muzzlePosition(m)
                let mx = mp.x + (x - m.x), mz = mp.y + (z - m.z)
                let dist = game.laserLength(m)
                let hit = dist < 23.95
                let ex = mx + m.ax * dist, ez = mz + m.az * dist
                let ey = hit ? lv.groundY(ex, ez) + 0.5 : y + 0.9
                let a = Iso.point(mx, y + 1.22, mz), b = Iso.point(ex, ey, ez)
                let mid = CGPoint(x: a.x + (b.x - a.x) * 0.62, y: a.y + (b.y - a.y) * 0.62)
                let tex = laserTex[ci]
                if near.texture !== tex { near.texture = tex; far.texture = tex }
                let w = 0.44 * Iso.ppm
                ribbon(near, a, mid, width: w)
                ribbon(far, mid, b, width: w)
                let base: CGFloat = m.firing ? 1.0 : 0.62
                near.alpha = base
                far.alpha = base * (hit ? 1 : 0.3)
            }
        }
        // turret sight
        let T = game.turret
        if T.active {
            turretSight.isHidden = false
            let ax = sinf(T.angle), az = cosf(T.angle)
            let ox = T.x + ax * 0.75, oz = T.z + az * 0.75
            let ty = lv.groundY(T.x, T.z)
            let dist = game.turretLaserLength
            let ex = ox + ax * dist, ez = oz + az * dist
            ribbon(turretSight, Iso.point(ox, ty + 1.05, oz), Iso.point(ex, lv.groundY(ex, ez) + 0.6, ez), width: max(2, 0.06 * Iso.ppm))
            turretSight.alpha = 0.9
        } else {
            turretSight.isHidden = true
        }
    }

    /// Head point of a marine (nameplates).
    func head(_ k: Int, downed: Bool) -> (Float, Float, Float) {
        let f = feet[k]
        return (f.0, f.1 + (downed ? 1.3 : 2.55), f.2)
    }
}
