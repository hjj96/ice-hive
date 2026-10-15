import SpriteKit
import IceHiveCore

/// A dynamic light for the darkness overlay (world position, radius in metres, 0…1+ intensity, display colour).
struct PointLight {
    var x: Float, y: Float, z: Float
    var radius: Float
    var intensity: Float
    var r: Float, g: Float, b: Float
}

// ================================================================
//  LIGHTING — the game's signature look: the station sits in the
//  dark (moon + sky only, light map ≈ [0.27, 0.31, 0.42]); the four
//  marines' flashlights cut cones along their aim and blasts / muzzle
//  flashes / flames light pools. One full-screen sprite (camera child)
//  multiplies the lit world by a light map computed per pixel in an
//  SKShader. The floor under each pixel is recovered by inverting the
//  ortho projection, so cones and pools lie correctly on the deck.
//  Glow layers, particles and the HUD are drawn above it.
// ================================================================
final class LightingLayer {
    static let maxPoints = 6

    // SpriteKit passes custom uniforms to main() only: helpers take them as parameters.
    static let source = """
    vec2 gnd(vec2 d) {
        float a = d.x / 0.707107;
        float b = -d.y / 0.593030;
        return vec2((a + b) * 0.5, (b - a) * 0.5);
    }
    float spot(vec2 p, vec4 L, float I, float ppm, float gain, float halo) {
        if (I <= 0.0) { return 0.0; }
        vec2 g = gnd((p - L.xy) / ppm);
        vec2 aim = L.zw;
        vec3 v = vec3(g.x - aim.x * 0.3, -1.75, g.y - aim.y * 0.3);
        float d = length(v);
        vec3 sd = normalize(vec3(aim.x * 8.7, -1.75, aim.y * 8.7));
        float c = dot(v, sd) / d;
        float cone = smoothstep(0.8776, 0.9748, c);
        float q = d / 32.0;
        float att = clamp(1.0 - q * q * q * q, 0.0, 1.0);
        float lit = cone * (1.75 / d) * att * att / pow(d, 1.35);
        return I * (lit * gain + halo * exp(-dot(g, g) * 0.8));
    }
    vec3 pt(vec2 p, vec4 L, vec4 C, float ppm) {
        if (L.w <= 0.0) { return vec3(0.0); }
        vec2 g = gnd((p - L.xy) / ppm);
        float r = length(g) / max(L.z, 0.01);
        float f = clamp(1.0 - r, 0.0, 1.0);
        return C.rgb * (L.w * f * f);
    }
    void main() {
        vec2 p = v_tex_coord * u_size;
        vec2 wpt = u_cam.xy + (p - u_size * 0.5) * u_cam.z;
        vec2 wm = wpt / 24.0;
        float ppm = u_ppm;
        float gain = u_gain.x;
        float halo = u_gain.y;
        float onStation = 0.0;
        if (u_cam.w > 0.01) {
            // the lift is rising (extraction): march the view ray through the height mask
            float a = wm.x / 0.707107;
            for (int i = 0; i < 20; i++) {
                float y = 1.2 - float(i) * 0.5;
                float b = (y * 0.544639 - wm.y) / 0.593030;
                vec2 tc = (vec2((a + b) * 0.5, (b - a) * 0.5) + 64.0) / 128.0;
                vec4 m = texture2D(u_mask, tc);
                float h = m.r * 16.0 - 8.0 + m.b * u_cam.w;
                if (m.a > 0.5 && y >= h - m.g * 8.0 && y <= h + 1.25) { onStation = 1.0; break; }
            }
        } else {
            // the same march, precomputed once per world point (one lookup instead of up to 20)
            vec2 dt = (wpt - u_deck.xy) * u_deck.zw;
            if (dt.x > 0.0 && dt.x < 1.0 && dt.y > 0.0 && dt.y < 1.0) { onStation = texture2D(u_deckMap, dt).r; }
        }
        if (onStation < 0.004) {
            gl_FragColor = vec4(u_bg.rgb, 1.0);
        } else {
            float s = spot(p, u_fl0, u_fli.x, ppm, gain, halo) + spot(p, u_fl1, u_fli.y, ppm, gain, halo)
                    + spot(p, u_fl2, u_fli.z, ppm, gain, halo) + spot(p, u_fl3, u_fli.w, ppm, gain, halo);
            vec3 l = u_ambient.rgb + vec3(1.0, 0.95, 0.87) * s;
            l += pt(p, u_pt0, u_pc0, ppm) + pt(p, u_pt1, u_pc1, ppm) + pt(p, u_pt2, u_pc2, ppm);
            l += pt(p, u_pt3, u_pc3, ppm) + pt(p, u_pt4, u_pc4, ppm) + pt(p, u_pt5, u_pc5, ppm);
            gl_FragColor = vec4(mix(u_bg.rgb, min(l, vec3(1.0)), onStation), 1.0);
        }
    }
    """

