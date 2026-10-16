import SpriteKit

// ================================================================
//  PIPELINE WARM-UP — with a cold Metal shader cache (the first
//  launch after an install or update) SpriteKit compiles a render
//  pipeline the first time it draws a new combination of blend mode,
//  texture / no texture, colour blending and alpha; on the simulator
//  each compile stalls a frame by 100–600 ms. Behind the loading
//  cover this grid draws one small sprite per combination (every
//  sheet page × every blend mode the game uses × colour blend 0 / ½ /
//  1 × opaque / translucent, plus untextured colour quads) for a few
//  frames, so the pipelines exist before the first visible frame.
// ================================================================
final class PipelineWarmup {
    let root = SKNode()
    private(set) var count = 0

    /// `textures`: the sheet pages (every game sprite is a sub-rectangle of one of them).
    init(textures: [SKTexture], viewSize: CGSize, z: CGFloat) {
        root.zPosition = z
        let blends: [SKBlendMode] = [.alpha, .add, .multiply]
        let factors: [CGFloat] = [0, 0.5, 1]
        let alphas: [CGFloat] = [1, 0.5]
        var texs: [SKTexture?] = [nil]
        for t in textures { texs.append(t) }
        let tint = SKColor(red: 0.6, green: 0.75, blue: 0.95, alpha: 1)
        let cell: CGFloat = 7
        let cols = 18
        let total = texs.count * blends.count * factors.count * alphas.count
        let rows = (total + cols - 1) / cols
        let x0 = -CGFloat(cols - 1) * cell / 2
        let y0 = CGFloat(rows - 1) * cell / 2
        // keep the grid inside the view (SpriteKit skips nodes outside it, and those would not warm anything)
        let fit = min(1, (min(viewSize.width, viewSize.height) - 20) / (CGFloat(cols) * cell))
        root.setScale(max(0.2, fit))
        var k = 0
        for tex in texs {
            for bm in blends {
                for f in factors {
                    for a in alphas {
                        let s: SKSpriteNode
                        if let t = tex {
                            s = SKSpriteNode(texture: t, color: tint, size: CGSize(width: cell - 1, height: cell - 1))
                            s.color = tint
                        } else {
                            s = SKSpriteNode(color: tint, size: CGSize(width: cell - 1, height: cell - 1))
                        }
                        s.blendMode = bm
                        s.colorBlendFactor = f
                        s.alpha = a
                        s.position = CGPoint(x: x0 + CGFloat(k % cols) * cell, y: y0 - CGFloat(k / cols) * cell)
                        root.addChild(s)
                        k += 1
                    }
                }
            }
        }
        count = k
    }
}
