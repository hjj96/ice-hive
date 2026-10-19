import Foundation
import Metal

// ================================================================
//  POST CHAIN — the HDR / post slot and the composite (WP1 «Кадр»;
//  shaders: Shaders/Post.metal).
//    bloom (R4–R12)  dual-Kawase from sceneHDR: prefilter (13 taps,
//                    Karis average, soft knee) into the first level,
//                    downs, tent ups added back (High: ½ res × 5 levels
//                    ≈ 0.45 ms on an iPhone 12; Efficient: ¼ × 4 ≈ 0.2)
//    composite       the first draw of FrameLoop's final pass: sharpened
//                    upscale + heat distortion (High) + bloom, scripted
//                    exposure, ACES, sRGB, 32³ LUT grade, brightness,
//                    vignette, grain, dither (≈ 0.8 / 0.6 ms at 2.96 Mpx)
//  The look (crisp neutral-cool grade, deep blacks, tight bloom, light
//  vignette and grain) is the built-in "gameplay" grade below until
//  the look-dev package ships its LUTs: Resources/Grade/<mood>.lut
//  (raw 32³ RGBA8, r fastest, 131072 bytes) and
//  Resources/Look/exposure.json ({"<mood>": EV, …}) are picked up when
//  present. Scripted exposure: mood EV + shot EV + short dips (big
//  blasts); no auto-exposure. Brightness (gamma) is the player option.
// ================================================================

/// Uniforms of every post pass (`struct PostParams` in Post.metal).
struct PostUniforms {
    /// xy = uv extent of the viewport in sceneHDR, zw = 1 / allocation size.
    var scene = F4(1, 1, 0, 0)
    /// x threshold, y knee, z intensity, w firefly clamp.
    var bloom = F4(0, 0, 0, 0)
    /// x exposure (linear), y vignette, z grain, w brightness gamma.
    var grade = F4(1, 0, 0, 1)
    /// x time, y frame index, z sharpen, w distortion strength.
    var misc = F4(0, 0, 0, 0)
    /// bloom passes: xy = source texel (uv); prefilter zw = destination texel (uv); up z = coarse-level weight.
    var pass = F4(0, 0, 0, 0)
}

final class PostChain {
    let device: MTLDevice
    private var psPrefilter: MTLRenderPipelineState?, psDown: MTLRenderPipelineState?, psUp: MTLRenderPipelineState?
    /// [0] High (distortion), [1] Efficient.
    private var psComposite: [MTLRenderPipelineState?] = [nil, nil]
    private let bloomPass = MTLRenderPassDescriptor()
    private var lut: MTLTexture?
    private var black: MTLTexture?
    private var neutralDistortion: MTLTexture?
    private var luts: [String: MTLTexture] = [:]
    private var moodEV: [String: Float] = [:]
    private(set) var mood = "gameplay"
    private(set) var errors: [String] = []

    // ---- the look (crisp: tight bloom, light vignette, light grain)
    var bloomThreshold: Float = 0.8
    var bloomKnee: Float = 0.5
    var bloomStrength: Float = 0.3
    var bloomFireflyClamp: Float = 24
    /// Weight of each coarser bloom level on the way up (1 = the classic wide dual-Kawase sum; lower = tighter).
    var bloomFalloff: Float = 0.6
    var vignette: Float = 0.2
    var grain: Float = 0.016
    var sharpen: Float = 0.35
    var distortionStrength: Float = 0.02

    // ---- scripted exposure
    /// EV of the current shot (cinematics / look-dev), on top of the mood's EV.
    var shotEV: Float = 0
    private var dipEV: Float = 0
    private var dipPeak: Float = 0
    private var dipLeft: Float = 0
    private var dipDur: Float = 1
    private var lastNow: Double = 0
    /// Player brightness (gamma on the graded image): 1 = off; 1.1–1.4 lifts the darks for dim screens / outdoors.
    var brightness: Float = 1
    private var frameIndex: Float = 0
    /// The world's bloom ran this frame (else the composite binds black).
    private var bloomReady = false
    private var bloomStart = 0

    init(device: MTLDevice) {
        self.device = device
        bloomPass.colorAttachments[0].loadAction = .dontCare
        bloomPass.colorAttachments[0].storeAction = .store
        // look-dev launch options (CI shots, store shots): `-brightness G` (the player option's gamma, 0.5…2),
        // `-exposure EV` (a shot EV on top of the mood's, −4…4)
        let a = LaunchOptions.current.unknown
        func value(_ k: String) -> Float? { a.firstIndex(of: k).flatMap { i in i + 1 < a.count ? Float(a[i + 1]) : nil } }
        if let g = value("-brightness") { brightness = min(max(g, 0.5), 2) }
        if let ev = value("-exposure") { shotEV = min(max(ev, -4), 4) }
    }

