import Foundation
import Metal

// ================================================================
//  IHV LOADER — the swarm's creature files (owned by WP3 «Рой»):
//  App/Resources/Creatures/<type>.ihv, written by the Blender pipeline
//  (tools/blender/creatures, format: tools/blender/ihv.py, version 2
//  rigid). The whole file becomes ONE shared MTLBuffer: the LOD vertex
//  (20-byte rigid records) and index sections are bound at their
//  offsets, the bone texture (RGBA16F, 3 texels per bone per frame)
//  is a linear texture over the same bytes (256-aligned offset and
//  row pitch; a copied texture where the device refuses that), and the
//  per-frame glow table is a buffer offset. The clip table, LODs and
//  sockets are parsed here; the CPU also keeps the socket rest points
//  (gland glints, WP5's impact points) and reads bone rows for them.
// ================================================================

/// One clip of a creature (IHV1 clip record).
struct IHVClip {
    let name: String
    let first: Int
    let frames: Int
    let fps: Float
    let loop: Bool
    /// Locomotion: the phase comes from the distance walked (`stride` m per loop at scale 1).
    let locomotion: Bool
    let stride: Float
    let event: Int
    /// Seconds: a loop's period, a one-shot's (frames − 1) / fps.
    let duration: Float
}

/// One LOD of a creature (IHV1 LOD record).
struct IHVLod {
    let vertexCount: Int
    let indexCount: Int
    let triangles: Int
    let indexType: MTLIndexType
    let vertexOffset: Int
    let indexOffset: Int
    /// The authored switch size (drawable px of the body length; 0 = always).
    let switchPx: Float
    /// Vertices drawn (socket points follow them).
    let drawVertexCount: Int
}

/// A socket point (IHV1 v2 socket record): a gland, the mouth, the body core …
struct IHVSocket {
    let name: String
    let bone: Int
    /// Raw flags (insect.py): bit0 glint, bit1 hot, bits 8–15 radius mm, bits 16–23 intensity × 100.
    let flags: UInt32
    /// Rest position (model space, game axes).
    let rest: F3

    var glint: Bool { flags & 1 != 0 }
    var hot: Bool { flags & 2 != 0 }
    var radius: Float { Float((flags >> 8) & 255) / 1000 }
    var intensity: Float { Float((flags >> 16) & 255) / 100 }
}

/// A loaded creature file.
final class IHVCreature {
    let name: String
    let buffer: MTLBuffer
    let boneTexture: MTLTexture
    let glowOffset: Int
    let fps: Float
    let frames: Int
    let boneCount: Int
    let clips: [IHVClip]
    let lods: [IHVLod]
    let sockets: [IHVSocket]
    let boundsMin: F3, boundsMax: F3
    /// Body length along z (model space, m): the LOD size measure.
    var length: Float { boundsMax.z - boundsMin.z }
    let bytes: Int
    private let boneTexOffset: Int
    private let boneRowBytes: Int

    /// Clip index by name (nil: the creature has no such clip).
    func clip(_ name: String) -> Int? { clips.firstIndex { $0.name == name } }

    private init(name: String, buffer: MTLBuffer, boneTexture: MTLTexture, glowOffset: Int, fps: Float, frames: Int, boneCount: Int,
                 clips: [IHVClip], lods: [IHVLod], sockets: [IHVSocket], bounds: (F3, F3), bytes: Int, boneTexOffset: Int, boneRowBytes: Int) {
        self.name = name
        self.buffer = buffer
        self.boneTexture = boneTexture
        self.glowOffset = glowOffset
        self.fps = fps
        self.frames = frames
        self.boneCount = boneCount
        self.clips = clips
        self.lods = lods
        self.sockets = sockets
        boundsMin = bounds.0
        boundsMax = bounds.1
        self.bytes = bytes
        self.boneTexOffset = boneTexOffset
        self.boneRowBytes = boneRowBytes
    }

    /// Bone `b`'s 3×4 deform matrix at `row` (rows r0, r1, r2 of [R | t], game space) — read from the shared buffer.
    func boneRows(_ b: Int, _ row: Int) -> (F4, F4, F4) {
        let base = buffer.contents().advanced(by: boneTexOffset + max(0, min(frames - 1, row)) * boneRowBytes + b * 24)
        let h = base.assumingMemoryBound(to: UInt16.self)
        @inline(__always) func t(_ k: Int) -> F4 { F4(ihvHalf(h[k * 4]), ihvHalf(h[k * 4 + 1]), ihvHalf(h[k * 4 + 2]), ihvHalf(h[k * 4 + 3])) }
        return (t(0), t(1), t(2))
    }

