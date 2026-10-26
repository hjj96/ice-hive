import Foundation
import Metal
import IceHiveCore

// ================================================================
//  MARINE RIG (WP4 «Отряд») — the skinned marines' assets and their
//  CPU animation:
//   MarineAsset     one Characters/marine_<class>.ihv (IHV1 v2 skinned,
//                   tools/blender/ihv.py): the whole file is one
//                   MTLBuffer (vertices + u16 indices at 256-aligned
//                   offsets), the 32-bone skeleton (bind = pure
//                   translations), the clip records and their tracks
//                   (half4 bone-local rotation + translation per bone
//                   per frame, decoded once), the sockets (muzzle,
//                   torch, grips with their hand frames)
//   MarineTextures  the two texture arrays (layer = class): baked
//                   tangent-space normals (ASTC 6×6, x in rgb, y in a)
//                   and AO / roughness / metal / paint mask (ASTC 6×6)
//   MarineRig       one marine's blend tree, every drawn frame:
//     locomotion    idle ↔ walk ↔ run in 8 directions (move vs aim
//                   angle), one phase advanced by distance / stride so
//                   planted feet stay planted at any speed
//     full body     dash (anticipation → boost → land → settle, 4
//                   directions), down → downed crawl → revive (scrubbed
//                   by the revive progress, then played out) → death
//     additive      per-weapon fire layer (rifle kick per shot, rotary
//                   judder, flamer push, cryo hum), hit flinch
//     procedural    rotary barrels / cryo coils spin (weapon_aux),
//                   pauldrons / tassets follow, both hands on 2-bone IK
//                   to the weapon grips every frame, planted feet
//                   locked in the world (2-bone leg IK; a turning idle
//                   marine re-steps)
//     palette       32 × 3×4 skinning matrices in world space (the
//                   instance transform folded in) → the frame arena
//  The ctrl bone of every clip carries the IK weights (gun hand,
//  support hand), the plant weights of both feet and the visor glow.
// ================================================================

/// Quaternion helpers (x, y, z, w; Hamilton; the pipeline's convention, skeleton.py).
enum Quat {
    typealias Q = SIMD4<Float>
    static let identity = Q(0, 0, 0, 1)