    /// The mood's EV (Look/exposure.json, else 0) + the shot + the running dip.
    var exposureEV: Float { (moodEV[mood] ?? 0) + shotEV + dipEV }

    /// Switch the grade / exposure mood ("gameplay", "beacon", "extraction", "title"); unknown moods keep the
    /// built-in gameplay grade.
    func setMood(_ m: String) {
        mood = m
        lut = luts[m] ?? luts["gameplay"]
    }

    /// A short exposure dip (flash adaptation after a big blast): `ev` below the current exposure, easing back over
    /// `duration` seconds of wall time.
    func dip(ev: Float, duration: Float) {
        if ev > dipEV { return }
        dipPeak = ev
        dipEV = ev
        dipDur = max(0.05, duration)
        dipLeft = dipDur
    }

    // ---------------------------------------------------------------- setup
    /// Pipeline descriptors of the post passes (the renderer compiles them with the world's, in parallel).
    func pipelineJobs(_ lib: MTLLibrary, drawableFormat: MTLPixelFormat) -> [(String, () throws -> MTLRenderPipelineState)] {
        func desc(_ label: String, _ fs: @escaping () -> MTLFunction?, _ format: MTLPixelFormat, additive: Bool) -> (() throws -> MTLRenderPipelineState) {
            return { [device] in
                guard let v = lib.makeFunction(name: "vs_post"), let f = fs() else {
                    throw NSError(domain: "post", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(label): missing function"])
                }
                let d = MTLRenderPipelineDescriptor()
                d.label = label
                d.vertexFunction = v
                d.fragmentFunction = f
                let c = d.colorAttachments[0]!
                c.pixelFormat = format
                if additive {
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .one
                    c.destinationRGBBlendFactor = .one
                    c.sourceAlphaBlendFactor = .one
                    c.destinationAlphaBlendFactor = .one
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
        }
        func composite(_ high: Bool) -> MTLFunction? { FunctionConstant.function(lib, "fs_composite", tier: high ? .high : .efficient) }
        let hdr = RenderTargets.colorFormat
        return [
            // (the function-constant specialisations compile inside the parallel jobs too)
            ("bloomPrefilter", desc("bloomPrefilter", { lib.makeFunction(name: "fs_bloom_prefilter") }, hdr, additive: false)),
            ("bloomDown", desc("bloomDown", { lib.makeFunction(name: "fs_bloom_down") }, hdr, additive: false)),
            ("bloomUp", desc("bloomUp", { lib.makeFunction(name: "fs_bloom_up") }, hdr, additive: true)),
            ("composite.high", desc("composite.high", { composite(true) }, drawableFormat, additive: false)),
            ("composite.efficient", desc("composite.efficient", { composite(false) }, drawableFormat, additive: false)),
        ]
    }

    /// Take the compiled states (by job label).
    func bind(_ states: [String: MTLRenderPipelineState]) {
        psPrefilter = states["bloomPrefilter"]; psDown = states["bloomDown"]; psUp = states["bloomUp"]
        psComposite = [states["composite.high"], states["composite.efficient"]]
    }

    /// The composite exists for at least one tier (the frame cannot be shown without it).
    var ready: Bool { psComposite[0] != nil || psComposite[1] != nil }

    /// Textures: grade LUTs (bundle files, else the built-in grade), the exposure table, 1 × 1 fallbacks. Off the main
    /// thread at preload.
    func loadResources() -> String {
        let t0 = FrameTimer.now()
        black = makeTexture2D(width: 1, height: 1, format: .rg11b10Float, bytes: [UInt8](repeating: 0, count: 4), bpr: 4)
        neutralDistortion = makeTexture2D(width: 1, height: 1, format: .rgba8Unorm, bytes: [128, 128, 0, 255], bpr: 4)
        var files: [String] = []
        for m in ["gameplay", "beacon", "extraction", "title"] {
            if let u = Bundle.main.url(forResource: m, withExtension: "lut", subdirectory: "Grade") ?? Bundle.main.url(forResource: m, withExtension: "lut"),
               let d = try? Data(contentsOf: u), d.count == 32 * 32 * 32 * 4, let t = makeLUT(Array(d)) {
                luts[m] = t
                files.append(m)
            }
        }
        if luts["gameplay"] == nil, let t = makeLUT(PostChain.builtInGrade()) { luts["gameplay"] = t }
        if let u = Bundle.main.url(forResource: "exposure", withExtension: "json", subdirectory: "Look") ?? Bundle.main.url(forResource: "exposure", withExtension: "json"),
           let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in j { if let n = v as? NSNumber { moodEV[k] = n.floatValue } }
        }
        setMood("gameplay")
        return "post: grade LUTs " + (files.isEmpty ? "built-in" : files.joined(separator: "/")) + ", exposure table "
            + (moodEV.isEmpty ? "none" : "\(moodEV.count) moods")
            + (shotEV != 0 || brightness != 1 ? String(format: ", shot EV %+.2f brightness %.2f", shotEV, brightness) : "")
            + String(format: " in %.0f ms", (FrameTimer.now() - t0) * 1000)
    }

    private func makeTexture2D(width: Int, height: Int, format: MTLPixelFormat, bytes: [UInt8], bpr: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bpr) }
        return t
    }

