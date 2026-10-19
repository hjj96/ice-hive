import Foundation
import Metal

// ================================================================
//  ENVIRONMENT PROBE — the station seen from a deck (owned by WP2 «Свет
//  и воздух»): a 64² RGBA16F cube with 5 GGX-prefiltered mips (mip m =
//  roughness m / 4), baked offline in Blender / Cycles by
//  tools/blender/env/bake_probe.py into Resources/Env/station_probe.ihe
//  (0.26 MB): the cold dark void with a faint moon patch, the teal
//  walkway strips and lamps at the horizon, sodium and red warning
//  lamps, the navy abyss below. Materials read it through Lighting.h's
//  full API (shadeLit: Karis EnvBRDF specular + the top mip as diffuse)
//  at texture slot 4 — it gives wet chitin, steel and ice something to
//  reflect outside the flashlights. Missing file: a 1 × 1 navy cube.
//  File (little-endian): "IHE1", u32 size, u32 mips, u32 format
//  (1 = RGBA16F), u32 faces (6), 12 reserved bytes; then mip-major,
//  face-minor (+X −X +Y −Y +Z −Z, Metal's cube order) RGBA16F texels.
// ================================================================
final class EnvProbe {
    /// Weight of the probe in the ambient (LightBlock.ambient.xy): diffuse (the top mip) and specular.
    static let diffuseWeight: Float = 0.35
    static let specularWeight: Float = 0.6

    private(set) var mipCount = 1
    private(set) var texture: MTLTexture?
    private(set) var loaded = false

    /// Load the probe (main thread at attach: 0.26 MB, a few ms). Returns the cube to bind.
    func load(device: MTLDevice) -> MTLTexture? {
        if let t = texture { return t }
        let t0 = FrameTimer.now()
        if let u = Bundle.main.url(forResource: "station_probe", withExtension: "ihe", subdirectory: "Env")
            ?? Bundle.main.url(forResource: "station_probe", withExtension: "ihe"),
           let d = try? Data(contentsOf: u), let t = EnvProbe.makeCube(device: device, data: d) {
            texture = t.0
            mipCount = t.1
            loaded = true
            AppLog.info(String(format: "metal: environment probe %dx%d, %d mips, %.0f KB in %.1f ms", t.0.width, t.0.width, t.1,
                               Double(d.count) / 1024, (FrameTimer.now() - t0) * 1000))
        } else {
            texture = EnvProbe.fallback(device: device)
            mipCount = 1
            AppLog.error("metal: environment probe station_probe.ihe missing or bad: 1x1 fallback")
        }
        return texture
    }

    static func makeCube(device: MTLDevice, data: Data) -> (MTLTexture, Int)? {
        return data.withUnsafeBytes { raw -> (MTLTexture, Int)? in
            guard raw.count >= 32, String(bytes: raw[0..<4], encoding: .ascii) == "IHE1" else { return nil }
            func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            let size = u32(4), mips = u32(8), format = u32(12), faces = u32(16)
            guard size >= 1 && size <= 512, mips >= 1, (size >> (mips - 1)) >= 1, format == 1, faces == 6 else { return nil }
            var need = 32
            for m in 0..<mips { let s = size >> m; need += 6 * s * s * 8 }
            guard raw.count >= need, let base = raw.baseAddress else { return nil }
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: mips > 1)
            d.mipmapLevelCount = mips
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            t.label = "environment probe"
            var o = 32
            for m in 0..<mips {
                let s = size >> m
                for f in 0..<6 {
                    t.replace(region: MTLRegionMake2D(0, 0, s, s), mipmapLevel: m, slice: f, withBytes: base + o, bytesPerRow: s * 8, bytesPerImage: s * s * 8)
                    o += s * s * 8
                }
            }
            return (t, mips)
        }
    }

    /// 1 × 1 cube of the abyss navy (half floats).
    static func fallback(device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: 1, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        // (0.004, 0.007, 0.012, 1) as IEEE half
        let px: [UInt16] = [0x1C19, 0x1F2C, 0x2224, 0x3C00]
        px.withUnsafeBytes { b in
            for f in 0..<6 { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: f, withBytes: b.baseAddress!, bytesPerRow: 8, bytesPerImage: 8) }
        }
        return t
    }
}