    /// A socket's model-space position at clip rows (r0, r1, f) — the same matrix lerp vs_creature does for clip A.
    func socketPoint(_ s: IHVSocket, _ r0: Int, _ r1: Int, _ f: Float) -> F3 {
        let a = boneRows(s.bone, r0), b = boneRows(s.bone, r1)
        let m0 = a.0 + (b.0 - a.0) * f, m1 = a.1 + (b.1 - a.1) * f, m2 = a.2 + (b.2 - a.2) * f
        let p = F4(s.rest.x, s.rest.y, s.rest.z, 1)
        return F3((m0 * p).sum(), (m1 * p).sum(), (m2 * p).sum())
    }

    // ---------------------------------------------------------------- parsing
    enum LoadError: Error, CustomStringConvertible {
        case missing(String), bad(String)
        var description: String {
            switch self { case .missing(let s): return "missing \(s)"; case .bad(let s): return s }
        }
    }

    static func load(device: MTLDevice, name: String) throws -> IHVCreature {
        guard let url = Bundle.main.url(forResource: name, withExtension: "ihv")
                ?? Bundle.main.url(forResource: name, withExtension: "ihv", subdirectory: "Creatures") else {
            throw LoadError.missing(name + ".ihv")
        }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try parse(device: device, name: name, data: data)
    }

    static func parse(device: MTLDevice, name: String, data: Data) throws -> IHVCreature {
        let n = data.count
        guard n >= 128 else { throw LoadError.bad("\(name).ihv: short file") }
        guard let buffer = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: n, options: [.storageModeShared]) }) else {
            throw LoadError.bad("\(name).ihv: no buffer")
        }
        buffer.label = "creature " + name
        let p = UnsafeRawPointer(buffer.contents())
        func u32(_ o: Int) -> Int { Int(p.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
        func f32(_ o: Int) -> Float { p.loadUnaligned(fromByteOffset: o, as: Float.self) }
        func str(_ o: Int, _ len: Int) -> String {
            var b: [UInt8] = []
            for k in 0..<len { let c = p.load(fromByteOffset: o + k, as: UInt8.self); if c == 0 { break }; b.append(c) }
            return String(decoding: b, as: UTF8.self)
        }
        guard str(0, 4) == "IHV1" else { throw LoadError.bad("\(name).ihv: not IHV1") }
        let version = u32(4), total = u32(8), flags = u32(12)
        guard version == 2, total == n else { throw LoadError.bad("\(name).ihv: version \(version), \(total) ≠ \(n) bytes") }
        guard flags & 1 != 0, flags & 4 == 0 else { throw LoadError.bad("\(name).ihv: not a rigid bone-texture file (flags \(flags))") }
        let fps = f32(16), frames = u32(20), clipCount = u32(24), lodCount = u32(28), boneCount = u32(32), socketCount = u32(36)
        let clipOff = u32(40), lodOff = u32(44), sockOff = u32(48)
        let btexOff = u32(56), btexRow = u32(60)
        let bmin = F3(f32(64), f32(68), f32(72)), bmax = F3(f32(76), f32(80), f32(84))
        let btexW = u32(92), glowOff = u32(96)
        guard lodCount >= 1 && lodCount <= 3, btexW == boneCount * 3, btexOff % 256 == 0, btexRow % 256 == 0, glowOff > 0,
              btexOff + btexRow * frames <= n, glowOff + frames * 16 <= n else {
            throw LoadError.bad("\(name).ihv: bad section table")
        }
        var clips: [IHVClip] = []
        for i in 0..<clipCount {
            let o = clipOff + i * 48
            let cf = u32(o + 28)
            let ev = u32(o + 36)
            clips.append(IHVClip(name: str(o, 16), first: u32(o + 16), frames: u32(o + 20), fps: f32(o + 24), loop: cf & 1 != 0,
                                 locomotion: cf & 4 != 0, stride: f32(o + 32), event: ev == 0xFFFF_FFFF ? -1 : ev, duration: f32(o + 40)))
        }
        var lods: [IHVLod] = []
        for i in 0..<lodCount {
            let o = lodOff + i * 64
            let vc = u32(o), ic = u32(o + 4), tris = u32(o + 8), ib = u32(o + 12), voff = u32(o + 16), stride = u32(o + 20)
            let ioff = u32(o + 24)
            guard stride == 20, voff + vc * 20 <= n, ioff + ic * ib <= n, ib == 2 || ib == 4 else {
                throw LoadError.bad("\(name).ihv: LOD\(i) record")
            }
            lods.append(IHVLod(vertexCount: vc, indexCount: ic, triangles: tris, indexType: ib == 2 ? .uint16 : .uint32, vertexOffset: voff,
                               indexOffset: ioff, switchPx: f32(o + 44), drawVertexCount: u32(o + 48)))
        }
        var sockets: [IHVSocket] = []
        let lod0 = lods[0]
        for i in 0..<socketCount {
            let o = sockOff + i * 48
            let vid = u32(o + 16)
            guard vid < lod0.vertexCount else { continue }
            let vo = lod0.vertexOffset + vid * 20
            let h = (p + vo + 8).assumingMemoryBound(to: UInt16.self)
            sockets.append(IHVSocket(name: str(o, 16), bone: u32(o + 28), flags: UInt32(u32(o + 32)),
                                     rest: F3(ihvHalf(h[0]), ihvHalf(h[1]), ihvHalf(h[2]))))
        }
        // the bone texture: a linear view of the buffer (no copy) on a device; a copy where it cannot be one — the
        // simulator makes linear textures only over private buffers (it asserts on a shared one)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: btexW, height: frames, mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        var tex: MTLTexture? = nil
        #if targetEnvironment(simulator)
        let linear = false
        #else
        let align = device.minimumLinearTextureAlignment(for: .rgba16Float)
        let linear = btexOff % align == 0 && btexRow % align == 0
        #endif
        if linear {
            tex = buffer.makeTexture(descriptor: td, offset: btexOff, bytesPerRow: btexRow)
        }
        if tex == nil, let t = device.makeTexture(descriptor: td) {
            t.replace(region: MTLRegionMake2D(0, 0, btexW, frames), mipmapLevel: 0, withBytes: p + btexOff, bytesPerRow: btexRow)
            tex = t
        }
        guard let bt = tex else { throw LoadError.bad("\(name).ihv: no bone texture") }
        bt.label = "bones " + name
        return IHVCreature(name: name, buffer: buffer, boneTexture: bt, glowOffset: glowOff, fps: fps, frames: frames, boneCount: boneCount,
                           clips: clips, lods: lods, sockets: sockets, bounds: (bmin, bmax), bytes: n, boneTexOffset: btexOff,
                           boneRowBytes: btexRow)
    }
}