    @inline(__always) static func mul(_ a: Q, _ b: Q) -> Q {
        Q(a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
          a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
          a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
          a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
    }

    @inline(__always) static func conj(_ q: Q) -> Q { Q(-q.x, -q.y, -q.z, q.w) }

    @inline(__always) static func norm(_ q: Q) -> Q {
        let l = (q * q).sum().squareRoot()
        return l > 1e-12 ? q / l : identity
    }

    @inline(__always) static func rotate(_ q: Q, _ v: F3) -> F3 {
        let u = F3(q.x, q.y, q.z)
        let t = Mat4.cross(u, v) * 2
        return v + t * q.w + Mat4.cross(u, t)
    }

    @inline(__always) static func axis(_ a: F3, _ angle: Float) -> Q {
        let s = sinf(angle * 0.5)
        return Q(a.x * s, a.y * s, a.z * s, cosf(angle * 0.5))
    }

    /// Normalised lerp with the shorter arc.
    @inline(__always) static func nlerp(_ a: Q, _ b: Q, _ t: Float) -> Q {
        let bb = (a * b).sum() < 0 ? -b : b
        return norm(a + (bb - a) * t)
    }

    /// Shortest-arc rotation taking direction u onto v.
    static func between(_ u0: F3, _ v0: F3) -> Q {
        let u = u0 / max(1e-9, (u0 * u0).sum().squareRoot()), v = v0 / max(1e-9, (v0 * v0).sum().squareRoot())
        let d = (u * v).sum()
        if d < -0.99999 {
            var a = Mat4.cross(u, F3(1, 0, 0))
            if (a * a).sum() < 1e-8 { a = Mat4.cross(u, F3(0, 1, 0)) }
            return axis(a / (a * a).sum().squareRoot(), Float.pi)
        }
        let c = Mat4.cross(u, v)
        return norm(Q(c.x, c.y, c.z, 1 + d))
    }

    /// Rotation whose columns are the orthonormal axes x, y, z.
    static func fromAxes(_ x: F3, _ y: F3, _ z: F3) -> Q {
        let m00 = x.x, m11 = y.y, m22 = z.z
        let t = m00 + m11 + m22
        var q: Q
        if t > 0 {
            let s = (t + 1).squareRoot() * 2
            q = Q((y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, 0.25 * s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            q = Q(0.25 * s, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            q = Q((y.x + x.y) / s, 0.25 * s, (z.y + y.z) / s, (z.x - x.z) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            q = Q((z.x + x.z) / s, (z.y + y.z) / s, 0.25 * s, (x.y - y.x) / s)
        }
        return norm(q)
    }

    /// Rows of the rotation matrix.
    @inline(__always) static func rows(_ q: Q) -> (F3, F3, F3) {
        let x = q.x, y = q.y, z = q.z, w = q.w
        return (F3(1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
                F3(2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
                F3(2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)))
    }
}

@inline(__always) private func len3(_ v: F3) -> Float { (v * v).sum().squareRoot() }
@inline(__always) private func unit3(_ v: F3) -> F3 { let l = len3(v); return l > 1e-9 ? v / l : F3(0, 1, 0) }

// ================================================================ asset
final class MarineAsset {
    struct Clip {
        let name: String
        let first: Int
        let frames: Int
        let loop: Bool
        /// Metres per loop (locomotion; 0 otherwise).
        let stride: Float
        let duration: Float
    }
    struct Socket { let bone: Int; let offset: F3 }

    let cls: MarineClass
    let buffer: MTLBuffer
    let vertexOffset: Int
    let vertexCount: Int
    let indexOffset: Int
    let indexCount: Int
    let indexType: MTLIndexType
    let bones: Int
    let parent: [Int]
    let names: [String]
    let bindPos: [F3]
    /// Bone-local bind translations.
    let bindLocal: [F3]
    let fps: Float
    let clips: [Clip]
    let clipIndex: [String: Int]
    /// Track rows: rot[frame * bones + bone], pos[…] (xyz translation, w = the scale slot: ctrl's right-foot plant).
    let rot: [SIMD4<Float>]
    let pos: [SIMD4<Float>]
    let sockets: [String: Socket]
    let boundsMin: F3
    let boundsMax: F3
    let fileBytes: Int

    /// Bone indices the rig touches by name.
    let iPelvis, iChest, iWeapon, iAux, iCtrl: Int
    let iArm: [(Int, Int, Int)]     // (upperarm, forearm, hand) L, R
    let iLeg: [(Int, Int, Int, Int)] // (thigh, shin, foot, toe) L, R
    let iFollow: [(Int, Int, Float, Bool)]  // (dst, src, weight, lift-only)

    static func url(_ cls: MarineClass) -> URL? {
        let n = "marine_\(cls.id)"
        return Bundle.main.url(forResource: n, withExtension: "ihv") ?? Bundle.main.url(forResource: n, withExtension: "ihv", subdirectory: "Characters")
    }

    init?(cls: MarineClass, device: MTLDevice, data d: Data) {
        self.cls = cls
        fileBytes = d.count
        var ok = true
        func u32(_ o: Int) -> Int {
            guard o + 4 <= d.count else { ok = false; return 0 }
            return Int(d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) })
        }
        func i32(_ o: Int) -> Int {
            guard o + 4 <= d.count else { ok = false; return 0 }
            return Int(d.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: Int32.self)) })
        }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: u32(o))) }
        func u16(_ o: Int) -> UInt16 { d.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt16.self)) } }
        func name(_ o: Int, _ n: Int) -> String {
            guard o + n <= d.count else { return "" }
            return String(decoding: d[o..<(o + n)].prefix { $0 != 0 }, as: UTF8.self)
        }
        guard d.count >= 128, String(decoding: d[0..<4], as: UTF8.self) == "IHV1", u32(4) == 2, u32(8) == d.count else { return nil }
        let flags = u32(12)
        guard flags & 4 != 0, flags & 8 != 0, u32(108) == 1 else { return nil }   // skinned + clip tracks
        fps = f32(16)
        let frames = u32(20), nclip = u32(24), nbone = u32(32), nsock = u32(36)
        let clipOff = u32(40), lodOff = u32(44), sockOff = u32(48), boneOff = u32(52)
        let trkOff = u32(100), trkRow = u32(104)
        boundsMin = F3(f32(64), f32(68), f32(72))
        boundsMax = F3(f32(76), f32(80), f32(84))
        bones = nbone
        var cl: [Clip] = []
        var ci: [String: Int] = [:]
        for k in 0..<nclip {
            let r = clipOff + k * 48
            let c = Clip(name: name(r, 16), first: u32(r + 16), frames: u32(r + 20), loop: u32(r + 28) & 1 != 0, stride: f32(r + 32),
                         duration: f32(r + 40))
            ci[c.name] = cl.count
            cl.append(c)
        }
        clips = cl
        clipIndex = ci
        vertexCount = u32(lodOff)
        indexCount = u32(lodOff + 4)
        let ib = u32(lodOff + 12)
        vertexOffset = u32(lodOff + 16)
        guard u32(lodOff + 20) == 32 else { return nil }
        indexOffset = u32(lodOff + 24)
        indexType = ib == 2 ? .uint16 : .uint32
        var par: [Int] = [], nm: [String] = [], bl: [F3] = []
        var bp: [F3] = []
        for k in 0..<nbone {
            let r = boneOff + k * 64
            nm.append(name(r, 24))
            let p = i32(r + 24)
            par.append(p)
            let t = F3(f32(r + 48), f32(r + 52), f32(r + 56))
            bl.append(t)
            bp.append(p >= 0 && p < bp.count ? bp[p] + t : t)
        }
        parent = par
        names = nm
        bindLocal = bl
        bindPos = bp
        var so: [String: Socket] = [:]
        for k in 0..<nsock {
            let r = sockOff + k * 48
            so[name(r, 16)] = Socket(bone: u32(r + 28), offset: F3(f32(r + 36), f32(r + 40), f32(r + 44)))
        }
        sockets = so
        var R = [SIMD4<Float>](repeating: Quat.identity, count: frames * nbone)
        var P = [SIMD4<Float>](repeating: .zero, count: frames * nbone)
        guard trkOff > 0, trkOff + frames * trkRow <= d.count else { return nil }
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for f in 0..<frames {
                for b in 0..<nbone {
                    let o = trkOff + f * trkRow + b * 16
                    func h(_ k: Int) -> Float { halfToFloat(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: o + 2 * k, as: UInt16.self))) }
                    R[f * nbone + b] = SIMD4(h(0), h(1), h(2), h(3))
                    P[f * nbone + b] = SIMD4(h(4), h(5), h(6), h(7))
                }
            }
        }
        rot = R
        pos = P
        _ = u16
        guard ok, vertexOffset + vertexCount * 32 <= d.count, indexOffset + indexCount * ib <= d.count,
              let buf = d.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: d.count, options: .storageModeShared) }) else { return nil }
        buf.label = "marine_\(cls.id)"
        buffer = buf
        func idx(_ n: String) -> Int { nm.firstIndex(of: n) ?? 0 }
        iPelvis = idx("pelvis"); iChest = idx("chest"); iWeapon = idx("weapon"); iAux = idx("weapon_aux"); iCtrl = idx("ctrl")
        iArm = ["L", "R"].map { (idx("upperarm_" + $0), idx("forearm_" + $0), idx("hand_" + $0)) }
        iLeg = ["L", "R"].map { (idx("thigh_" + $0), idx("shin_" + $0), idx("foot_" + $0), idx("toe_" + $0)) }
        iFollow = [(idx("pauldron_L"), idx("upperarm_L"), 0.15, false), (idx("pauldron_R"), idx("upperarm_R"), 0.15, false),
                   (idx("tasset_L"), idx("thigh_L"), 0.55, true), (idx("tasset_R"), idx("thigh_R"), 0.55, true)]
        guard nbone == 32, clipIndex["idle"] != nil, clipIndex["run_f"] != nil else { return nil }
    }

    func clip(_ n: String) -> Int { clipIndex[n] ?? 0 }
}

