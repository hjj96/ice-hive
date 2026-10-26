import Foundation
import Metal
import IceHiveCore

// ================================================================
//  GROUND GLYPHS (owned by WP4 «Отряд») — what the deck says about the
//  squad and the objectives, drawn as analytic shapes on deck quads
//  (Glyphs.metal), MAX-blended so overlaps (with each other, telegraphs
//  and floor glows) never add up to a white blot, transparent item 305:
//    • under each marine an HP arc in its class hue: a 300° arc open
//      behind the marine, split into pips (20 armour each), lit up to
//      the armour left, the rest a dim track; a small aim chevron just
//      outside it; the player's a little larger and brighter, with a
//      thin pale inner arc for the magazine / heat (blinking while it
//      overheats or reloads) — what the player's nameplate carried, so
//      the HUD can hide the world nameplates (`hpArcs`)
//    • a downed marine: a pulsing red ring filling white with the
//      revive progress, a cross in the middle
//    • beacons: a segmented ring (24 segments) filling with the charge,
//      in the state colour (red idle, amber charging, teal done),
//      turning slowly; the lift: 32 segments, the hold countdown
//  Replaces the web's additive team rings and progress-ring sprites
//  (`teamRings` stays empty: MetalEffects' ring draw gets nothing from
//  here any more).
// ================================================================

/// One glyph (`struct GlyphInstance` in Glyphs.metal), 64 bytes.
struct GlyphInstance {
    /// xyz centre on the deck, w = radius (m).
    var center: F4
    /// rgb colour (linear radiance), w = kind (0 HP arc, 1 revive, 2 segmented ring).
    var color: F4
    /// HP arc: x = armour fraction, y = pips, z = aim angle (rad, about +y from +z), w = 1 player.
    /// Ring: x = progress, y = segments, z = rotation (rad), w = alpha.
    var a: F4
    /// x = time, y = pulse 0…1, z = the player's magazine / heat bar 0…1 (−1: none), w = 1 blinking (overheat / reload).
    var b: F4
}

final class GroundGlyphs {
    static let pipelines: [PipelineSpec] = [.world("glyphs", "vs_glyph", "fs_glyph", .max)]
    /// The squad's armour and the player's magazine are on the deck: the HUD hides the world nameplates while this is
    /// on and shows a marine's only while it is downed / revived or just took damage (the HUD owner's switch).
    static let hpArcs = true

    let level: Level
    /// Kept for MetalEffects' ring draw (the web's additive team rings): empty — the HP arcs replace them.
    let teamRings: [SpriteInstance] = []
    private(set) var glyphs: [GlyphInstance] = []
    private var renderer: MetalRenderer?
    private var ps: MTLRenderPipelineState?
    private var region = Region()

    init(level: Level) {
        self.level = level
        glyphs.reserveCapacity(16)
    }

    /// Resolve the pipeline and register the glyph item (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        ps = r.pipeline("glyphs")
        r.register(.transparent, order: 305, "ground glyphs") { [unowned self] enc in self.encode(enc) }
    }

    /// This frame's glyphs (after the squad's poses).
    func build(game: Game, time: Float, poses: [MetalEffects.MarinePose], liftRise rise: Float) {
        glyphs.removeAll(keepingCapacity: true)
        for (k, m) in game.marines.enumerated() where k < poses.count {
            let p = poses[k]
            let y = p.y + 0.03
            if m.downed {
                let pulse = 0.5 + 0.5 * sinf(time * 6)
                glyphs.append(GlyphInstance(center: F4(p.x, y, p.z, 1.15), color: F4(1.0, 0.16, 0.1, 1),
                                            a: F4(m.revive, 0, 0, 1), b: F4(time, pulse, 0, 0)))
                continue
            }
            let c = linearRGB(m.spec.laser)
            let k2: Float = m.isPlayer ? 1.25 : 0.95
            let pips = max(3, min(10, (m.maxHp / 20).rounded()))
            glyphs.append(GlyphInstance(center: F4(p.x, y, p.z, m.isPlayer ? 0.86 : 0.76), color: F4(c.x * k2, c.y * k2, c.z * k2, 0),
                                        a: F4(max(0, min(1, m.hp / max(1, m.maxHp))), pips, m.aim, m.isPlayer ? 1 : 0),
                                        b: F4(time, 0, m.isPlayer ? max(0, min(1, m.bar)) : -1,
                                              m.isPlayer && (m.overheated || m.reloading) ? 1 : 0)))
        }
        for b in game.beacons {
            let col: F3 = b.state == 2 ? F3(0.2, 1.0, 0.82) : (b.state == 1 ? F3(1.0, 0.62, 0.12) : F3(1.0, 0.22, 0.12))
            glyphs.append(GlyphInstance(center: F4(b.x, level.groundY(b.x, b.z) + 0.04, b.z, BEACON_R), color: F4(col.x, col.y, col.z, 2),
                                        a: F4(b.state == 2 ? 1 : b.progress, 24, time * 0.15, b.state == 2 ? 0.55 : 1), b: F4(time, 0, 0, 0)))
        }
        let st = game.stage
        if st == .toLift || st == .hold || st == .extract {
            let L = level.lift
            let prog: Float = st == .hold ? 1 - game.liftT / game.liftDur : (st == .extract ? 1 : 0)
            let alpha: Float = st == .extract ? 0.45 + 0.4 * smooth01f(game.extractT / 2) : 0.55
            glyphs.append(GlyphInstance(center: F4(L.x, L.y + rise + 0.06, L.z, L.r - 0.3), color: F4(0.2, 1.0, 0.82, 2),
                                        a: F4(prog, 32, -time * 0.1, alpha), b: F4(time, 0, 0, 0)))
        }
    }

    func upload(_ r: MetalRenderer) {
        region = r.upload(glyphs)
    }

    private func encode(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer, let ps = ps, region.count > 0 else { return }
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: region.offset, index: BufferIndex.instances)
        r.drawQuads(enc, region.count)
    }
}
