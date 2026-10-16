import SpriteKit
import IceHiveCore

// ================================================================
//  BUG LAYER — the swarm from the core's struct-of-arrays.
//  Only on-screen bugs get sprites (pooled, no per-frame allocation):
//  a lit body (depth-sorted with every object), its additive glow
//  layer above the darkness and a contact shadow on the floor.
//  Status: brightness spread + burn / frost via color + colorBlendFactor;
//  the hit flash / frost sheen re-uses the glow sprite with the body frame.
//
//  Calibrated against the web swarm (store 2-swarm.png): the baked bodies
//  are lit for full light, and under the darkness multiply (ambient ≈ 0.3)
//  they went near-black — the web bugs keep maroon bodies with readable
//  legs and a carpet of pink / white glints. Bodies therefore draw through
//  one shared shader that lifts them past 1 (gain · per-type palette, the
//  web 0.55…1.3 instance spread), and the glint layer through another that
//  grows each speckle by a texel and brightens it (glints of bright bugs
//  burn to white, like the web emissive under ACES).
// ================================================================
final class BugLayer {
    let root = SKNode()
    private let assets: SpriteAssets
    private let bodies: SpritePool
    /// Glint layer (glint shader) and lit flashes (hit flash / frost sheen on the body frame, no shader) live in
    /// separate pools: a pooled sprite never switches shader, which made SpriteKit rebuild its bindings per change.
    private let glows: SpritePool
    private let lit: SpritePool
    private let shadows: SpritePool
    /// Colour last given to each pooled sprite (sprites keep their colour; set only when it changes).
    private var bodyColorSet: [SKColor?] = []
    private var glowColorSet: [SKColor?] = []
    private(set) var visibleCount = 0
    /// Ember emitter for burning bugs (world x, height, z, scale).
    var onBurning: ((Float, Float, Float, Float) -> Void)?
    private var emberRng = SeededRNG(seed: 77)
    private static let frostTint = SKColor(red: 0.25, green: 0.5, blue: 0.85, alpha: 1)
    private static let burnTint = SKColor(red: 1, green: 0.42, blue: 0.08, alpha: 1)

    /// Body gain of the shader (colours are passed as value / bodyGain so they stay ≤ 1).
    static let bodyGain: Float = 4.5
    /// Effective body brightness per type over the baked frame at the mean spread (runners / spitters / brutes are
    /// baked dark, boomers glow orange already).
    static let typeGain: [Float] = [3.4, 3.4, 3.0, 1.3]
    static let bodyShader = SKShader(source: """
    void main() {
        vec4 c = texture2D(u_texture, v_tex_coord) * v_color_mix;
        gl_FragColor = vec4(c.rgb * 4.5, c.a);
    }
    """)
    /// Glint layer: max over the texel cross (each 1–2 px speckle grows to a small blob, like the web glints at
    /// 3× resolution), times a gain; the per-bug colour carries the web brightness spread.
    private let glowShader: SKShader
    static let glintGain: Float = 2.3
    /// Bodies lean maroon under the blue-grey ambient (web bodies ≈ 41 / 26 / 28 in the dark).
    static let bodyTint: (Float, Float, Float) = (1.0, 0.86, 0.84)

    /// Healthy bodies: [type][spread 0…31]; burning / frozen: lazily filled [type][spread][burn 0…7][frost 0…7].
    private let palette: [[SKColor]]
    private var tinted = [SKColor?](repeating: nil, count: 4 * 32 * 8 * 8)
    /// Glint colour by spread (web instance colour 0.55…1.3, / 1.3).
    private let glintPalette: [SKColor]

    private static func spread(_ vr: Float) -> (Float, Float, Float) {
        let v = 0.55 + vr * 0.75
        return (v, v * (0.92 + vr * 0.1), v)
    }

