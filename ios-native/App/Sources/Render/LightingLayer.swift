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
    float spot(vec2 p, vec4 L, float I, float ppm, float gain) {
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
        float halo = 0.06 * exp(-dot(g, g) * 0.45);
        return I * (lit * gain + halo);
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
        vec2 wm = (u_cam.xy + (p - u_size * 0.5) * u_cam.z) / 24.0;
        float ppm = u_ppm;
        float gain = u_gain.x;
        float onStation = 0.0;
        float a = wm.x / 0.707107;
        for (int i = 0; i < 20; i++) {
            float y = 1.2 - float(i) * 0.5;
            float b = (y * 0.544639 - wm.y) / 0.593030;
            vec2 tc = (vec2((a + b) * 0.5, (b - a) * 0.5) + 64.0) / 128.0;
            vec4 m = texture2D(u_mask, tc);
            float h = m.r * 16.0 - 8.0 + m.b * u_cam.w;
            if (m.a > 0.5 && y >= h - m.g * 8.0 && y <= h + 1.25) { onStation = 1.0; break; }
        }
        if (onStation < 0.5) {
            gl_FragColor = vec4(u_bg.rgb, 1.0);
        } else {
            float s = spot(p, u_fl0, u_fli.x, ppm, gain) + spot(p, u_fl1, u_fli.y, ppm, gain)
                    + spot(p, u_fl2, u_fli.z, ppm, gain) + spot(p, u_fl3, u_fli.w, ppm, gain);
            vec3 l = u_ambient.rgb + vec3(1.0, 0.95, 0.87) * s;
            l += pt(p, u_pt0, u_pc0, ppm) + pt(p, u_pt1, u_pc1, ppm) + pt(p, u_pt2, u_pc2, ppm);
            l += pt(p, u_pt3, u_pc3, ppm) + pt(p, u_pt4, u_pc4, ppm) + pt(p, u_pt5, u_pc5, ppm);
            gl_FragColor = vec4(min(l, vec3(1.0)), 1.0);
        }
    }
    """

    let node: SKSpriteNode
    private let uSize = SKUniform(name: "u_size", vectorFloat2: SIMD2<Float>(1, 1))
    private let uPpm = SKUniform(name: "u_ppm", float: 18)
    private let uGain = SKUniform(name: "u_gain", vectorFloat4: SIMD4<Float>(1.8, 0, 0, 0))
    private let uAmbient = SKUniform(name: "u_ambient", vectorFloat4: SIMD4<Float>(0.27, 0.31, 0.42, 1))
    private let uFl: [SKUniform]
    private let uFli = SKUniform(name: "u_fli", vectorFloat4: SIMD4<Float>(0, 0, 0, 0))
    private let uPt: [SKUniform]
    private let uPc: [SKUniform]
    /// World points of the camera (xy), camera scale (z), lift rise in metres (w).
    private let uCam = SKUniform(name: "u_cam", vectorFloat4: SIMD4<Float>(0, 0, 1, 0))
    /// Light map of the abyss (background is not darkened by the station's darkness).
    private let uBg = SKUniform(name: "u_bg", vectorFloat4: SIMD4<Float>(0.8, 0.8, 0.8, 1))
    private let uMask: SKUniform

    /// Darkness level (light map outside every light) and the flashlight gain — tuning knobs.
    var ambient = SIMD4<Float>(0.30, 0.34, 0.45, 1) { didSet { uAmbient.vectorFloat4Value = ambient } }
    var gain: Float = 1.8 { didSet { uGain.vectorFloat4Value = SIMD4<Float>(gain, 0, 0, 0) } }

    /// `level` gives the floor-height mask: the shader marches each pixel's view ray through it to tell the
    /// station (darkened, lit by the flashlights) from the abyss behind it (keeps its own haze brightness).
    init(level: Level) {
        uMask = SKUniform(name: "u_mask", texture: LightingLayer.makeMask(level))
        uFl = (0..<4).map { SKUniform(name: "u_fl\($0)", vectorFloat4: SIMD4<Float>(0, 0, 0, 1)) }
        uPt = (0..<LightingLayer.maxPoints).map { SKUniform(name: "u_pt\($0)", vectorFloat4: SIMD4<Float>(0, 0, 1, 0)) }
        uPc = (0..<LightingLayer.maxPoints).map { SKUniform(name: "u_pc\($0)", vectorFloat4: SIMD4<Float>(1, 1, 1, 1)) }
        node = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
        var all: [SKUniform] = [uSize, uPpm, uGain, uAmbient, uFli, uCam, uBg, uMask]
        all.append(contentsOf: uFl)
        all.append(contentsOf: uPt)
        all.append(contentsOf: uPc)
        node.shader = SKShader(source: LightingLayer.source, uniforms: all)
        node.blendMode = .multiply
        node.zPosition = ZBand.darkness
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        uAmbient.vectorFloat4Value = ambient
        uGain.vectorFloat4Value = SIMD4<Float>(gain, 0, 0, 0)
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

    var abyss = SIMD4<Float>(0.8, 0.8, 0.8, 1) { didSet { uBg.vectorFloat4Value = abyss } }

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