// ================================================================ textures
/// The class texture arrays (IHT1: tools/blender/iht.py), uploaded once through a staging buffer and one blit.
final class MarineTextures {
    private(set) var normal: MTLTexture?
    private(set) var orm: MTLTexture?
    private(set) var note = ""

    init(device: MTLDevice) {
        let astc = device.supportsFamily(.apple2)
        let queue = device.makeCommandQueue()
        let cb = queue?.makeCommandBuffer()
        let blit = cb?.makeBlitCommandEncoder()
        normal = MarineTextures.load("marine_normal", device: device, blit: blit, astc: astc, fallback: [128, 128, 255, 128])
        orm = MarineTextures.load("marine_orm", device: device, blit: blit, astc: astc, fallback: [255, 140, 20, 0])
        blit?.endEncoding()
        cb?.commit()
        cb?.waitUntilCompleted()
        note = (normal != nil && orm != nil) ? (astc ? "ASTC" : "FLAT (no ASTC)") : "MISSING"
    }

    private static func load(_ name: String, device: MTLDevice, blit: MTLBlitCommandEncoder?, astc: Bool, fallback: [UInt8]) -> MTLTexture? {
        guard let u = Bundle.main.url(forResource: name, withExtension: "iht") ?? Bundle.main.url(forResource: name, withExtension: "iht", subdirectory: "Characters"),
              let d = try? Data(contentsOf: u) else { return flat(device, layers: 4, fallback, name) }
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MTLTexture? in
            guard let base = raw.baseAddress, raw.count >= 64 else { return nil }
            func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }
            guard String(bytes: raw[0..<4], encoding: .ascii) == "IHT1", u32(4) == 1, u32(8) == raw.count else { return nil }
            let fmt = u32(16), w = u32(20), h = u32(24), layers = u32(28), mips = u32(32), tab = u32(36)
            let pf: MTLPixelFormat
            switch fmt {
            case 1: pf = .astc_4x4_ldr
            case 2: pf = .astc_5x5_ldr
            case 3: pf = .astc_6x6_ldr
            case 4: pf = .astc_8x8_ldr
            case 16: pf = .rgba8Unorm
            default: return nil
            }
            if fmt != 16 && !astc { return flat(device, layers: layers, fallback, name) }
            let desc = MTLTextureDescriptor()
            desc.textureType = .type2DArray
            desc.pixelFormat = pf
            desc.width = w
            desc.height = h
            desc.arrayLength = layers
            desc.mipmapLevelCount = mips
            desc.usage = .shaderRead
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc), let blit = blit,
                  let staging = device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared) else { return nil }
            for L in 0..<layers {
                for m in 0..<mips {
                    let r = tab + 16 * (L * mips + m)
                    let off = u32(r), n = u32(r + 4), bpr = u32(r + 8)
                    guard off + n <= raw.count else { return nil }
                    blit.copy(from: staging, sourceOffset: off, sourceBytesPerRow: bpr, sourceBytesPerImage: n,
                              sourceSize: MTLSize(width: max(1, w >> m), height: max(1, h >> m), depth: 1), to: tex, destinationSlice: L,
                              destinationLevel: m, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                }
            }
            tex.label = name
            return tex
        }
    }

    private static func flat(_ device: MTLDevice, layers: Int, _ v: [UInt8], _ label: String) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba8Unorm
        desc.width = 1
        desc.height = 1
        desc.arrayLength = max(1, layers)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        for L in 0..<max(1, layers) {
            v.withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: L, withBytes: $0.baseAddress!, bytesPerRow: 4, bytesPerImage: 4)
            }
        }
        t.label = label + " (flat)"
        return t
    }
}