    let node: SKSpriteNode
    private let uSize = SKUniform(name: "u_size", vectorFloat2: SIMD2<Float>(1, 1))
    private let uPpm = SKUniform(name: "u_ppm", float: 18)
    private let uGain = SKUniform(name: "u_gain", vectorFloat4: SIMD4<Float>(0.8, 0, 0, 0))
    private let uAmbient = SKUniform(name: "u_ambient", vectorFloat4: SIMD4<Float>(0.27, 0.32, 0.43, 1))
    private let uFl: [SKUniform]
    private let uFli = SKUniform(name: "u_fli", vectorFloat4: SIMD4<Float>(0, 0, 0, 0))
    private let uPt: [SKUniform]
    private let uPc: [SKUniform]
    /// World points of the camera (xy), camera scale (z), lift rise in metres (w).
    private let uCam = SKUniform(name: "u_cam", vectorFloat4: SIMD4<Float>(0, 0, 1, 0))
    /// Light map of the abyss (background is not darkened by the station's darkness).
    private let uBg = SKUniform(name: "u_bg", vectorFloat4: SIMD4<Float>(1, 1, 1, 1))
    private let uMask: SKUniform
    private let uDeckMap: SKUniform
    /// Deck map placement: world-point origin (xy) and 1 / extent (zw).
    private let uDeck: SKUniform

    /// Darkness level (light map outside every light), flashlight gain and the glow around each marine — tuning
    /// knobs, calibrated against the web game (store/screenshots/6.9/2-swarm.png and a harness shot of the same
    /// landing-pad start): unlit slab ≈ 0.27 / 0.33 / 0.42 of the pre-lit sprite, the marines themselves stay dark
    /// (their own flashlights point away), the cone floor saturates within ~6 m and fades out by ~15 m.
    var ambient = SIMD4<Float>(0.27, 0.32, 0.43, 1) { didSet { uAmbient.vectorFloat4Value = ambient } }
    var gain: Float = 0.8 { didSet { uGain.vectorFloat4Value = SIMD4<Float>(gain, halo, 0, 0) } }
    var halo: Float = 0.004 { didSet { uGain.vectorFloat4Value = SIMD4<Float>(gain, halo, 0, 0) } }

    /// `level` gives the floor-height mask: the shader marches each pixel's view ray through it to tell the
    /// station (darkened, lit by the flashlights) from the abyss behind it (keeps its own haze brightness).
    init(level: Level) {
        uMask = SKUniform(name: "u_mask", texture: LightingLayer.makeMask(level))
        let deck = LightingLayer.makeDeckMap(level)
        uDeckMap = SKUniform(name: "u_deckMap", texture: deck.0)
        uDeck = SKUniform(name: "u_deck", vectorFloat4: deck.1)
        uFl = (0..<4).map { SKUniform(name: "u_fl\($0)", vectorFloat4: SIMD4<Float>(0, 0, 0, 1)) }
        uPt = (0..<LightingLayer.maxPoints).map { SKUniform(name: "u_pt\($0)", vectorFloat4: SIMD4<Float>(0, 0, 1, 0)) }
        uPc = (0..<LightingLayer.maxPoints).map { SKUniform(name: "u_pc\($0)", vectorFloat4: SIMD4<Float>(1, 1, 1, 1)) }
        node = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
        var all: [SKUniform] = [uSize, uPpm, uGain, uAmbient, uFli, uCam, uBg, uMask, uDeckMap, uDeck]
        all.append(contentsOf: uFl)
        all.append(contentsOf: uPt)
        all.append(contentsOf: uPc)
        node.shader = SKShader(source: LightingLayer.source, uniforms: all)
        node.blendMode = .multiply
        node.zPosition = ZBand.darkness
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        uAmbient.vectorFloat4Value = ambient
        uGain.vectorFloat4Value = SIMD4<Float>(gain, halo, 0, 0)
    }

