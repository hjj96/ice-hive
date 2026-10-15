import SpriteKit
import IceHiveCore

// ================================================================
//  BUG LAYER — the swarm from the core's struct-of-arrays.
//  Only on-screen bugs get sprites (pooled, no per-frame allocation):
//  a lit body (depth-sorted with every object), its additive glow
//  layer above the darkness and a contact shadow on the floor.
//  Status: brightness spread + burn / frost via color + colorBlendFactor;
//  the hit flash / frost sheen re-uses the glow sprite with the body frame.
// ================================================================
final class BugLayer {
    let root = SKNode()
    private let assets: SpriteAssets
    private let bodies: SpritePool
    private let glows: SpritePool
    private let shadows: SpritePool
    private(set) var visibleCount = 0
    /// Ember emitter for burning bugs (world x, height, z, scale).
    var onBurning: ((Float, Float, Float, Float) -> Void)?
    private var emberRng = SeededRNG(seed: 77)
    /// Brightness spread of healthy bugs, quantised (no colour allocation per bug per frame).
    private let palette: [SKColor] = (0..<32).map { k in
        let vr = Float(k) / 31
        let v = 0.478 + vr * 0.652
        return SKColor(red: CGFloat(min(1, v)), green: CGFloat(min(1, v * (0.92 + vr * 0.1))), blue: CGFloat(min(1, v)), alpha: 1)
    }

    init(assets: SpriteAssets, capacity: Int) {
        self.assets = assets
        bodies = SpritePool(parent: root, capacity: capacity) { n in
            n.colorBlendFactor = 1
        }
        glows = SpritePool(parent: root, capacity: capacity) { n in
            n.blendMode = .add
            n.zPosition = ZBand.glow
        }
        shadows = SpritePool(parent: root, capacity: capacity) { n in
            n.alpha = 0.9
            n.zPosition = ZBand.shadow
        }
    }