// ================================================================ rig
/// What the rig needs from the simulation for one marine this frame (world space).
struct RigInput {
    var pos = F3(0, 0, 0)
    /// Facing (aim) angle about +y: the model's +z points along (sin yaw, cos yaw).
    var yaw: Float = 0
    /// Ground velocity (m/s, world x / z).
    var vel = SIMD2<Float>(0, 0)
    var firing = false
    /// 1 on a shot, decaying (the core's muzzle).
    var muzzle: Float = 0
    /// Rotary spin-up 0…1 (gunner).
    var spin: Float = 0
    var dashT: Float = 0
    var dashDir = SIMD2<Float>(0, 1)
    var hurtT: Float = 0
    var knock = SIMD2<Float>(0, 0)
    var downed = false
    /// Revive progress 0…1 while downed.
    var revive: Float = 0
    /// The mission is lost: downed marines die.
    var dead = false
    var invulnerable = false
}

final class MarineRig {
    let asset: MarineAsset
    typealias Q = SIMD4<Float>
    private let n: Int
    // the pose: bone-local rotation / translation, then model space
    private(set) var lq: [Q]
    private(set) var lt: [F3]
    private(set) var wq: [Q]
    private(set) var wt: [F3]
    private var oq: [Q], ot: [F3]      // the full-body override pose
    private var accQ: [Q], accT: [F3]
    private var accW: Float = 0
    /// ctrl curves of the blended pose: IK gun / support hand, plant L / R, visor.
    private(set) var ikGun: Float = 1, ikSup: Float = 1, plant = SIMD2<Float>(1, 1), visor: Float = 1
    private var ctrlAcc = SIMD4<Float>(0, 0, 0, 0), ctrlVisor: Float = 0

    // animation state
    private var phase: Float = 0
    private var gaitRun: Float = 0
    private var speedSm: Float = 0
    private var dirSm = SIMD2<Float>(0, 1)
    private var prevDash: Float = 0
    private var dashClock: Float = 10
    private var dashRel = SIMD2<Float>(0, 1)
    private var prevHurt: Float = 0
    private var flinchClock: Float = 10
    private var flinchBack = false
    private var prevMuzzle: Float = 0
    private var fireClock: Float = 10
    private var fireLoopW: Float = 0
    private var fireLoopT: Float = 0
    private var auxAngle: Float = 0
    private var wasDowned = false
    private var downClock: Float = 0
    private var reviveW: Float = 0
    private var getUpClock: Float = 10
    private var getUpFrom: Float = 0
    private var deathClock: Float = 0
    private var overrideW: Float = 0
    private var idleClock: Float = 0
    // foot lock (world space): locked ball position per foot and how long a re-step has been running
    private var lockOn = [false, false]
    private var lockPos = [F3](repeating: .zero, count: 2)
    private var stepClock: [Float] = [1, 1]
    private var stepFrom = [F3](repeating: .zero, count: 2)
    // world placement of this frame
    private(set) var world = Mat4.identity
    private(set) var yaw: Float = 0
    private(set) var origin = F3(0, 0, 0)
    // diagnostics: worst planted-foot slide (m, world) and hand-to-grip error (m) since the last read
    var slideMax: Float = 0
    var gripErrMax: Float = 0
    private var lastBall = [F3](repeating: .zero, count: 2)
    private var lastPlanted = [false, false]
    private(set) var state = "idle"

    private let iDirs: [[Int]]      // [walk, run] × 8 directions (f fl l bl b br r fr)
    private let iIdle, iFire, iFlinchF, iFlinchB, iDown, iDowned, iRevive, iDeath: Int
    private let iDash: [Int]         // f l b r

    init(asset: MarineAsset) {
        self.asset = asset
        n = asset.bones
        lq = [Q](repeating: Quat.identity, count: n)
        lt = asset.bindLocal
        wq = lq
        wt = asset.bindPos
        oq = lq
        ot = lt
        accQ = lq
        accT = lt
        let dirs = ["f", "fl", "l", "bl", "b", "br", "r", "fr"]
        iDirs = [dirs.map { asset.clip("walk_" + $0) }, dirs.map { asset.clip("run_" + $0) }]
        iIdle = asset.clip("idle"); iFire = asset.clip("fire"); iFlinchF = asset.clip("flinch_f"); iFlinchB = asset.clip("flinch_b")
        iDown = asset.clip("down"); iDowned = asset.clip("downed"); iRevive = asset.clip("revive"); iDeath = asset.clip("death")
        iDash = ["f", "l", "b", "r"].map { asset.clip("dash_" + $0) }
    }

    func reset() {
        phase = 0; dashClock = 10; flinchClock = 10; fireClock = 10; fireLoopW = 0; wasDowned = false; overrideW = 0
        getUpClock = 10; reviveW = 0; lockOn = [false, false]; speedSm = 0; prevDash = 0; prevHurt = 0; prevMuzzle = 0
    }

    // ---------------------------------------------------------------- sampling
    private func beginAcc() {
        for b in 0..<n { accQ[b] = .zero; accT[b] = .zero }
        accW = 0
        ctrlAcc = .zero
        ctrlVisor = 0
    }

