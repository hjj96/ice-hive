import Foundation
import Metal
import IceHiveCore

// ================================================================
//  DECALS — stains on the deck (owned by WP5 «Эффекты»; FX.metal
//  vs_decal / fs_decal_wet / fs_decal). A ring of instances that
//  changes only on events (kept in EventPool buffers, re-copied only
//  after a change), one draw (transparent item 200):
//    High       forward WET decals lit by WP2's full light model: the
//               flashlights and grid lights glint on fresh ichor, which
//               dries from roughness 0.08 to 0.62 over 45 s; the pores'
//               pink-white flecks fade in ~2.5 s; acid stays glossy with
//               a faint glow, scorch is dry soot whose embers cool,
//               frost is pale rime with glints. Ring 1600.
//    Efficient  the web's multiply stains (ring 1000; «низкая» 500).
//  Atlas Resources/FX/fx_decals.iht (4 × 2 cells, tools/fx): r coverage,
//  g thickness (wet relief), b flecks / embers / crystal glints,
//  a variation. Cells: 0 splat, 1 streak, 2 gore, 3 scorch, 4 acid
//  pool, 5 frost rime, 6 small splat, 7 drips.
// ================================================================

/// One stain (`struct DecalInstance` in FX.metal), 64 bytes.
struct DecalInstance {
    /// xyz on the deck, w = size (m, edge of the quad).
    var center: F4
    /// x cos, y sin of the roll, z deck slope along z (dy / dz), w atlas cell (0…7).
    var axis: F4
    /// rgb stain tint (multiply factor; the wet albedo follows from it), w = birth time (s).
    var color: F4
    /// x kind, y opacity, z flecks 0…1, w unused.
    var params: F4
}

final class Decals {
    enum Kind: Int { case ichor = 0, acid, scorch, frost, gore }
    /// Atlas cells.
    enum Cell: Int { case splat = 0, streak, gore, scorch, acid, frost, small, drips }

    /// Fragment buffer slot of the stains' clock (FX.metal fs_decal_wet).
    static let clockIndex = 7

    static let pipelines: [PipelineSpec] = [
        .world("decal", "vs_decal", "fs_decal", .multiply),
        .world("decalWet", "vs_decal", "fs_decal_wet", .alpha),
    ]

    let level: Level
    private(set) var items: [DecalInstance] = [] { didSet { version &+= 1 } }
    private(set) var version = 0
    private var xz: [Vec2] = []
    private(set) var ring = 1000
    private var headIdx = 0
    private var layer = 0
    /// Stains lying on the lift deck (ring index, base y) once the extraction starts.
    private var liftGore: [(Int, Float)]? = nil
    private var liftRiseLast: Float = 0
    /// Effect clock of the stains (birth times, drying): MetalEffects.clock — the effects' time (it stops with them in a
    /// frozen look-dev shot), handed to the shader per draw.
    var clock: Float = 0

    private var renderer: MetalRenderer?
    private var psMul: MTLRenderPipelineState?
    private var psWet: MTLRenderPipelineState?
    private var atlas: MTLTexture?
    /// One persistent buffer per arena slot for the largest ring (1600), made in attach() — not lazily on the first frame
    /// with stains: CI swarm3x (791d52f) logged `fx: slow frame 133 ms (upload 133.3; thread cpu 0.4 ms)` behind the
    /// loading cover, the first upload's makeBuffer waiting while the particles' compute pipelines compiled. A slot is
    /// re-copied only after a change (the EventPool rule: written only by the frame that fills the same arena slot).
    static let maxItems = 1600
    private var buffers: [MTLBuffer?] = []
    private var copied = [Int](repeating: -1, count: MetalRenderer.arenaSlots)
    private var region = Region()
    private var rng = SeededRNG(seed: 2718)

    init(level: Level) {
        self.level = level
        items.reserveCapacity(Decals.maxItems)
        xz.reserveCapacity(Decals.maxItems)
        assert(MemoryLayout<DecalInstance>.stride == 64, "DecalInstance is 64 bytes in FX.metal")
    }

    func attach(_ r: MetalRenderer) {
        renderer = r
        psMul = r.pipeline("decal")
        psWet = r.pipeline("decalWet")
        let dev = r.device
        buffers = (0..<MetalRenderer.arenaSlots).map { k in
            let b = dev.makeBuffer(length: MemoryLayout<DecalInstance>.stride * Decals.maxItems,
                                   options: [.storageModeShared, .cpuCacheModeWriteCombined])
            b?.label = "stains \(k)"
            return b
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t = FXTextures.load("fx_decals", device: dev) ?? FXTextures.flat(dev, [200, 128, 0, 128])
            DispatchQueue.main.async { self?.atlas = t }
        }
        r.register(.transparent, order: 200, "decals") { [unowned self] enc in self.encode(enc) }
    }