    private func makeLUT(_ px: [UInt8]) -> MTLTexture? {
        let n = 32
        guard px.count == n * n * n * 4 else { return nil }
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = n; d.height = n; d.depth = n
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        px.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                      bytesPerRow: n * 4, bytesPerImage: n * n * 4)
        }
        t.label = "grade LUT"
        return t
    }

    // ---------------------------------------------------------------- the built-in grade
    /// The "gameplay" grade on display-referred (sRGB) values: crisp's neutral-cool image with horror's deep blacks —
    /// a soft toe that sinks only the near-blacks (below ~4 %) and keeps the low mid-tones (dark chitin on a dark deck)
    /// apart, a gentle S-curve, cool shadows / neutral-warm highlights, a little more colour from the mid-tones up (one
    /// hue per class stays saturated) and a little less in the deep shadows.
    static func grade(_ c: F3) -> F3 {
        func luma(_ v: F3) -> Float { v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722 }
        // toe: x − 0.03 · (1 − smoothstep(0, 0.3, x)) — 10/255 → ~3, 26 → 17, 51 → 44, ≥ 77 untouched
        func toe(_ v: Float) -> Float { max(0, v - 0.03 * (1 - smooth01f(v / 0.3))) }
        var x = F3(toe(c.x), toe(c.y), toe(c.z))
        // S-curve around the mid-tones (smoothstep blend 22 %)
        func s(_ v: Float) -> Float { let t = min(max(v, 0), 1); return t + (t * t * (3 - 2 * t) - t) * 0.22 }
        x = F3(s(x.x), s(x.y), s(x.z))
        // saturation by luminance: 0.9 in the deep shadows → 1.06 from the mid-tones up
        let l = luma(x)
        let sat = 0.9 + (1.06 - 0.9) * smooth01f((l - 0.04) / 0.3)
        x = F3(repeating: l) + (x - F3(repeating: l)) * sat
        // split tone: cool (blue-teal) shadows, neutral-warm highlights
        let sh = 1 - smooth01f(l / 0.45), hl = smooth01f((l - 0.55) / 0.45)
        x += F3(-0.006, 0.001, 0.008) * sh + F3(0.010, 0.004, -0.008) * hl
        return F3(min(max(x.x, 0), 1), min(max(x.y, 0), 1), min(max(x.z, 0), 1))
    }

    /// The built-in grade as a 32³ RGBA8 LUT (r fastest, then g, then b).
    static func builtInGrade() -> [UInt8] {
        let n = 32
        var px = [UInt8](repeating: 255, count: n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let c = grade(F3(Float(r), Float(g), Float(b)) / Float(n - 1))
                    let i = ((b * n + g) * n + r) * 4
                    px[i] = UInt8((c.x * 255).rounded()); px[i + 1] = UInt8((c.y * 255).rounded()); px[i + 2] = UInt8((c.z * 255).rounded())
                }
            }
        }
        return px
    }

    /// The display value a linear radiance `lin` ends up at with the composite's curve (exposure 1, before the grade):
    /// for picking fog / clear colours by their on-screen value.
    static func display(_ lin: F3) -> F3 {
        // three.js ACESFilmicToneMapping (Post.metal acesFilmic) + sRGB
        let a = lin / 0.6
        let m1 = F3(0.59719 * a.x + 0.35458 * a.y + 0.04823 * a.z, 0.07600 * a.x + 0.90834 * a.y + 0.01566 * a.z,
                    0.02840 * a.x + 0.13383 * a.y + 0.83777 * a.z)
        let num = m1 * (m1 + F3(repeating: 0.0245786)) - F3(repeating: 0.000090537)
        let den = m1 * (m1 * 0.983729 + F3(repeating: 0.4329510)) + F3(repeating: 0.238081)
        let r = num / den
        let o = F3(1.60475 * r.x - 0.53108 * r.y - 0.07367 * r.z, -0.10208 * r.x + 1.10813 * r.y - 0.00605 * r.z,
                   -0.00327 * r.x - 0.07276 * r.y + 1.07602 * r.z)
        func srgb(_ v: Float) -> Float { let c = min(max(v, 0), 1); return c <= 0.0031308 ? c * 12.92 : powf(c, 1 / 2.4) * 1.055 - 0.055 }
        return F3(srgb(o.x), srgb(o.y), srgb(o.z))
    }

    /// The linear radiance that shows as display value `d` (inverse of display(), per-channel Newton steps).
    static func radiance(forDisplay d: F3) -> F3 {
        var x = F3(repeating: 0.05)
        for _ in 0..<40 {
            let y = display(x)
            let e: Float = 1e-4
            let dy = (display(x + F3(repeating: e)) - y) / e
            x += (d - y) / F3(max(dy.x, 1e-3), max(dy.y, 1e-3), max(dy.z, 1e-3))
            x = F3(max(x.x, 0), max(x.y, 0), max(x.z, 0))
        }
        return x
    }

    // ---------------------------------------------------------------- per frame
    private func uniforms(_ t: RenderTargets, time: Float) -> PostUniforms {
        var u = PostUniforms()
        u.scene = t.sceneUV
        // the bloom level sums the levels with weights 1, f, f², …: normalised so bloomStrength is the total
        var wsum: Float = 0, w: Float = 1
        for _ in 0..<max(1, t.bloom.count - bloomStart) { wsum += w; w *= bloomFalloff }
        u.bloom = F4(bloomThreshold, bloomKnee, bloomReady ? bloomStrength / wsum : 0, bloomFireflyClamp)
        u.grade = F4(powf(2, exposureEV), vignette, grain, max(0.5, brightness))
        u.misc = F4(time, frameIndex, sharpen, distortionStrength)
        return u
    }

    /// Advance the exposure dip (wall time; a frozen world keeps easing back).
    func update(now: Double) {
        let dt = lastNow > 0 ? Float(min(0.1, now - lastNow)) : 0
        lastNow = now
        dipLeft = max(0, dipLeft - dt)
        dipEV = dipPeak * (dipLeft / dipDur)
    }

    /// R4–R12: the bloom chain from sceneHDR (tier: High from level 0 × 5, Efficient from level 1 × 4).
    func encodeBloom(_ cb: MTLCommandBuffer, _ t: RenderTargets, tier: RenderTier, time: Float, counters: GPUCounters) {
        bloomStart = tier == .high ? 0 : 1
        bloomReady = false
        guard let scene = t.scene, t.bloom.count > bloomStart + 1, let pf = psPrefilter, let dn = psDown, let up = psUp else { return }
        frameIndex = frameIndex >= 1024 ? 0 : frameIndex + 1
        var u = uniforms(t, time: time)
        let last = t.bloom.count - 1
        var passIndex = 0
        let passCount = 1 + 2 * (last - bloomStart)
        func run(_ ps: MTLRenderPipelineState, _ src: MTLTexture, _ dst: MTLTexture, load: Bool, label: String) {
            let c = bloomPass.colorAttachments[0]!
            c.texture = dst
            c.loadAction = load ? .load : .dontCare
            counters.attach(to: bloomPass, pass: .bloom, first: passIndex == 0, last: passIndex == passCount - 1)
            passIndex += 1
            guard let enc = cb.makeRenderCommandEncoder(descriptor: bloomPass) else { return }
            enc.label = label
            u.pass = F4(1 / Float(src.width), 1 / Float(src.height), 1 / Float(dst.width), 1 / Float(dst.height))
            if load { u.pass.z = bloomFalloff }
            enc.setRenderPipelineState(ps)
            enc.setFragmentBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 0)
            enc.setFragmentTexture(src, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        run(pf, scene, t.bloom[bloomStart], load: false, label: "bloom prefilter")
        if bloomStart + 1 <= last {
            for k in (bloomStart + 1)...last { run(dn, t.bloom[k - 1], t.bloom[k], load: false, label: "bloom down \(k)") }
            for k in stride(from: last - 1, through: bloomStart, by: -1) { run(up, t.bloom[k + 1], t.bloom[k], load: true, label: "bloom up \(k)") }
        }
        counters.detach(bloomPass)
        bloomPass.colorAttachments[0].texture = nil
        bloomReady = true
    }

    /// The composite: first draw of the final pass. false = nothing to show yet.
    func encodeComposite(_ enc: MTLRenderCommandEncoder, _ t: RenderTargets, tier: RenderTier, time: Float, distortion: MTLTexture?) -> Bool {
        let ps = psComposite[tier == .high ? 0 : 1] ?? psComposite[tier == .high ? 1 : 0]
        guard let p = ps, let scene = t.scene, let lut = lut else { return false }
        var u = uniforms(t, time: time)
        if distortion == nil { u.misc.w = 0 }
        enc.setRenderPipelineState(p)
        enc.setFragmentBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 0)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentTexture(bloomReady && bloomStart < t.bloom.count ? t.bloom[bloomStart] : black, index: 1)
        enc.setFragmentTexture(lut, index: 2)
        enc.setFragmentTexture(distortion ?? neutralDistortion, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }
}
