import Foundation
import Metal
import IceHiveCore

// ================================================================
//  GROUND GLYPHS — what the deck says about the squad and the
//  objectives (owned by WP4 «Отряд»; from the web's renderFx rings):
//  team rings under the marines in their laser colour (readability
//  inside the swarm; drawn in MetalEffects' ring-sprite draw, one
//  instanced call with the telegraph rings), and the procedural
//  progress rings — beacons, the lift, revives (fs_sprite mode 1,
//  transparent item 310).
// ================================================================
final class GroundGlyphs {
    let level: Level
    /// Team rings of this frame (additive ring texture; uploaded with MetalEffects' ring sprites).
    private(set) var teamRings: [SpriteInstance] = []
    /// Beacon / lift / revive progress rings of this frame.
    private(set) var indicators: [SpriteInstance] = []
    private var renderer: MetalRenderer!
    private var psSprite: MTLRenderPipelineState?
    private var texGlow: MTLTexture!
    private var rIndicators = Region()

    init(level: Level) {
        self.level = level
        teamRings.reserveCapacity(4)
        indicators.reserveCapacity(8)
    }

    /// Resolve the sprite pipeline (MetalEffects' "sprite") and register the progress-ring item (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        psSprite = r.pipeline("sprite")
        texGlow = r.store.texture("glow")
        r.register(.transparent, order: 310, "progress rings") { [unowned self] enc in self.encode(enc) }
    }

    private func indicator(_ x: Float, _ y: Float, _ z: Float, _ r: Float, _ prog: Float, _ col: F3, _ alpha: Float) {
        indicators.append(SpriteInstance(center: F4(x, y, z, 1), axisU: F4(r, 0, 0, prog), axisV: F4(0, 0, -r, alpha), color: F4(col.x, col.y, col.z, 1)))
    }

    /// This frame's rings (after the squad's poses).
    func build(game: Game, time: Float, poses: [MetalEffects.MarinePose], liftRise rise: Float) {
        teamRings.removeAll(keepingCapacity: true)
        indicators.removeAll(keepingCapacity: true)
        // team rings under the marines (readability inside the swarm)
        for (k, m) in game.marines.enumerated() where !m.downed && k < poses.count {
            let p = poses[k]
            let s: Float = (m.isPlayer ? 1.9 : 1.5) * 0.5
            let c = linearRGB(m.spec.laser) * (m.isPlayer ? 0.55 : 0.32)
            teamRings.append(SpriteInstance(center: F4(p.x, p.y + 0.035, p.z, 0), axisU: F4(s, 0, 0, 0), axisV: F4(0, 0, -s, 0), color: F4(c.x, c.y, c.z, 1)))
        }
        // beacon progress rings
        for b in game.beacons {
            let col: F3 = b.state == 2 ? F3(0.25, 1.0, 0.85) : (b.state == 1 ? F3(1.0, 0.7, 0.15) : F3(1.0, 0.25, 0.15))
            indicator(b.x, level.groundY(b.x, b.z) + 0.04, b.z, BEACON_R, b.progress, col, b.state == 2 ? 0.5 : 1)
        }
        let st = game.stage
        if st == .toLift || st == .hold || st == .extract {
            let L = level.lift
            let prog: Float = st == .hold ? 1 - game.liftT / game.liftDur : (st == .extract ? 1 : 0)
            let alpha: Float = st == .extract ? 0.4 + 0.4 * smooth01f(game.extractT / 2) : 0.4
            indicator(L.x, L.y + rise + 0.06, L.z, L.r - 0.3, prog, F3(0.25, 1.0, 0.85), alpha)
        }
        for m in game.marines where m.downed {
            indicator(m.x, level.groundY(m.x, m.z) + 0.06, m.z, 1.5, m.revive, F3(1.0, 0.25 + m.revive * 0.6, 0.2 + m.revive * 0.6), 1)
        }
    }

    func upload(_ r: MetalRenderer) {
        rIndicators = r.upload(indicators)
    }

    private func encode(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psSprite, rIndicators.count > 0 else { return }
        let r = renderer!
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: rIndicators.offset, index: BufferIndex.instances)
        r.bindMain(enc, texGlow)
        r.drawQuads(enc, rIndicators.count)
    }
}