    init(assets: SpriteAssets, capacity: Int) {
        self.assets = assets
        let gs = assets.sheets.pageSize(assets.sheets.sheetIndex("glow"))
        let texel = SIMD2<Float>(gs.width > 0 ? Float(1 / gs.width) : 1.0 / 4096, gs.height > 0 ? Float(1 / gs.height) : 1.0 / 2768)
        glowShader = SKShader(source: """
        void main() {
            vec2 t = v_tex_coord;
            vec4 c = texture2D(u_texture, t);
            vec4 n = max(max(texture2D(u_texture, t + vec2(u_texel.x, 0.0)), texture2D(u_texture, t - vec2(u_texel.x, 0.0))),
                         max(texture2D(u_texture, t + vec2(0.0, u_texel.y)), texture2D(u_texture, t - vec2(0.0, u_texel.y))));
            c = max(c, n * 0.4) * v_color_mix;
            vec3 g = c.rgb * u_glint;
            // what passes 1 spills into every channel: glints of bright bugs burn to white (web emissive + ACES)
            float over = max(0.0, max(g.r, max(g.g, g.b)) - 1.0);
            gl_FragColor = vec4(g + vec3(over * 0.9), c.a);
        }
        """, uniforms: [SKUniform(name: "u_texel", vectorFloat2: texel), SKUniform(name: "u_glint", float: BugLayer.glintGain)])
        palette = (0..<4).map { t in
            (0..<32).map { k in
                let c = BugLayer.spread(Float(k) / 31)
                let g = BugLayer.typeGain[t] / 0.925 / BugLayer.bodyGain
                let w = BugLayer.bodyTint
                return SKColor(red: CGFloat(min(1, c.0 * g * w.0)), green: CGFloat(min(1, c.1 * g * w.1)), blue: CGFloat(min(1, c.2 * g * w.2)), alpha: 1)
            }
        }
        glintPalette = (0..<32).map { k in
            let c = BugLayer.spread(Float(k) / 31)
            return SKColor(red: CGFloat(c.0 / 1.3), green: CGFloat(c.1 / 1.3), blue: CGFloat(c.2 / 1.3), alpha: 1)
        }
        bodies = SpritePool(parent: root, capacity: capacity) { n in
            n.colorBlendFactor = 1
            n.shader = BugLayer.bodyShader
        }
        let gsh = glowShader
        glows = SpritePool(parent: root, capacity: capacity) { n in
            n.blendMode = .add
            n.zPosition = ZBand.glow
            n.colorBlendFactor = 1
            n.shader = gsh
        }
        lit = SpritePool(parent: root, capacity: capacity) { n in
            n.blendMode = .add
            n.zPosition = ZBand.glowLit
        }
        bodyColorSet = [SKColor?](repeating: nil, count: capacity)
        glowColorSet = [SKColor?](repeating: nil, count: capacity)
        shadows = SpritePool(parent: root, capacity: capacity) { n in
            n.alpha = 0.9
            n.zPosition = ZBand.shadow
        }
    }

    /// Pre-create `n` sprites per pool behind the loading cover (a swarm reaching the screen never allocates).
    func reserve(_ n: Int) { bodies.reserve(n); glows.reserve(n); lit.reserve(n / 2); shadows.reserve(n) }