    /// Add clip `c` at time t (s; loops wrap, one-shots clamp) with weight w.
    private func acc(_ c: Int, time t: Float, _ w: Float) {
        if w <= 1e-4 { return }
        let C = asset.clips[c]
        let fr = Float(C.frames)
        var p = t * asset.fps
        if C.loop { p = p - floorf(p / fr) * fr } else { p = min(max(0, p), fr - 1) }
        let f0 = Int(p), fa = p - Float(f0)
        let f1 = C.loop ? (f0 + 1) % C.frames : min(f0 + 1, C.frames - 1)
        let r0 = (C.first + min(f0, C.frames - 1)) * n, r1 = (C.first + f1) * n
        for b in 0..<n {
            if b == asset.iCtrl {
                let a = asset.pos[r0 + b], bb = asset.pos[r1 + b]
                ctrlAcc += (a + (bb - a) * fa) * w
                ctrlVisor += (asset.rot[r0 + b].x + (asset.rot[r1 + b].x - asset.rot[r0 + b].x) * fa) * w
                continue
            }
            var q = Quat.nlerp(asset.rot[r0 + b], asset.rot[r1 + b], fa)
            if (q * accQ[b]).sum() < 0 { q = -q }
            accQ[b] += q * w
            let a = asset.pos[r0 + b], bb = asset.pos[r1 + b]
            accT[b] += F3(a.x + (bb.x - a.x) * fa, a.y + (bb.y - a.y) * fa, a.z + (bb.z - a.z) * fa) * w
        }
        accW += w
    }

    /// Locomotion clips are sampled by phase (0…1).
    private func accPhase(_ c: Int, _ ph: Float, _ w: Float) {
        acc(c, time: ph * asset.clips[c].duration, w)
    }

    private func endAcc(into q: inout [Q], _ t: inout [F3]) {
        let inv = accW > 1e-6 ? 1 / accW : 1
        for b in 0..<n where b != asset.iCtrl {
            q[b] = Quat.norm(accQ[b])
            t[b] = accT[b] * inv
        }
        q[asset.iCtrl] = Quat.identity
        t[asset.iCtrl] = .zero
    }

    /// Delta of an additive clip at t against its frame 0, applied on top of the pose (pre-multiplied, local).
    private func additive(_ c: Int, time t: Float, _ w: Float) {
        if w <= 1e-3 { return }
        let C = asset.clips[c]
        let fr = Float(C.frames)
        var p = t * asset.fps
        if C.loop { p = p - floorf(p / fr) * fr } else { p = min(max(0, p), fr - 1) }
        let f0 = Int(p), fa = p - Float(f0)
        let f1 = C.loop ? (f0 + 1) % C.frames : min(f0 + 1, C.frames - 1)
        let r0 = (C.first + f0) * n, r1 = (C.first + f1) * n, rr = C.first * n
        for b in 0..<n where b != asset.iCtrl {
            let q = Quat.nlerp(asset.rot[r0 + b], asset.rot[r1 + b], fa)
            var d = Quat.mul(q, Quat.conj(asset.rot[rr + b]))
            d = Quat.nlerp(Quat.identity, d, w)
            lq[b] = Quat.norm(Quat.mul(d, lq[b]))
            let a = asset.pos[r0 + b], bb = asset.pos[r1 + b], ref = asset.pos[rr + b]
            let dt = F3(a.x + (bb.x - a.x) * fa - ref.x, a.y + (bb.y - a.y) * fa - ref.y, a.z + (bb.z - a.z) * fa - ref.z)
            lt[b] += dt * w
        }
    }

    // ---------------------------------------------------------------- FK / IK
    private func fk() {
        for b in 0..<n {
            let p = asset.parent[b]
            if p < 0 { wq[b] = lq[b]; wt[b] = lt[b] } else {
                wq[b] = Quat.norm(Quat.mul(wq[p], lq[b]))
                wt[b] = wt[p] + Quat.rotate(wq[p], lt[b])
            }
        }
    }

    /// FK of one bone's subtree after a local change (bones are ordered parents first).
    private func fkFrom(_ root: Int) {
        for b in root..<n {
            let p = asset.parent[b]
            guard b == root || isUnder(b, root) else { continue }
            if p < 0 { wq[b] = lq[b]; wt[b] = lt[b] } else {
                wq[b] = Quat.norm(Quat.mul(wq[p], lq[b]))
                wt[b] = wt[p] + Quat.rotate(wq[p], lt[b])
            }
        }
    }

    private func isUnder(_ b: Int, _ root: Int) -> Bool {
        var p = asset.parent[b]
        while p >= 0 { if p == root { return true }; p = asset.parent[p] }
        return false
    }

    /// Give bone b the model-space rotation q (its parent's from the current FK).
    private func setWorld(_ b: Int, _ q: Q) {
        let p = asset.parent[b]
        lq[b] = p >= 0 ? Quat.norm(Quat.mul(Quat.conj(wq[p]), q)) : q
    }