    func update(game: Game, alpha: Float, time: Float, dt: Float, visible: CGRect) {
        let S = game.bugs
        let lv = game.level
        let xs = S.xs, zs = S.zs, pxs = S.prevXs, pzs = S.prevZs, ys = S.heights, hds = S.headings, scs = S.scales
        let tys = S.types, sts = S.states, fls = S.flashes, burns = S.burnTimers, frzs = S.freezeTimers, chills = S.chills
        let stts = S.stateTimers, phs = S.gaitPhases, vrs = S.variations, dead = S.deadFlags
        let minX = visible.minX - 60, maxX = visible.maxX + 60, minY = visible.minY - 60, maxY = visible.maxY + 90
        let emberChance = 9 * dt * 0.7
        bodies.begin(); glows.begin(); shadows.begin()
        var shown = 0
        let n = S.count
        var i = 0
        while i < n {
            defer { i += 1 }
            if dead[i] != 0 { continue }
            let x = pxs[i] + (xs[i] - pxs[i]) * alpha
            let z = pzs[i] + (zs[i] - pzs[i]) * alpha
            let floorY = lv.groundY(x, z)
            let yOff = ys[i]
            let y = floorY + yOff
            let p = Iso.point(x, y, z)
            if p.x < minX || p.x > maxX || p.y < minY || p.y > maxY { continue }
            let t = Int(tys[i]), st = sts[i], vr = vrs[i]
            let dir = Iso.dir16(hds[i])
            var set = assets.bugWalk[t]
            var frame = 0
            var hScale: CGFloat = 1
            var climbing = false
            if st == BugState.climb.rawValue && yOff < -0.1 {
                climbing = true
                if yOff < -0.85 {
                    set = assets.bugClimb[t]
                    frame = Int(time * 8.9 + vr * 13) % max(1, set.frameCount)
                } else {
                    set = assets.bugCrest[t]
                    frame = Int(time * 4.5 + vr * 7) % max(1, set.frameCount)
                }
            } else if t == BugType.brute.rawValue && st == BugState.charge.rawValue {
                set = assets.bruteCharge
                frame = Int(time * 16 + vr * 7) % max(1, set.frameCount)
            } else if t == BugType.boomer.rawValue && st == BugState.swell.rawValue {
                set = assets.boomerSwell
                let prog = max(0, min(0.999, 1 - stts[i] / 0.8))
                frame = min(set.frameCount - 1, Int(prog * Float(set.frameCount)))
            } else if t == BugType.brute.rawValue && st == BugState.wind.rawValue {
                frame = 0
                hScale = 1 + CGFloat(sinf(time * 30)) * 0.05
            } else {
                frame = Iso.phaseFrame(phs[i], 8)
            }
            if set.frameCount == 0 { continue }
            frame = max(0, min(set.frameCount - 1, frame))
            guard let body = bodies.next() else { break }
            shown += 1
            let tex = set.tex(dir, frame)
            let k = CGFloat(scs[i] / assets.bugBakedScale[t])
            let size = CGSize(width: set.info.size.width * k, height: set.info.size.height * k * hScale)

            if body.texture !== tex { body.texture = tex }
            body.size = size
            body.anchorPoint = set.info.anchor
            body.position = p
            // nearness quantised to 0.5 m slices: bugs in one slice share a z, so SpriteKit can batch them by atlas page
            body.zPosition = ZBand.object((Iso.nearness(x, y, z) * 2).rounded(.down) * 0.5)

            // body colour: per-bug brightness, charred while burning, icy while frozen / chilled
            let v = 0.478 + vr * 0.652
            var r = v, g = v * (0.92 + vr * 0.1), b = v
            var burnK: Float = 0
            if burns[i] > 0 {
                burnK = 0.55 + 0.45 * sinf(time * 23 + Float(i) * 1.7)
                let c = 1 - burnK * 0.6
                r *= c; g *= c; b *= c
                if emberRng.next() < emberChance { onBurning?(x, y + 0.35 * scs[i], z, scs[i]) }
            }
            let frost: Float = frzs[i] > 0 ? 1 : chills[i] * 0.55
            if frost > 0 {
                r *= 1 - 0.5 * frost; g *= 1 - 0.25 * frost
            }
            if burnK == 0 && frost <= 0 {
                body.color = palette[max(0, min(31, Int(vr * 31 + 0.5)))]
            } else {
                body.color = SKColor(red: CGFloat(min(1, r)), green: CGFloat(min(1, g)), blue: CGFloat(min(1, b)), alpha: 1)
            }

            // glow layer / hit flash / frost sheen
            var flash = max(0, fls[i])
            if t == BugType.boomer.rawValue && st == BugState.swell.rawValue {
                let pr = 1 - stts[i] / 0.8
                flash = max(flash, (0.5 + 0.5 * sinf(time * (18 + 30 * pr))) * 0.9)
            }
            if let glow = glows.next() {
                glow.position = p
                glow.size = size
                glow.anchorPoint = set.info.anchor
                if flash > 0.04 {
                    if glow.texture !== tex { glow.texture = tex }
                    glow.colorBlendFactor = 0
                    glow.alpha = CGFloat(min(1, flash * 1.4))
                } else if frost > 0.05 {
                    if glow.texture !== tex { glow.texture = tex }
                    glow.color = SKColor(red: 0.25, green: 0.5, blue: 0.85, alpha: 1)
                    glow.colorBlendFactor = 1
                    glow.alpha = CGFloat(frost * 0.45)
                } else if let gt = set.glow(dir, frame) {
                    if glow.texture !== gt { glow.texture = gt }
                    if burnK > 0 {
                        glow.color = SKColor(red: 1, green: 0.42, blue: 0.08, alpha: 1)
                        glow.colorBlendFactor = 1
                        glow.alpha = CGFloat(0.7 + 0.3 * burnK)
                    } else {
                        glow.colorBlendFactor = 0
                        glow.alpha = 1
                    }
                } else {
                    glow.alpha = 0
                }
            }

            // contact shadow on the floor (not while climbing the wall)
            if !climbing, let sh = shadows.next() {
                let ss = assets.bugShadow[t]
                if ss.frameCount > 0 {
                    let stex = ss.tex(dir, 0)
                    if sh.texture !== stex { sh.texture = stex }
                    sh.size = CGSize(width: ss.info.size.width * k, height: ss.info.size.height * k)
                    sh.anchorPoint = ss.info.anchor
                    sh.position = Iso.point(x, floorY, z)
                }
            }
        }
        bodies.end(); glows.end(); shadows.end()
        visibleCount = shown
    }

    var nodeCount: Int { bodies.used + glows.used + shadows.used }
}
