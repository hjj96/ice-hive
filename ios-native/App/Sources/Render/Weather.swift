import SpriteKit
import IceHiveCore

// ================================================================
//  WEATHER — the web snowfall (points falling through a 48 × 18 × 48 m
//  box that follows the camera, drifting with the wind) and the low
//  mist banks. Both are unlit (above the darkness), pooled sprites.
// ================================================================
final class WeatherLayer {
    let root = SKNode()
    private struct Flake { var x: Float; var y: Float; var z: Float; var seed: Float }
    private var flakes: [Flake] = []
    private var mists: [Flake] = []
    private let snowPool: SpritePool
    private let mistPool: SpritePool
    private let flakeTex: SKTexture
    private let mistTex: [SKTexture]

    init(assets: SpriteAssets, snow: Int, mist: Int) {
        flakeTex = assets.texture("p_dot")
        mistTex = [assets.texture("p_mist_0"), assets.texture("p_mist_1")]
        snowPool = SpritePool(parent: root, capacity: snow) { n in
            n.zPosition = ZBand.particlesAlpha + 20
            n.color = SKColor(red: 0.86, green: 0.9, blue: 1, alpha: 1)
            n.colorBlendFactor = 1
        }
        mistPool = SpritePool(parent: root, capacity: mist) { n in
            n.zPosition = ZBand.particlesAlpha + 10
            n.color = Tone.color(0.62, 0.72, 0.84)
            n.colorBlendFactor = 1
        }
        var r = SeededRNG(seed: 2024)
        for _ in 0..<snow { flakes.append(Flake(x: r.next() * 48 - 24, y: r.next() * 18, z: r.next() * 48 - 24, seed: r.next())) }
        var m = SeededRNG(seed: 17)
        for _ in 0..<mist { mists.append(Flake(x: m.next() * 60 - 30, y: 0.4 + m.next() * 1.4, z: m.next() * 60 - 30, seed: m.next())) }
    }

    @inline(__always) private func wrap(_ v: Float, _ c: Float, _ half: Float) -> Float {
        let w = half * 2
        var d = (v - c + half).truncatingRemainder(dividingBy: w)
        if d < 0 { d += w }
        return d - half + c
    }

    func update(time: Float, cx: Float, cy: Float, cz: Float, visible: CGRect, cameraScale: CGFloat) {
        let minX = visible.minX - 20, maxX = visible.maxX + 20, minY = visible.minY - 20, maxY = visible.maxY + 20
        snowPool.begin()
        for f in flakes {
            var y = (f.y - time * (1.1 + f.seed * 0.9)).truncatingRemainder(dividingBy: 18)
            if y < 0 { y += 18 }
            y += -1 + cy
            var x = f.x + sinf(time * 0.8 + f.seed * 40) * 0.5 + time * 1.6
            var z = f.z + cosf(time * 0.6 + f.seed * 30) * 0.4 + time * 0.7
            x = wrap(x, cx, 24); z = wrap(z, cz, 24)
            let p = Iso.point(x, y, z)
            if p.x < minX || p.x > maxX || p.y < minY || p.y > maxY { continue }
            guard let n = snowPool.next() else { break }
            if n.texture !== flakeTex { n.texture = flakeTex }
            // 1…3.5 screen points like the web gl_PointSize (clamped 1…7 device pixels)
            let s = CGFloat(1.2 + f.seed * 2.3) * cameraScale
            n.size = CGSize(width: s, height: s)
            n.position = p
            n.alpha = CGFloat(0.35 + f.seed * 0.45)
        }
        snowPool.end()
        mistPool.begin()
        for (k, f) in mists.enumerated() {
            var x = f.x + time * (0.35 + f.seed * 0.3), z = f.z + time * 0.12
            x = wrap(x, cx, 30); z = wrap(z, cz, 30)
            let p = Iso.point(x, f.y + cy, z)
            let size = CGFloat(6 + f.seed * 6) * Iso.ppm
            if p.x + size < minX || p.x - size > maxX || p.y + size < minY || p.y - size > maxY { continue }
            guard let n = mistPool.next() else { break }
            let t = mistTex[k % mistTex.count]
            if n.texture !== t { n.texture = t }
            n.size = CGSize(width: size, height: size * 0.7)
            n.position = p
            n.alpha = CGFloat((0.07 + 0.05 * sinf(time * 0.3 + f.seed * 20)) * 1.4)
        }
        mistPool.end()
    }
}