    /// Analytic 2-bone IK: a → b → c (c's origin is the end joint) to `target` (model space), bending toward the
    /// plane of the current pose; `endRot` (model space) for c. Returns the end's miss (m).
    @discardableResult
    private func twoBone(_ a: Int, _ b: Int, _ c: Int, _ target: F3, endRot: Q?, weight: Float) -> Float {
        if weight <= 1e-3 { return 0 }
        let A = wt[a], B = wt[b], C = wt[c]
        let T = C + (target - C) * min(1, weight)
        let l1 = len3(B - A), l2 = len3(C - B)
        let v = T - A
        let d0 = len3(v)
        let d = min(max(d0, abs(l1 - l2) + 1e-4), l1 + l2 - 1e-4)
        let dir = v / max(d0, 1e-6)
        let ca = min(1, max(-1, (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)))
        // bend plane from the current pose (the clip's elbow / knee)
        let mid = (A + C) * 0.5
        var pv = B - mid
        if len3(pv) < 1e-4 { pv = B - A }
        var perp = pv - dir * (pv * dir).sum()
        if len3(perp) < 1e-6 { perp = Mat4.cross(dir, F3(1, 0, 0)) }
        perp = unit3(perp)
        let Bn = A + dir * (l1 * ca) + perp * (l1 * (1 - ca * ca).squareRoot())
        let Cn = A + dir * d
        // upper bone: shortest arc onto the new elbow, then the twist that keeps the bend plane
        var q1 = Quat.between(B - A, Bn - A)
        let nOld = Quat.rotate(q1, Mat4.cross(B - A, C - B))
        let nNew = Mat4.cross(Bn - A, Cn - Bn)
        let ax = unit3(Bn - A)
        let u = nOld - ax * (nOld * ax).sum(), w = nNew - ax * (nNew * ax).sum()
        if len3(u) > 1e-6 && len3(w) > 1e-6 {
            let uu = unit3(u), ww = unit3(w)
            let ang = atan2f((Mat4.cross(uu, ww) * ax).sum(), (uu * ww).sum())
            q1 = Quat.mul(Quat.axis(ax, ang), q1)
        }
        let endWorld = wq[c]
        setWorld(a, Quat.norm(Quat.mul(q1, wq[a])))
        fkFrom(a)
        let q2 = Quat.between(wt[c] - wt[b], Cn - wt[b])
        setWorld(b, Quat.norm(Quat.mul(q2, wq[b])))
        fkFrom(b)
        if let r = endRot {
            setWorld(c, Quat.nlerp(endWorld, r, min(1, weight)))
        } else {
            setWorld(c, endWorld)
        }
        fkFrom(c)
        return d0 > l1 + l2 - 1e-4 ? d0 - (l1 + l2) : len3(wt[c] - T)
    }

    /// A socket's model-space position on the current pose.
    @inline(__always) private func socket(_ s: MarineAsset.Socket) -> F3 { wt[s.bone] + Quat.rotate(wq[s.bone], s.offset) }

