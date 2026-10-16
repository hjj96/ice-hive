import Foundation
import Metal
import MetalKit
import ImageIO
import CoreGraphics

// ================================================================
//  MESH STORE — loads the meshes and textures exported from the web
//  game (ios-native/tools/export-meshes.mjs → App/Resources/Meshes,
//  flat in the bundle root): IHM1 binaries (little-endian: magic,
//  u32 vertexCount, u32 indexCount, u32 flags; interleaved vertices
//  of position, normal, colour (linear), aGlow, aLeg; u32 indices),
//  manifest.json (texture colour spaces, wrap modes) and PNG textures
//  decoded with ImageIO into straight-alpha RGBA (MTKTextureLoader
//  premultiplied them: the haze, glow pools and pad mark lost most of
//  their light). A missing file is logged and replaced by a small
//  placeholder so the renderer always has something to draw.
// ================================================================
struct GPUMesh {
    let name: String
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let vertexCount: Int
    let indexCount: Int
    let flags: UInt32
    let boundsMin: F3
    let boundsMax: F3
    let placeholder: Bool
    /// Bug meshes: the glow speckles (aGlow = 1, no leg weight) as (centre xyz, size) / (colour) pairs, drawn again as
    /// soft additive dots so a 3 cm glint never drops below a pixel (the web gets this from MSAA / bloom).
    var glints: [F4] = []
}

final class MeshStore {
    /// Vertex layout of every mesh buffer (the exporter's stride: 13 floats).
    static let stride = 52