    func update(game: Game, alpha: Float, time: Float, dt: Float, visible: CGRect) {
        let S = game.bugs
        let lv = game.level
        let xs = S.xs, zs = S.zs, pxs = S.prevXs, pzs = S.prevZs, ys = S.heights, hds = S.headings, scs = S.scales
        let tys = S.types, sts = S.states, fls = S.flashes, burns = S.burnTimers, frzs = S.freezeTimers, chills = S.chills
        let stts = S.stateTimers, phs = S.gaitPhases, vrs = S.variations, dead = S.deadFlags
        let minX = visible.minX - 60, maxX = visible.maxX + 60, minY = visible.minY - 60, maxY = visible.maxY + 90
        let emberChance = 9 * dt * 0.7
        bodies.begin(); glows.begin(); lit.begin(); shadows.begin()
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
            let anchor = set.info.anchor

            body.show(tex, size: size, anchor: anchor)
            body.position = p
            // depth slice shared with the deck objects: every bug of a slice is one draw call (one sheet)
            body.zPosition = ZBand.slice(Iso.nearness(x, y, z))

            // body colour: per-bug brightness, charred while burning, icy while frozen / chilled (quantised tables)
            let vq = max(0, min(31, Int(vr * 31 + 0.5)))
            var burnK: Float = 0
            if burns[i] > 0 {
                burnK = 0.55 + 0.45 * sinf(time * 23 + Float(i) * 1.7)
                if emberRng.next() < emberChance { onBurning?(x, y + 0.35 * scs[i], z, scs[i]) }
            }
            let frost: Float = frzs[i] > 0 ? 1 : chills[i] * 0.55
            let bc = burnK == 0 && frost <= 0 ? palette[t][vq] : tint(t, vq, burnK, frost)
            let bs = bodies.used - 1
            if bodyColorSet[bs] !== bc { body.color = bc; bodyColorSet[bs] = bc }

            // glow layer / hit flash / frost sheen
            var flash = max(0, fls[i])
            if t == BugType.boomer.rawValue && st == BugState.swell.rawValue {
                let pr = 1 - stts[i] / 0.8
                flash = max(flash, (0.5 + 0.5 * sinf(time * (18 + 30 * pr))) * 0.9)
            }
            if flash > 0.04 || frost > 0.05 {
                if let l = lit.next() {
                    l.position = p
                    l.show(tex, size: size, anchor: anchor)
                    if flash > 0.04 {
                        l.colorBlendFactor = 0
                        l.alpha = CGFloat(min(1, flash * 1.4))
                    } else {
                        l.color = BugLayer.frostTint
                        l.colorBlendFactor = 1
                        l.alpha = CGFloat(frost * 0.45)
                    }
                }
            } else if let gt = set.glow(dir, frame), let glow = glows.next() {
                glow.position = p
                glow.show(gt, size: size, anchor: anchor)
                let gc = burnK > 0 ? BugLayer.burnTint : glintPalette[vq]
                let gsl = glows.used - 1
                if glowColorSet[gsl] !== gc { glow.color = gc; glowColorSet[gsl] = gc }
                let ga = CGFloat(burnK > 0 ? 0.7 + 0.3 * burnK : 1)
                if glow.alpha != ga { glow.alpha = ga }
            }

            // contact shadow on the floor (not while climbing the wall)
            if !climbing, let sh = shadows.next() {
                let ss = assets.bugShadow[t]
                if ss.frameCount > 0 {
                    sh.show(ss.tex(dir, 0), size: CGSize(width: ss.info.size.width * k, height: ss.info.size.height * k), anchor: ss.info.anchor)
                    sh.position = Iso.point(x, floorY, z)
                }
            }
        }
        bodies.end(); glows.end(); lit.end(); shadows.end()
        visibleCount = shown
    }

    var nodeCount: Int { bodies.used + glows.used + lit.used + shadows.used }

    /// Charred (burn 0…1) / icy (frost 0…1) body colour, quantised to 8 × 8 steps and cached.
    private func tint(_ t: Int, _ vq: Int, _ burn: Float, _ frost: Float) -> SKColor {
        let bq = max(0, min(7, Int(burn * 7 + 0.5))), fq = max(0, min(7, Int(frost * 7 + 0.5)))
        let k = ((t * 32 + vq) * 8 + bq) * 8 + fq
        if let c = tinted[k] { return c }
        let s = BugLayer.spread(Float(vq) / 31)
        let g = BugLayer.typeGain[t] / 0.925 / BugLayer.bodyGain
        let b = Float(bq) / 7, f = Float(fq) / 7
        let ch = 1 - b * 0.6
        let w = BugLayer.bodyTint
        let r = s.0 * g * w.0 * ch * (1 - 0.5 * f), gg = s.1 * g * w.1 * ch * (1 - 0.25 * f), bb = s.2 * g * w.2 * ch
        let c = SKColor(red: CGFloat(min(1, r)), green: CGFloat(min(1, gg)), blue: CGFloat(min(1, bb)), alpha: 1)
        tinted[k] = c
        return c
    }
}