    // ---------------------------------------------------------------- the frame
    /// Advance and pose this marine for the frame (world space input), dt seconds since the last drawn frame.
    func update(_ I: RigInput, dt dt0: Float) {
        let dt = min(0.1, max(0, dt0))
        origin = I.pos
        yaw = I.yaw
        world = Mat4.translation(I.pos.x, I.pos.y, I.pos.z) * Mat4.rotationY(I.yaw)
        // velocity in the model frame (+z = facing, +x = the marine's left)
        let c = cosf(I.yaw), s = sinf(I.yaw)
        let lx = I.vel.x * c - I.vel.y * s, lz = I.vel.x * s + I.vel.y * c
        let sp = (lx * lx + lz * lz).squareRoot()
        speedSm += (sp - speedSm) * min(1, dt * 10)
        if sp > 0.2 {
            let d = SIMD2<Float>(lx, lz) / sp
            dirSm += (d - dirSm) * min(1, dt * 12)
        }
        let dlen = (dirSm * dirSm).sum().squareRoot()
        let dir = dlen > 1e-4 ? dirSm / dlen : SIMD2<Float>(0, 1)
        // ---- base: locomotion
        let v = speedSm
        let walkV = asset.clips[iDirs[0][0]].stride / max(1e-3, asset.clips[iDirs[0][0]].duration)
        let runV = asset.clips[iDirs[1][0]].stride / max(1e-3, asset.clips[iDirs[1][0]].duration)
        let wRun = min(1, max(0, (v - walkV) / max(0.1, runV - walkV)))
        gaitRun += (wRun - gaitRun) * min(1, dt * 8)
        let moveW = min(1, max(0, (v - 0.08) / 0.7))
        let strideW = asset.clips[iDirs[0][0]].stride, strideR = asset.clips[iDirs[1][0]].stride
        let stride = strideW + (strideR - strideW) * gaitRun
        phase += v * dt / max(0.2, stride)
        phase -= floorf(phase)
        idleClock += dt
        // 8-way: the angle of the movement relative to the aim (0 = forward, +90 = toward the marine's left)
        var ang = atan2f(dir.x, dir.y) * 180 / Float.pi
        if ang < 0 { ang += 360 }
        let sect = ang / 45
        let i0 = Int(sect) % 8, i1 = (i0 + 1) % 8
        let fa = sect - floorf(sect)
        beginAcc()
        acc(iIdle, time: idleClock, 1 - moveW)
        if moveW > 1e-3 {
            for (g, gw) in [(0, 1 - gaitRun), (1, gaitRun)] where gw > 1e-3 {
                accPhase(iDirs[g][i0], phase, moveW * gw * (1 - fa))
                accPhase(iDirs[g][i1], phase, moveW * gw * fa)
            }
        }
        endAcc(into: &lq, &lt)
        var ctrl = ctrlAcc / max(1e-6, accW)
        var vis = ctrlVisor / max(1e-6, accW)
        state = moveW < 0.5 ? "idle" : (gaitRun > 0.5 ? "run" : "walk")
        // ---- full-body overrides
        var want: Float = 0
        beginAcc()
        if I.downed {
            if !wasDowned { downClock = 0; deathClock = 0 }
            downClock += dt
            let dd = asset.clips[iDown].duration
            if I.dead {
                deathClock += dt
                acc(iDeath, time: deathClock, 1)
                state = "death"
            } else {
                let rv = min(1, max(0, I.revive))
                reviveW += ((rv > 0.01 ? 1 : 0) - reviveW) * min(1, dt * 6)
                if downClock < dd {
                    acc(iDown, time: downClock, 1 - reviveW)
                    state = "down"
                } else {
                    acc(iDowned, time: downClock - dd, 1 - reviveW)
                    state = "downed"
                }
                if reviveW > 1e-3 {
                    acc(iRevive, time: rv * 0.78 * asset.clips[iRevive].duration, reviveW)
                    state = "revive"
                }
                getUpFrom = rv * 0.78
            }
            want = 1
            overrideW = 1
            getUpClock = 10
        } else {
            if wasDowned {
                getUpClock = 0
                lockOn = [false, false]
            }
            let rd = asset.clips[iRevive].duration
            if getUpClock < 10 {
                getUpClock += dt
                let t = getUpFrom * rd + getUpClock
                acc(iRevive, time: t, 1)
                state = "getup"
                want = t < rd ? 1 : max(0, 1 - (t - rd) / 0.25)
                if t > rd + 0.25 { getUpClock = 10 }
            }
            // dash: rising edge of the core's dash timer
            if I.dashT > 0 && prevDash <= 0 {
                dashClock = 0
                let dx = I.dashDir.x * c - I.dashDir.y * s, dz = I.dashDir.x * s + I.dashDir.y * c
                dashRel = SIMD2<Float>(dx, dz)
                lockOn = [false, false]
            }
            if dashClock < 10 && want < 0.5 {
                dashClock += dt
                // f l b r at 0 / 90 / 180 / 270
                var a = atan2f(dashRel.x, dashRel.y) * 180 / Float.pi
                if a < 0 { a += 360 }
                let q = a / 90
                let j0 = Int(q) % 4, j1 = (j0 + 1) % 4
                let f = q - floorf(q)
                acc(iDash[j0], time: dashClock, 1 - f)
                acc(iDash[j1], time: dashClock, f)
                let dur = asset.clips[iDash[0]].duration
                want = dashClock < 0.3 ? 1 : max(0, 1 - (dashClock - 0.3) / max(0.05, dur - 0.3))
                if dashClock > dur { dashClock = 10 }
                state = "dash"
            }
        }
        prevDash = I.dashT
        if accW > 1e-4 {
            let oc = ctrlAcc / accW, ov = ctrlVisor / accW
            endAcc(into: &oq, &ot)
            overrideW = I.downed ? 1 : want
            let w = overrideW
            for b in 0..<n where b != asset.iCtrl {
                lq[b] = Quat.nlerp(lq[b], oq[b], w)
                lt[b] += (ot[b] - lt[b]) * w
            }
            ctrl += (oc - ctrl) * w
            vis += (ov - vis) * w
        } else {
            overrideW = 0
        }
        wasDowned = I.downed
        // ---- additive layers
        if !I.downed {
            switch asset.cls {
            case .assault:
                if I.muzzle > prevMuzzle + 0.3 { fireClock = 0 }
                fireClock += dt
                additive(iFire, time: fireClock, fireClock < 0.25 ? 1 : 0)
            default:
                let want: Float = I.firing ? (asset.cls == .gunner ? I.spin : 1) : 0
                fireLoopW += (want - fireLoopW) * min(1, dt * 10)
                fireLoopT += dt
                additive(iFire, time: fireLoopT, fireLoopW)
            }
            if I.hurtT > prevHurt + 0.05 {
                flinchClock = 0
                let kx = I.knock.x * c - I.knock.y * s, kz = I.knock.x * s + I.knock.y * c
                flinchBack = kz > 0.05 && abs(kz) > abs(kx) * 0.5   // pushed forward: hit from behind
            }
            flinchClock += dt
            if flinchClock < 0.34 { additive(flinchBack ? iFlinchB : iFlinchF, time: flinchClock, 1) }
        }
        prevMuzzle = I.muzzle
        prevHurt = I.hurtT
        // ---- the spinning part of the weapon
        switch asset.cls {
        case .gunner: auxAngle += I.spin * dt * 40
        case .cryo: auxAngle += (I.firing ? 9 : 1.2) * dt
        default: break
        }
        auxAngle = fmodf(auxAngle, 2 * Float.pi)
        lq[asset.iAux] = Quat.norm(Quat.mul(lq[asset.iAux], Quat.axis(F3(0, 0, 1), auxAngle)))
        ikGun = min(1, max(0, ctrl.x)); ikSup = min(1, max(0, ctrl.y))
        plant = SIMD2<Float>(min(1, max(0, ctrl.z)), min(1, max(0, ctrl.w)))
        visor = min(1, max(0, vis))
        fk()
        // ---- hands on the grips
        let grips: [(String, String, String)] = [("grip_L", "grip_L_y", "grip_L_z"), ("grip_R", "grip_R_y", "grip_R_z")]
        let handAxes: [(String, String)] = [("hand_L_y", "hand_L_z"), ("hand_R_y", "hand_R_z")]
        for side in 0..<2 {
            let w = side == 0 ? ikGun : ikSup
            guard w > 1e-3, let g = asset.sockets[grips[side].0], let gy = asset.sockets[grips[side].1], let gz = asset.sockets[grips[side].2],
                  let hy = asset.sockets[handAxes[side].0], let hz = asset.sockets[handAxes[side].1] else { continue }
            let p = socket(g), py = socket(gy), pz = socket(gz)
            let z = unit3(pz - p)
            var y = py - p
            y = unit3(y - z * (y * z).sum())
            let x = Mat4.cross(y, z)
            // the hand's canonical frame at bind (bone-local offsets of its axis sockets)
            let bz = unit3(hz.offset)
            var by = hy.offset
            by = unit3(by - bz * (by * bz).sum())
            let bx = Mat4.cross(by, bz)
            let qF = Quat.fromAxes(x, y, z), qB = Quat.fromAxes(bx, by, bz)
            let rot = Quat.mul(qF, Quat.conj(qB))
            let (a, b, h) = asset.iArm[side]
            let err = twoBone(a, b, h, p, endRot: rot, weight: w)
            if w > 0.99 { gripErrMax = max(gripErrMax, err) }
        }
        // ---- feet: planted balls stay put in the world (leg IK); a turning idle marine re-steps
        let inv = Mat4.rotationY(-I.yaw)
        for side in 0..<2 {
            let (th, sh, ft, toe) = asset.iLeg[side]
            let ballM = wt[toe]
            let ballW = I.pos + Quat.rotate(Quat.axis(F3(0, 1, 0), I.yaw), ballM)
            let planted = plant[side] > 0.5 && overrideW < 0.5
            if planted {
                if !lockOn[side] {
                    lockOn[side] = true
                    lockPos[side] = F3(ballW.x, ballM.y + I.pos.y, ballW.z)
                    stepClock[side] = 1
                }
                // too far from where the clip wants it (a turn on the spot): step there
                let dx = lockPos[side] - F3(ballW.x, lockPos[side].y, ballW.z)
                if len3(dx) > 0.32 && stepClock[side] >= 1 && moveW < 0.3 {
                    stepFrom[side] = lockPos[side]
                    stepClock[side] = 0
                }
                var target = lockPos[side]
                if stepClock[side] < 1 {
                    stepClock[side] = min(1, stepClock[side] + dt / 0.2)
                    let e = stepClock[side] * stepClock[side] * (3 - 2 * stepClock[side])
                    let goal = F3(ballW.x, lockPos[side].y, ballW.z)
                    target = stepFrom[side] + (goal - stepFrom[side]) * e + F3(0, 0.09 * sinf(Float.pi * stepClock[side]), 0)
                    if stepClock[side] >= 1 { lockPos[side] = goal }
                }
                // world → model, ankle from the ball through the foot's current rotation
                let tm4 = inv.point(target.x - I.pos.x, target.y - I.pos.y, target.z - I.pos.z)
                let tm = F3(tm4.x, tm4.y, tm4.z)
                let ankle = tm - Quat.rotate(wq[ft], lt[toe])
                twoBone(th, sh, ft, ankle, endRot: nil, weight: 1)
                // diagnostics: the locked ball's world drift while planted (a slide)
                let now = I.pos + Quat.rotate(Quat.axis(F3(0, 1, 0), I.yaw), wt[toe])
                if lastPlanted[side] && stepClock[side] >= 1 {
                    let d = now - lastBall[side]
                    slideMax = max(slideMax, (d.x * d.x + d.z * d.z).squareRoot())
                }
                lastBall[side] = now
                lastPlanted[side] = stepClock[side] >= 1
            } else {
                lockOn[side] = false
                lastPlanted[side] = false
            }
        }
        // ---- secondary armour follows (after IK)
        for (dst, src, k, liftOnly) in asset.iFollow {
            let q = lq[src]
            if liftOnly {
                let fwd = Quat.rotate(q, F3(0, -1, 0))
                let lift = max(0, atan2f(fwd.z, -fwd.y))
                lq[dst] = Quat.axis(F3(1, 0, 0), -lift * k)
            } else {
                // the upper arm's swing away from its bind direction (no twist), a fraction of it
                let child = src + 1
                let d0 = asset.bindLocal[child]
                lq[dst] = Quat.nlerp(Quat.identity, Quat.between(d0, Quat.rotate(q, d0)), k)
            }
        }
        fk()
    }