    let device: MTLDevice
    private(set) var meshes: [String: GPUMesh] = [:]
    private(set) var textures: [String: MTLTexture] = [:]
    private(set) var missing: [String] = []
    private(set) var bytesLoaded = 0
    /// One-time diagnostic: the haze texture's centre texel as decoded here and as MTKTextureLoader returns it.
    private(set) var textureCheck = ""
    /// Tileable value noise for the particle edges (07-fx.js NOISE_TEX).
    private(set) var noise: MTLTexture?
    private var white: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
    }

    static let meshNames: [String] = [
        "bug_runner", "bug_spitter", "bug_brute", "bug_boomer", "corpse_generic", "corpse_brute",
        "marine_assault_body", "marine_assault_leg", "marine_assault_gun",
        "marine_pyro_body", "marine_pyro_leg", "marine_pyro_gun",
        "marine_cryo_body", "marine_cryo_leg", "marine_cryo_gun",
        "marine_gunner_body", "marine_gunner_leg", "marine_gunner_gun",
        "level_floor_grating", "level_floor_slab", "level_props", "level_hazard", "level_pad_mark", "level_glow", "level_haze",
        "lift_floor", "lift_props", "turret_base", "turret_head", "medkit", "glob", "grenade", "beacon_top",
    ]

    /// (name, file, sRGB, mipmaps) — overridden by manifest.json when it is present.
    private static let textureDefaults: [(String, String, Bool, Bool)] = [
        ("grating", "tex_grating", true, true), ("slab", "tex_slab", true, true), ("hazard", "tex_hazard", true, true),
        ("pad", "tex_pad", true, true), ("decals", "tex_decals", true, true), ("glow", "tex_glow", false, false),
        ("ring", "tex_ring", false, false), ("fill", "tex_fill", false, false), ("lane", "tex_lane", false, false),
        ("dash", "tex_dash", false, false), ("streak", "tex_streak", false, false), ("snow", "tex_snow", false, false),
        ("haze", "tex_haze", true, false),
    ]

    private func url(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Meshes")
    }

    /// Everything, synchronously (call off the main thread). Returns a one-line summary for the log.
    func loadAll() -> String {
        let t0 = FrameTimer.now()
        var srgb: [String: Bool] = [:]
        if let u = url("manifest", "json"), let d = try? Data(contentsOf: u),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let tex = j["textures"] as? [String: Any] {
            for (k, v) in tex {
                if let o = v as? [String: Any], let s = o["srgb"] as? Bool { srgb[k] = s }
            }
        } else {
            missing.append("manifest.json")
        }
        for n in MeshStore.meshNames { meshes[n] = loadMesh(n) ?? placeholder(n) }
        let queue = device.makeCommandQueue()
        for (name, file, s, mips) in MeshStore.textureDefaults {
            guard let u = url(file, "png") else { missing.append(file + ".png"); continue }
            let (t, err) = loadPNG(u, srgb: srgb[name] ?? s, mips: mips, queue: queue)
            if let t = t { t.label = name; textures[name] = t } else { missing.append(file + ".png (\(err))") }
        }
        textureCheck = checkHaze(queue: queue)
        noise = makeNoise()
        white = makeWhite()
        let ms = (FrameTimer.now() - t0) * 1000
        var tris = 0
        for m in meshes.values { tris += m.indexCount / 3 }
        let gl = ["bug_runner", "bug_spitter", "bug_brute", "bug_boomer"].map { String((meshes[$0]?.glints.count ?? 0) / 2) }.joined(separator: "/")
        return String(format: "meshes %d (%d triangles, %.1f MB) textures %d in %.0f ms", meshes.count, tris,
                      Double(bytesLoaded) / 1_048_576, textures.count, ms) + " glints " + gl + " " + textureCheck
            + (missing.isEmpty ? "" : " MISSING: " + missing.joined(separator: ", "))
    }

    func mesh(_ name: String) -> GPUMesh {
        if let m = meshes[name] { return m }
        let p = placeholder(name)
        meshes[name] = p
        return p
    }

    func texture(_ name: String) -> MTLTexture {
        if let t = textures[name] { return t }
        if let w = white { return w }
        let w = makeWhite()!
        white = w
        return w
    }

    // ---------------------------------------------------------------- IHM1
    private func loadMesh(_ name: String) -> GPUMesh? {
        guard let u = url(name, "mesh"), let data = try? Data(contentsOf: u) else {
            missing.append(name + ".mesh")
            return nil
        }
        guard data.count >= 16 else { missing.append(name + ".mesh (short)"); return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> GPUMesh? in
            guard let base = raw.baseAddress else { return nil }
            let magic = String(bytes: raw[0..<4], encoding: .ascii) ?? ""
            func u32(_ o: Int) -> UInt32 { UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
            let vc = Int(u32(4)), ic = Int(u32(8)), flags = u32(12)
            var stride = Int((flags >> 8) & 0xff)
            if stride == 0 { stride = MeshStore.stride }
            guard magic == "IHM1", stride >= 40, vc > 0, ic > 0, data.count >= 16 + vc * stride + ic * 4 else {
                missing.append(name + ".mesh (bad header \(magic) v\(vc) i\(ic) stride \(stride))")
                return nil
            }
            // vertices: one copy straight from the file at the shared stride (52 B), repacked otherwise (aLeg zero-filled)
            let vb: MTLBuffer?
            if stride == MeshStore.stride {
                vb = device.makeBuffer(bytes: base + 16, length: vc * stride, options: [])
            } else {
                var verts = [Float](repeating: 0, count: vc * 13)
                let nf = min(13, stride / 4)
                for i in 0..<vc {
                    for k in 0..<nf { verts[i * 13 + k] = base.loadUnaligned(fromByteOffset: 16 + i * stride + k * 4, as: Float.self) }
                }
                vb = device.makeBuffer(bytes: verts, length: verts.count * 4, options: [])
            }
            let io = 16 + vc * stride
            guard let vbuf = vb, let ib = device.makeBuffer(bytes: base + io, length: ic * 4, options: []) else { return nil }
            // indices checked in place (out-of-range ones are pointed at vertex 0)
            let ip = ib.contents().bindMemory(to: UInt32.self, capacity: ic)
            var bad = 0
            for i in 0..<ic where Int(UInt32(littleEndian: ip[i])) >= vc { ip[i] = 0; bad += 1 }
            if bad > 0 { missing.append(name + ".mesh (\(bad) indices out of range)") }
            let vp = vbuf.contents().bindMemory(to: Float.self, capacity: vc * 13)
            var lo = F3(repeating: Float.greatestFiniteMagnitude), hi = F3(repeating: -Float.greatestFiniteMagnitude)
            for i in 0..<vc {
                let p = F3(vp[i * 13], vp[i * 13 + 1], vp[i * 13 + 2])
                lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p)
            }
            vbuf.label = name + ".v"
            ib.label = name + ".i"
            bytesLoaded += vc * 52 + ic * 4
            var mesh = GPUMesh(name: name, vertices: vbuf, indices: ib, vertexCount: vc, indexCount: ic, flags: flags,
                               boundsMin: lo, boundsMax: hi, placeholder: false)
            if name.hasPrefix("bug_") {
                let verts = Array(UnsafeBufferPointer(start: vp, count: vc * 13))
                let idx = Array(UnsafeBufferPointer(start: ip, count: ic))
                mesh.glints = MeshStore.glints(verts, vc, idx)
            }
            return mesh
        }
    }

    /// Group the full-glow, leg-free vertices of a bug mesh into speckles (connected through their triangles and
    /// shared positions): centre, size and colour of each.
    static func glints(_ v: [Float], _ n: Int, _ idx: [UInt32]) -> [F4] {
        var parent = [Int](0..<n)
        func find(_ a0: Int) -> Int {
            var a = a0
            while parent[a] != a { parent[a] = parent[parent[a]]; a = parent[a] }
            return a
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }
        func isGlint(_ i: Int) -> Bool { v[i * 13 + 9] >= 0.99 && v[i * 13 + 10] == 0 && v[i * 13 + 12] <= 0.5 }
        var byPos: [SIMD3<Int32>: Int] = [:]
        for i in 0..<n where isGlint(i) {
            let k = SIMD3<Int32>(Int32((v[i * 13] * 1e4).rounded()), Int32((v[i * 13 + 1] * 1e4).rounded()), Int32((v[i * 13 + 2] * 1e4).rounded()))
            if let j = byPos[k] { union(i, j) } else { byPos[k] = i }
        }
        var t = 0
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            if isGlint(a) && isGlint(b) && isGlint(c) { union(a, b); union(b, c) }
            t += 3
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<n where isGlint(i) { groups[find(i), default: []].append(i) }
        var out: [F4] = []
        for key in groups.keys.sorted() {
            guard let l = groups[key], out.count < 16 else { continue }
            var c = F3.zero
            for i in l { c += F3(v[i * 13], v[i * 13 + 1], v[i * 13 + 2]) }
            c /= Float(l.count)
            var r: Float = 0.01
            for i in l { let d = F3(v[i * 13], v[i * 13 + 1], v[i * 13 + 2]) - c; r = max(r, (d * d).sum().squareRoot()) }
            let i0 = l[0]
            out.append(F4(c.x, c.y, c.z, 2 * r))
            out.append(F4(v[i0 * 13 + 6], v[i0 * 13 + 7], v[i0 * 13 + 8], 1))
        }
        return out
    }

    /// 20 cm grey cube (colour 0.5, no glow / legs) standing in for a missing mesh.
    private func placeholder(_ name: String) -> GPUMesh {
        var v: [Float] = []
        var idx: [UInt32] = []
        let h: Float = 0.1
        let faces: [(F3, F3, F3)] = [
            (F3(1, 0, 0), F3(0, 1, 0), F3(0, 0, 1)), (F3(-1, 0, 0), F3(0, 1, 0), F3(0, 0, -1)),
            (F3(0, 1, 0), F3(0, 0, 1), F3(1, 0, 0)), (F3(0, -1, 0), F3(0, 0, -1), F3(1, 0, 0)),
            (F3(0, 0, 1), F3(1, 0, 0), F3(0, 1, 0)), (F3(0, 0, -1), F3(-1, 0, 0), F3(0, 1, 0)),
        ]
        for (n, a, b) in faces {
            let base = UInt32(v.count / 13)
            for (sa, sb) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                let p = (n + a * sa + b * sb) * h + F3(0, h, 0)
                v += [p.x, p.y, p.z, n.x, n.y, n.z, 0.5, 0.5, 0.5, 0, 0, 0, 0]
            }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let vb = device.makeBuffer(bytes: v, length: v.count * 4, options: [])!
        let ib = device.makeBuffer(bytes: idx, length: idx.count * 4, options: [])!
        return GPUMesh(name: name, vertices: vb, indices: ib, vertexCount: v.count / 13, indexCount: idx.count, flags: 0,
                       boundsMin: F3(-h, 0, -h), boundsMax: F3(h, 2 * h, h), placeholder: true)
    }

    // ---------------------------------------------------------------- PNG textures
    /// Decode a PNG into a straight-alpha RGBA8 texture (sRGB or linear), mipmapped on the GPU when asked.
    private func loadPNG(_ url: URL, srgb: Bool, mips: Bool, queue: MTLCommandQueue?) -> (MTLTexture?, String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return (nil, "decode failed")
        }
        guard let px = MeshStore.straightRGBA(img) else { return (nil, "unsupported pixel layout") }
        let w = img.width, h = img.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: w, height: h,
                                                            mipmapped: mips)
        desc.usage = mips ? [.shaderRead, .renderTarget] : .shaderRead
        desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else { return (nil, "makeTexture failed") }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        if mips, t.mipmapLevelCount > 1, let cb = queue?.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return (t, "")
    }

    /// The image's pixels as straight (not premultiplied) RGBA8, rows top to bottom.
    static func straightRGBA(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let ai = img.alphaInfo
        let little = img.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        if img.bitsPerComponent == 8, img.bitsPerPixel == 32, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            // byte offsets of R, G, B, A in a pixel (-1 = no alpha)
            let o: (Int, Int, Int, Int)
            switch ai {
            case .last, .premultipliedLast: o = little ? (3, 2, 1, 0) : (0, 1, 2, 3)
            case .first, .premultipliedFirst: o = little ? (2, 1, 0, 3) : (1, 2, 3, 0)
            case .noneSkipLast: o = little ? (3, 2, 1, -1) : (0, 1, 2, -1)
            case .noneSkipFirst: o = little ? (2, 1, 0, -1) : (1, 2, 3, -1)
            default: return drawnRGBA(img)
            }
            let premul = ai == .premultipliedLast || ai == .premultipliedFirst
            let bpr = img.bytesPerRow
            for y in 0..<h {
                for x in 0..<w {
                    let s = y * bpr + x * 4, d = (y * w + x) * 4
                    let a = o.3 >= 0 ? p[s + o.3] : 255
                    var r = p[s + o.0], g = p[s + o.1], b = p[s + o.2]
                    if premul && a > 0 && a < 255 {
                        let k = 255 / Float(a)
                        r = UInt8(min(255, (Float(r) * k).rounded())); g = UInt8(min(255, (Float(g) * k).rounded()))
                        b = UInt8(min(255, (Float(b) * k).rounded()))
                    }
                    out[d] = r; out[d + 1] = g; out[d + 2] = b; out[d + 3] = a
                }
            }
            return out
        }
        return drawnRGBA(img)
    }

    /// Fallback for other layouts: draw into a premultiplied RGBA8 context and divide the alpha back out.
    private static func drawnRGBA(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
            let k = 255 / Float(px[i + 3])
            for c in 0..<3 { px[i + c] = UInt8(min(255, (Float(px[i + c]) * k).rounded())) }
        }
        return px
    }

    /// Diagnostic for the log: the haze centre texel (straight 119/149/183/139 in the PNG) as loaded here and through
    /// MTKTextureLoader with the options the spike used — shows whether the loader premultiplies.
    private func checkHaze(queue: MTLCommandQueue?) -> String {
        guard let u = url("tex_haze", "png"), let mine = textures["haze"] else { return "" }
        func texel(_ t: MTLTexture) -> String {
            guard t.storageMode == .shared, t.width > 128, t.height > 128 else { return "?" }
            var b = [UInt8](repeating: 0, count: 4)
            b.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(128, 128, 1, 1), mipmapLevel: 0) }
            return t.pixelFormat == .bgra8Unorm || t.pixelFormat == .bgra8Unorm_srgb ? "\(b[2])/\(b[1])/\(b[0])/\(b[3])" : "\(b[0])/\(b[1])/\(b[2])/\(b[3])"
        }
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [
            .SRGB: NSNumber(value: true), .generateMipmaps: NSNumber(value: false),
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
            .origin: MTKTextureLoader.Origin.topLeft.rawValue,
        ]
        let mtk = (try? loader.newTexture(URL: u, options: opts)).map(texel) ?? "-"
        return "haze texel own=\(texel(mine)) mtkloader=\(mtk)"
    }

    // ---------------------------------------------------------------- generated textures
    /// 64 × 64 tileable smooth value noise over 16 lattice cells (07-fx.js NOISE_TEX).
    private func makeNoise() -> MTLTexture? {
        let S = 64, L = 16
        var seed: UInt32 = 5
        func rnd() -> Float {
            seed = seed &+ 0x6D2B_79F5
            var t = (seed ^ (seed >> 15)) &* (1 | seed)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Float(t ^ (t >> 14)) / 4_294_967_296
        }
        var lat = [Float](repeating: 0, count: L * L)
        for i in 0..<lat.count { lat[i] = rnd() }
        var px = [UInt8](repeating: 0, count: S * S)
        for y in 0..<S {
            for x in 0..<S {
                let fx = Float(x) / Float(S) * Float(L), fy = Float(y) / Float(S) * Float(L)
                let xi = Int(fx), yi = Int(fy)
                let u = smooth01f(fx - Float(xi)), w = smooth01f(fy - Float(yi))
                let a = lat[(yi % L) * L + xi % L], b = lat[(yi % L) * L + (xi + 1) % L]
                let c = lat[((yi + 1) % L) * L + xi % L], d = lat[((yi + 1) % L) * L + (xi + 1) % L]
                px[y * S + x] = UInt8(max(0, min(255, lerpf(lerpf(a, b, u), lerpf(c, d, u), w) * 255)))
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: S, height: S, mipmapped: false)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, S, S), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: S) }
        t.label = "noise"
        return t
    }

    private func makeWhite() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        let px: [UInt8] = [255, 255, 255, 255]
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        return t
    }
}