/// The four bug types' creature files, loaded once per device (WorldSwarm and Corpses share them).
final class CreatureLibrary {
    /// BugType order: runner, spitter, brute, boomer.
    static let names = ["runner", "spitter", "brute", "boomer"]
    private static var cache: (ObjectIdentifier, CreatureLibrary)?

    /// One file per type; a type whose file is missing borrows the runner's (logged — never in a shipped build).
    let types: [IHVCreature]
    let summary: String

    static func shared(_ device: MTLDevice) -> CreatureLibrary? {
        if let c = cache, c.0 == ObjectIdentifier(device) { return c.1 }
        let t0 = FrameTimer.now()
        var loaded: [IHVCreature?] = []
        var notes: [String] = []
        for nm in names {
            do { loaded.append(try IHVCreature.load(device: device, name: nm)) } catch {
                notes.append("\(nm): \(error)")
                loaded.append(nil)
            }
        }
        guard let fallback = loaded.compactMap({ $0 }).first else {
            AppLog.error("swarm: no creature files (" + notes.joined(separator: "; ") + ")")
            return nil
        }
        let lib = CreatureLibrary(types: loaded.map { $0 ?? fallback }, notes: notes, ms: (FrameTimer.now() - t0) * 1000)
        cache = (ObjectIdentifier(device), lib)
        return lib
    }

    private init(types: [IHVCreature], notes: [String], ms: Double) {
        self.types = types
        let kb = types.reduce(0) { $0 + $1.bytes } / 1024
        summary = String(format: "creatures %d KB in %.1f ms: ", kb, ms)
            + types.map { c in "\(c.name) \(c.lods.map { String($0.triangles) }.joined(separator: "/")) tris \(c.clips.count) clips" }.joined(separator: ", ")
            + (notes.isEmpty ? "" : " | MISSING " + notes.joined(separator: "; "))
        if !notes.isEmpty { AppLog.error("swarm: " + notes.joined(separator: "; ")) }
    }
}

/// IEEE half → Float (no Float16: also builds where it is unavailable).
@inline(__always) func ihvHalf(_ h: UInt16) -> Float {
    let s = UInt32(h & 0x8000) << 16
    let e = Int((h >> 10) & 0x1f)
    let m = UInt32(h & 0x3ff)
    if e == 0 {
        if m == 0 { return Float(bitPattern: s) }
        // subnormal
        var mm = m, ee = -14
        while mm & 0x400 == 0 { mm <<= 1; ee -= 1 }
        return Float(bitPattern: s | UInt32(ee + 127) << 23 | (mm & 0x3ff) << 13)
    }
    if e == 31 { return Float(bitPattern: s | 0x7f80_0000 | m << 13) }
    return Float(bitPattern: s | UInt32(e - 15 + 127) << 23 | m << 13)
}