    /// The muzzle (and other sockets) in world space on the posed rig.
    func worldSocket(_ name: String) -> F3? {
        guard let s = asset.sockets[name] else { return nil }
        let p = socket(s)
        let w = world.point(p.x, p.y, p.z)
        return F3(w.x, w.y, w.z)
    }

    /// World-space direction of a bone's local axis (the weapon's +z: where it points).
    func worldAxis(_ bone: Int, _ axis: F3) -> F3 {
        let v = Quat.rotate(wq[bone], axis)
        let c = cosf(yaw), s = sinf(yaw)
        return F3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
    }

    /// The skinning palette into `out` (3 float4 rows per bone, world space: the instance transform folded in).
    func writePalette(_ out: UnsafeMutablePointer<SIMD4<Float>>) {
        let c = cosf(yaw), s = sinf(yaw)
        for b in 0..<n {
            let (r0, r1, r2) = Quat.rows(wq[b])
            let t = wt[b] - (r0 * 0 + F3((r0 * asset.bindPos[b]).sum(), (r1 * asset.bindPos[b]).sum(), (r2 * asset.bindPos[b]).sum()))
            // world = Ry(yaw) × M, then + origin
            let w0 = r0 * c + r2 * s, w2 = r0 * -s + r2 * c
            let t0 = t.x * c + t.z * s + origin.x, t2 = -t.x * s + t.z * c + origin.z, t1 = t.y + origin.y
            out[b * 3] = SIMD4(w0.x, w0.y, w0.z, t0)
            out[b * 3 + 1] = SIMD4(r1.x, r1.y, r1.z, t1)
            out[b * 3 + 2] = SIMD4(w2.x, w2.y, w2.z, t2)
        }
    }
}