    /// RGBA8 128 × 128: r = floor height ((h + 8) / 16), g = how far the structure reaches below the deck there
    /// (skirt + girder 1.45 m, stair side walls down to the low landing) / 8, b = lift cell, a = floor.
    static func makeMask(_ level: Level) -> SKTexture {
        let G = GRID
        var bytes = [UInt8](repeating: 0, count: G * G * 4)
        var low = [Float](repeating: 0, count: G * G)
        for r in level.layout.rects {
            for j in 0..<G {
                let z = Float(j) - GRID_HALF + 0.5
                if !(z > r.z0 && z < r.z1) { continue }
                for i in 0..<G {
                    let x = Float(i) - GRID_HALF + 0.5
                    if x > r.x0 && x < r.x1 { low[j * G + i] = r.height.minHeight }
                }
            }
        }
        for c in 0..<(G * G) where level.walkValue(c) != 0 {
            let h = level.groundY(Level.cellX(c), Level.cellZ(c))
            let v = max(0, min(255, Int(((h + 8) / 16 * 255).rounded())))
            bytes[c * 4] = UInt8(v)
            let depth: Float = level.isStairCell(c) ? max(1.45, h - low[c] + 0.7) : 1.45
            bytes[c * 4 + 1] = UInt8(max(0, min(255, Int((depth / 8 * 255).rounded(.up)))))
            bytes[c * 4 + 2] = level.isLiftCell(c) ? 255 : 0
            bytes[c * 4 + 3] = 255
        }
        let t = SKTexture(data: Data(bytes), size: CGSize(width: G, height: G))
        t.filteringMode = .nearest
        return t
    }