    /// Ring size of the tier: High 1600 (wet), Efficient 1000, «низкая» 500.
    func setTier(high: Bool, fxK: Float) {
        let n = fxK < 0.5 ? 500 : (high ? 1600 : 1000)
        if n == ring { return }
        ring = n
        headIdx = 0
        if items.count > ring { items.removeLast(items.count - ring); xz.removeLast(xz.count - ring) }
    }

    func reset() {
        items.removeAll(keepingCapacity: true)
        xz.removeAll(keepingCapacity: true)
        headIdx = 0; layer = 0
        liftGore = nil
        liftRiseLast = 0
    }

    private func walkable2(_ x: Float, _ z: Float) -> Bool {
        let c = level.cellOf(x, z)
        return c >= 0 && level.walkValue(c) != 0
    }

    /// A stain at (x, z): size (m), atlas cell, kind, multiply tint, opacity, pore flecks 0…1, roll (nil = random). It
    /// shrinks (up to 3 × 0.7) until it fits on the deck; nothing over the abyss.
    func add(_ x: Float, _ z: Float, size size0: Float, cell: Cell, kind: Kind, tint: F3, opacity: Float = 1, flecks: Float = 0,
             roll: Float? = nil) {
        let c0 = level.cellOf(x, z)
        if c0 < 0 || level.walkValue(c0) == 0 { return }
        var size = size0
        var k = 0
        while k < 3 {
            let h = size * 0.4
            if walkable2(x - h, z - h) && walkable2(x + h, z - h) && walkable2(x - h, z + h) && walkable2(x + h, z + h) { break }
            size *= 0.7
            k += 1
        }
        let gz = (level.groundY(x, z + 0.05) - level.groundY(x, z - 0.05)) / 0.1
        let gy = level.groundY(x, z) + (level.isStairCell(c0) ? 0.08 : 0)
        layer = (layer + 1) % 64
        let rot = roll ?? rng.next() * TAU
        let d = DecalInstance(center: F4(x, gy + 0.018 + Float(layer) * 0.0002, z, size),
                              axis: F4(cosf(rot), sinf(rot), gz, Float(cell.rawValue)),
                              color: F4(tint.x, tint.y, tint.z, clock),
                              params: F4(Float(kind.rawValue), opacity, flecks, 0))
        if items.count < ring {
            items.append(d); xz.append(Vec2(x, z))
        } else {
            items[headIdx] = d; xz[headIdx] = Vec2(x, z)
            if liftGore != nil { liftGore!.removeAll(where: { $0.0 == headIdx }) }
            headIdx = (headIdx + 1) % ring
        }
    }

    /// Stains lying on the lift deck ride up with it (web fxLiftRise; corpses: Corpses.liftRise).
    func liftRise(_ rise: Float) {
        if rise == liftRiseLast { return }
        liftRiseLast = rise
        if liftGore == nil {
            var list: [(Int, Float)] = []
            for (i, p) in xz.enumerated() where level.isLiftCell(level.cellOf(p.x, p.y)) { list.append((i, items[i].center.y)) }
            liftGore = list
        }
        for (i, y) in liftGore ?? [] where i < items.count { items[i].center.y = y + rise }
    }

    func upload(_ r: MetalRenderer) {
        if items.isEmpty { region = Region(); return }
        let s = r.arenaSlot
        guard s < buffers.count, let b = buffers[s], b.length >= MemoryLayout<DecalInstance>.stride * items.count else {
            region = r.upload(items)
            return
        }
        if copied[s] != version {
            items.withUnsafeBufferPointer { src in
                b.contents().bindMemory(to: DecalInstance.self, capacity: items.count).update(from: src.baseAddress!, count: items.count)
            }
            copied[s] = version
        }
        region = Region(offset: 0, count: items.count, buffer: b)
    }

    private func encode(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer, region.count > 0, let tex = atlas else { return }
        let wet = r.frameTier == .high
        guard let ps = wet ? (psWet ?? psMul) : psMul else { return }
        r.use(enc, ps)
        enc.setDepthBias(-4, slopeScale: -2, clamp: 0)
        enc.setVertexBuffer(region.buffer ?? r.arena, offset: region.offset, index: BufferIndex.instances)
        r.bindMain(enc, tex)
        var now = clock
        enc.setFragmentBytes(&now, length: MemoryLayout<Float>.stride, index: Decals.clockIndex)
        r.drawQuads(enc, region.count)
        enc.setDepthBias(0, slopeScale: 0, clamp: 0)
    }
}
