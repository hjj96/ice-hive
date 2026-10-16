import Foundation
import Metal
import MetalKit

// ================================================================
//  MESH STORE — loads the meshes and textures exported from the web
//  game (ios-native/tools/export-meshes.mjs → App/Resources/Meshes,
//  flat in the bundle root): IHM1 binaries (little-endian: magic,
//  u32 vertexCount, u32 indexCount, u32 flags; interleaved vertices
//  of position, normal, colour (linear), aGlow, aLeg; u32 indices),
//  manifest.json (texture colour spaces, wrap modes) and PNG textures
//  via MTKTextureLoader. A missing file is logged and replaced by a
//  small placeholder so the renderer always has something to draw.
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
}

final class MeshStore {
    /// Vertex layout of every mesh buffer (the exporter's stride: 13 floats).
    static let stride = 52

    let device: MTLDevice
    private(set) var meshes: [String: GPUMesh] = [:]
    private(set) var textures: [String: MTLTexture] = [:]
    private(set) var missing: [String] = []
    private(set) var bytesLoaded = 0
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
        let loader = MTKTextureLoader(device: device)
        for (name, file, s, mips) in MeshStore.textureDefaults {
            guard let u = url(file, "png") else { missing.append(file + ".png"); continue }
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB: NSNumber(value: srgb[name] ?? s),
                .generateMipmaps: NSNumber(value: mips),
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                .origin: MTKTextureLoader.Origin.topLeft.rawValue,
            ]
            do {
                textures[name] = try loader.newTexture(URL: u, options: opts)
            } catch {
                missing.append(file + ".png (\(error.localizedDescription))")
            }
        }
        noise = makeNoise()
        white = makeWhite()
        let ms = (FrameTimer.now() - t0) * 1000
        var tris = 0
        for m in meshes.values { tris += m.indexCount / 3 }
        return String(format: "meshes %d (%d triangles, %.1f MB) textures %d in %.0f ms", meshes.count, tris,
                      Double(bytesLoaded) / 1_048_576, textures.count, ms)
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
            // vertices: copied as-is at the shared stride, repacked otherwise (aLeg zero-filled)
            var verts = [Float](repeating: 0, count: vc * 13)
            var lo = F3(repeating: Float.greatestFiniteMagnitude), hi = F3(repeating: -Float.greatestFiniteMagnitude)
            for i in 0..<vc {
                let o = 16 + i * stride
                let nf = min(13, stride / 4)
                for k in 0..<nf { verts[i * 13 + k] = base.loadUnaligned(fromByteOffset: o + k * 4, as: Float.self) }
                let p = F3(verts[i * 13], verts[i * 13 + 1], verts[i * 13 + 2])
                lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p)
            }
            var idx = [UInt32](repeating: 0, count: ic)
            let io = 16 + vc * stride
            var bad = 0
            for i in 0..<ic {
                let v = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: io + i * 4, as: UInt32.self))
                if Int(v) >= vc { bad += 1; idx[i] = 0 } else { idx[i] = v }
            }
            if bad > 0 { missing.append(name + ".mesh (\(bad) indices out of range)") }
            guard let vb = device.makeBuffer(bytes: verts, length: verts.count * 4, options: []),
                  let ib = device.makeBuffer(bytes: idx, length: idx.count * 4, options: []) else { return nil }
            vb.label = name + ".v"
            ib.label = name + ".i"
            bytesLoaded += verts.count * 4 + idx.count * 4
            return GPUMesh(name: name, vertices: vb, indices: ib, vertexCount: vc, indexCount: ic, flags: flags,
                           boundsMin: lo, boundsMax: hi, placeholder: false)
        }
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