    /// The station / abyss split per world point (4 pt texels): the shader's view-ray march over the height mask,
    /// done once on the CPU for the resting lift. R8 in an RGBA texture, linear filtering softens the deck edge.
    static func makeDeckMap(_ level: Level, cell: Float = 4) -> (SKTexture, SIMD4<Float>) {
        let t0 = ProcessInfo.processInfo.systemUptime
        let G = GRID
        var height = [Float](repeating: 0, count: G * G)
        var depth = [Float](repeating: 0, count: G * G)
        var floorCell = [Bool](repeating: false, count: G * G)
        var low = [Float](repeating: 0, count: G * G)
        for r in level.layout.rects {
            for j in 0..<G {
                let z = Float(j) - GRID_HALF + 0.5
                if !(z > r.z0 && z < r.z1) { continue }
                for i in 0..<G {
                    let x = Float(i) - GRID_HALF + 0.5
                    if x > r.x0 && x < r.x1 { low[j * G + i] = r.height.minHeight }
                }
            }
        }
        var uMin = Float.greatestFiniteMagnitude, uMax = -Float.greatestFiniteMagnitude
        var vMin = Float.greatestFiniteMagnitude, vMax = -Float.greatestFiniteMagnitude
        for c in 0..<(G * G) where level.walkValue(c) != 0 {
            let x = Level.cellX(c), z = Level.cellZ(c)
            let h = level.groundY(x, z)
            let d: Float = level.isStairCell(c) ? max(1.45, h - low[c] + 0.7) : 1.45
            floorCell[c] = true
            height[c] = h
            depth[c] = d
            let u = (x - z) * Iso.cosYaw * Iso.ppmF
            uMin = min(uMin, u - 18); uMax = max(uMax, u + 18)
            let vTop = ((h + 1.3) * Iso.cosPitch - (x + z - 1) * Iso.depthK) * Iso.ppmF
            let vBot = ((h - d - 0.2) * Iso.cosPitch - (x + z + 1) * Iso.depthK) * Iso.ppmF
            vMin = min(vMin, vBot); vMax = max(vMax, vTop)
        }
        if uMin > uMax { uMin = 0; uMax = 4; vMin = 0; vMax = 4 }
        let W = max(1, Int(((uMax - uMin) / cell).rounded(.up))), H = max(1, Int(((vMax - vMin) / cell).rounded(.up)))
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        var hits = 0
        for r in 0..<H {
            let v = (vMin + (Float(r) + 0.5) * cell) / Iso.ppmF
            for q in 0..<W {
                let u = (uMin + (Float(q) + 0.5) * cell) / Iso.ppmF
                let a = u / Iso.cosYaw
                var on = false
                for i in 0..<20 {
                    let y = 1.2 - Float(i) * 0.5
                    let b = (y * Iso.cosPitch - v) / Iso.depthK
                    let x = (a + b) * 0.5, z = (b - a) * 0.5
                    let ci = Int((x + GRID_HALF).rounded(.down)), cj = Int((z + GRID_HALF).rounded(.down))
                    if ci < 0 || cj < 0 || ci >= G || cj >= G { continue }
                    let c = cj * G + ci
                    if floorCell[c] && y >= height[c] - depth[c] && y <= height[c] + 1.25 { on = true; break }
                }
                if on {
                    let k = (r * W + q) * 4
                    bytes[k] = 255; bytes[k + 1] = 255; bytes[k + 2] = 255; bytes[k + 3] = 255
                    hits += 1
                }
            }
        }
        let tex = SKTexture(data: Data(bytes), size: CGSize(width: W, height: H))
        tex.filteringMode = .linear
        AppLog.info(String(format: "deck map %dx%d (%.0f%% station) in %.0f ms", W, H, Double(hits) * 100 / Double(W * H),
                           (ProcessInfo.processInfo.systemUptime - t0) * 1000))
        return (tex, SIMD4<Float>(uMin, vMin, 1 / (Float(W) * cell), 1 / (Float(H) * cell)))
    }

    var abyss = SIMD4<Float>(1, 1, 1, 1) { didSet { uBg.vectorFloat4Value = abyss } }

    struct Flashlight {
        var x: Float, y: Float, z: Float
        var ax: Float, az: Float
        var intensity: Float
    }

    /// `toScreen` converts world points to overlay points (origin bottom-left); `ppm` = screen points per metre.
    func update(viewSize: CGSize, ppm: CGFloat, camera: CGPoint, scale: CGFloat, liftRise: Float,
                toScreen: (CGPoint) -> CGPoint, flashlights: [Flashlight], points: [PointLight]) {
        if node.size != viewSize { node.size = viewSize }
        uCam.vectorFloat4Value = SIMD4<Float>(Float(camera.x), Float(camera.y), Float(scale), liftRise)
        uSize.vectorFloat2Value = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        uPpm.floatValue = Float(ppm)
        var inten = SIMD4<Float>(0, 0, 0, 0)
        for k in 0..<4 {
            if k < flashlights.count {
                let f = flashlights[k]
                let s = toScreen(Iso.point(f.x, f.y, f.z))
                uFl[k].vectorFloat4Value = SIMD4<Float>(Float(s.x), Float(s.y), f.ax, f.az)
                inten[k] = f.intensity
            } else {
                inten[k] = 0
            }
        }
        uFli.vectorFloat4Value = inten
        // strongest lights first
        let sorted = points.count > LightingLayer.maxPoints ? Array(points.sorted { $0.intensity > $1.intensity }.prefix(LightingLayer.maxPoints)) : points
        for k in 0..<LightingLayer.maxPoints {
            if k < sorted.count {
                let l = sorted[k]
                let s = toScreen(Iso.point(l.x, l.y, l.z))
                uPt[k].vectorFloat4Value = SIMD4<Float>(Float(s.x), Float(s.y), l.radius, l.intensity)
                uPc[k].vectorFloat4Value = SIMD4<Float>(l.r, l.g, l.b, 1)
            } else {
                uPt[k].vectorFloat4Value = SIMD4<Float>(0, 0, 1, 0)
            }
        }
    }
}
