import Foundation
import Metal
import IceHiveCore

// ================================================================
//  OVERHEAD VISIBILITY — the squad-visibility / occlusion-budget
//  metric of the overhead (Stage 1 R3; design.md §1.1.2 «Occlusion
//  budget»: the overhead covers ≤ 15 % of the deck on screen on
//  average, 25 % at worst, and never hides the squad). CI only:
//  `-ohVis` (WorldOverhead creates it). Twice a second from 1.5 s
//  after «scene ready», a pre-pass draws the game camera's view into
//  an offscreen RGBA8 frame (480 px wide): the walkable deck cells
//  (R = 1), a 0.7 × 1.75 m silhouette proxy per marine (G = (k+1)/5),
//  then the overhead in front of them with its exact cutaway
//  (Level.metal fs_overhead_vis: B = the cutaway alpha, max blend) —
//  the same geometry and the same cut points as the frame. The frame
//  is read back and measured:
//    deck covered   Σ B over the deck pixels / deck pixels (the 25 %
//                   ghost counts a quarter), and the solid share
//    marine hidden  share of each marine's proxy pixels behind a
//                   solid overhead (B > 0.5): the cutaway keeps it 0
//  `oh vis t=… deck=… covered …% solid …% | marines hidden …` per
//  sample, `oh vis summary samples=N deck mean …% worst …% marine
//  hidden worst …% → ok|FAIL (…)` after each (ci/overhead_vis.py
//  gates the last summary: mean ≤ 15 %, worst ≤ 25 %, hidden ≤ 5 %).
// ================================================================
final class OverheadVisibility {
    static let width = 480
    static let every: Double = 0.5, after: Double = 1.5
    static let deckMean: Float = 15, deckWorst: Float = 25, hiddenMax: Float = 5

    private unowned let overhead: WorldOverhead
    private unowned let renderer: MetalRenderer
    /// Stage 2 B5: a chain boss over the deck (MetalWorld sets it): its body goes into the mask too, its cutaway alpha in A —
    /// a marine behind its solid body is hidden like one behind a solid overhead (ctx.md «Readability»).
    weak var boss: WorldBoss?
    private var psFlat: MTLRenderPipelineState?, psOver: MTLRenderPipelineState?, psBoss: MTLRenderPipelineState?
    private var dsWrite: MTLDepthStencilState?, dsTest: MTLDepthStencilState?
    private var color: MTLTexture?, depth: MTLTexture?, readback: MTLBuffer?
    private var deck: MTLBuffer?, deckCount = 0
    private var size = (0, 0)
    private let pass = MTLRenderPassDescriptor()
    private let queue = DispatchQueue(label: "icehive.ohvis", qos: .utility)
    /// This frame: sample it (frame() decided), the marine proxies, the params for the mask's viewport.
    private var pending = false
    private var proxies: [F4] = []
    private var params: [F4] = []
    private var nextAt: Double = OverheadVisibility.after
    private var busy = false
    private var lastT: Double = 0
    // running summary (the analysis queue only)
    private var samples = 0
    private var deckSum: Float = 0, deckWorst: Float = 0, hiddenWorst: Float = 0
    /// Stage 2 B5: samples with the boss in the mask, the deck its body covered (reported, not gated: the occlusion budget is
    /// the overhead's — the boss is gated on the squad it hides), the worst marine it hid.
    private var bossSampled = false
    private var bossSamples = 0
    private var bossDeckSum: Float = 0, bossDeckWorst: Float = 0, bossHiddenWorst: Float = 0

    init(overhead o: WorldOverhead, renderer r: MetalRenderer) {
        overhead = o
        renderer = r
        let dev = r.device
        if let lib = dev.makeDefaultLibrary() {
            func make(_ vs: String, _ fs: String, max: Bool) -> MTLRenderPipelineState? {
                guard let v = lib.makeFunction(name: vs), let f = lib.makeFunction(name: fs) else { return nil }
                let d = MTLRenderPipelineDescriptor()
                d.label = "ohvis." + fs
                d.vertexFunction = v
                d.fragmentFunction = f
                d.colorAttachments[0].pixelFormat = .rgba8Unorm
                d.depthAttachmentPixelFormat = .depth32Float
                if max {
                    let c = d.colorAttachments[0]!
                    c.isBlendingEnabled = true
                    c.rgbBlendOperation = .max
                    c.alphaBlendOperation = .max
                    c.sourceRGBBlendFactor = .one
                    c.destinationRGBBlendFactor = .one
                    c.sourceAlphaBlendFactor = .one
                    c.destinationAlphaBlendFactor = .one
                }
                return try? dev.makeRenderPipelineState(descriptor: d)
            }
            psFlat = make("vs_overhead_vis_flat", "fs_overhead_vis_flat", max: false)
            psOver = make("vs_overhead", "fs_overhead_vis", max: true)
            psBoss = make("vs_creature", "fs_creature_vis", max: true)
        }
        let w = MTLDepthStencilDescriptor()
        w.depthCompareFunction = .less
        w.isDepthWriteEnabled = true
        dsWrite = dev.makeDepthStencilState(descriptor: w)
        let t = MTLDepthStencilDescriptor()
        t.depthCompareFunction = .lessEqual
        t.isDepthWriteEnabled = false
        dsTest = dev.makeDepthStencilState(descriptor: t)
        buildDeck()
        r.registerPrePass(order: 260, "overhead visibility") { [unowned self] cb in self.encode(cb) }
        AppLog.info("oh vis: on (\(psFlat != nil && psOver != nil ? "pipelines ok" : "PIPELINES MISSING"), \(deckCount / 6) deck cells)")
    }

    func levelChanged() { buildDeck() }

    /// The walkable deck cells as quads at their heights (world xyz, code 1).
    private func buildDeck() {
        let L = overhead.level
        var v: [F4] = []
        for c in 0..<(GRID * GRID) where L.walkValue(c) == 1 {
            let x0 = Float(c % GRID) - GRID_HALF, z0 = Float(c / GRID) - GRID_HALF
            func p(_ dx: Float, _ dz: Float) -> F4 {
                let x = x0 + dx, z = z0 + dz
                return F4(x, L.groundY(x0 + 0.5 + (dx - 0.5) * 0.998, z0 + 0.5 + (dz - 0.5) * 0.998), z, 1)
            }
            let a = p(0, 0), b = p(0, 1), cc = p(1, 1), d = p(1, 0)
            v += [a, b, cc, a, cc, d]
        }
        deckCount = v.count
        deck = v.isEmpty ? nil : v.withUnsafeBytes { renderer.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: []) }
    }

    /// MetalWorld.update (through WorldOverhead.build): due for a sample? Then this frame's proxies and params.
    func frame(game: Game, camera: MetalCamera, poses: [MetalEffects.MarinePose]) {
        pending = false
        let t = DemoScript.sceneClock
        guard t >= nextAt, !busy, psFlat != nil, psOver != nil else { return }
        nextAt = t + OverheadVisibility.every
        lastT = t
        let w = OverheadVisibility.width, h = max(64, Int((Float(w) / max(0.5, camera.aspect)).rounded()))
        if size != (w, h) { allocate(w, h) }
        proxies.removeAll(keepingCapacity: true)
        for k in 0..<min(4, poses.count) {
            let p = poses[k]
            let code = Float(2 + k)
            let lo = F3(p.x - 0.35, p.y, p.z - 0.35), hi = F3(p.x + 0.35, p.y + 1.75, p.z + 0.35)
            func c(_ i: Int) -> F4 { F4(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z, code) }
            for f in [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]] {
                proxies += [c(f[0]), c(f[1]), c(f[2]), c(f[0]), c(f[2]), c(f[3])]
            }
        }
        params = overhead.block
        params[WorldOverhead.Block.view].x = 2 / Float(w)
        params[WorldOverhead.Block.view].y = 2 / Float(h)
        pending = color != nil && readback != nil
    }

    private func allocate(_ w: Int, _ h: Int) {
        let dev = renderer.device
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .private
        color = dev.makeTexture(descriptor: cd)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        depth = dev.makeTexture(descriptor: dd)
        readback = dev.makeBuffer(length: w * h * 4, options: .storageModeShared)
        size = (w, h)
    }

    /// Pre-pass 260: the mask frame, then its copy into the readback buffer; measured when the GPU is done.
    private func encode(_ cb: MTLCommandBuffer) {
        guard pending, let ct = color, let dt = depth, let rb = readback, let pf = psFlat, let po = psOver else { return }
        pending = false
        pass.colorAttachments[0].texture = ct
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = dt
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        renderer.counters.detach(pass)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "overhead visibility"
        let (w, h) = size
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1))
        enc.setCullMode(.none)
        var F = renderer.frame
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setFragmentBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setRenderPipelineState(pf)
        enc.setDepthStencilState(dsWrite)
        if let d = deck {
            enc.setVertexBuffer(d, offset: 0, index: BufferIndex.vertices)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: deckCount)
        }
        if !proxies.isEmpty {
            proxies.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: BufferIndex.vertices) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: proxies.count)
        }
        if let (vb, ib, runs) = overhead.visDraw, !runs.isEmpty {
            enc.setRenderPipelineState(po)
            enc.setDepthStencilState(dsTest)
            enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
            params.withUnsafeBytes {
                enc.setVertexBytes($0.baseAddress!, length: $0.count, index: BufferIndex.material)
                enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: BufferIndex.material)
            }
            for (start, count) in runs {
                enc.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32, indexBuffer: ib, indexBufferOffset: start * 4)
            }
        }
        if let b = boss, let pb = psBoss, b.drawn {
            enc.setDepthStencilState(dsTest)
            b.encodeVis(enc, pipeline: pb, w: w, h: h)
            bossSampled = true
        }
        enc.endEncoding()
        guard let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: ct, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: rb, destinationOffset: 0, destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        busy = true
        let t = lastT
        let withBoss = bossSampled
        bossSampled = false
        cb.addCompletedHandler { [weak self] _ in
            guard let s = self else { return }
            s.queue.async {
                s.measure(rb, w, h, t, boss: withBoss)
                DispatchQueue.main.async { s.busy = false }
            }
        }
    }

    /// The analysis queue: measure one mask frame, log it and the running summary.
    private func measure(_ buf: MTLBuffer, _ w: Int, _ h: Int, _ t: Double, boss: Bool) {
        let p = buf.contents().bindMemory(to: UInt8.self, capacity: w * h * 4)
        var deckPx = 0, solid = 0
        var covered: Float = 0, bossCovered: Float = 0
        var px = [Int](repeating: 0, count: 4), hidden = [Int](repeating: 0, count: 4), bossHidden = [Int](repeating: 0, count: 4)
        var ghost = [Float](repeating: 0, count: 4)
        for i in 0..<(w * h) {
            let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2], a = p[i * 4 + 3]
            let cov = Float(b) / 255
            if r > 127 {
                deckPx += 1
                covered += cov
                bossCovered += Float(a) / 255
                if b > 127 { solid += 1 }
            } else if g > 25 {
                let k = Int((Float(g) / 51).rounded()) - 1
                if k >= 0 && k < 4 {
                    px[k] += 1
                    ghost[k] += max(cov, Float(a) / 255)
                    // (Stage 2 B5: behind a solid overhead or a solid boss body)
                    if b > 127 || a > 127 { hidden[k] += 1 }
                    if a > 127 { bossHidden[k] += 1 }
                }
            }
        }
        let dc = deckPx > 0 ? covered / Float(deckPx) * 100 : 0
        let ds = deckPx > 0 ? Float(solid) / Float(deckPx) * 100 : 0
        var hid = [Float](repeating: 0, count: 4), cov = [Float](repeating: 0, count: 4)
        for k in 0..<4 where px[k] > 0 {
            hid[k] = Float(hidden[k]) / Float(px[k]) * 100
            cov[k] = ghost[k] / Float(px[k])
        }
        samples += 1
        deckSum += dc
        deckWorst = max(deckWorst, dc)
        hiddenWorst = max(hiddenWorst, hid.max() ?? 0)
        var bossTail = ""
        if boss {
            let bd = deckPx > 0 ? bossCovered / Float(deckPx) * 100 : 0
            var bh: Float = 0
            for k in 0..<4 where px[k] > 0 { bh = max(bh, Float(bossHidden[k]) / Float(px[k]) * 100) }
            bossSamples += 1
            bossDeckSum += bd
            bossDeckWorst = max(bossDeckWorst, bd)
            bossHiddenWorst = max(bossHiddenWorst, bh)
            bossTail = String(format: " | boss deck %.1f%% hides %.1f%%", bd, bh)
        }
        AppLog.info(String(format: "oh vis t=%.1f deck=%d px covered %.1f%% solid %.1f%% | marines px %d/%d/%d/%d hidden %.1f/%.1f/%.1f/%.1f%% cover %.2f/%.2f/%.2f/%.2f",
                           t, deckPx, dc, ds, px[0], px[1], px[2], px[3], hid[0], hid[1], hid[2], hid[3], cov[0], cov[1], cov[2], cov[3]) + bossTail)
        if bossSamples > 0 {
            AppLog.info(String(format: "oh vis boss samples=%d deck mean %.1f%% worst %.1f%% marine hidden by it worst %.1f%%", bossSamples,
                               bossDeckSum / Float(bossSamples), bossDeckWorst, bossHiddenWorst))
        }
        let mean = deckSum / Float(samples)
        var bad: [String] = []
        if mean > OverheadVisibility.deckMean { bad.append(String(format: "deck mean %.1f%% > %.0f%%", mean, OverheadVisibility.deckMean)) }
        if deckWorst > OverheadVisibility.deckWorst { bad.append(String(format: "deck worst %.1f%% > %.0f%%", deckWorst, OverheadVisibility.deckWorst)) }
        if hiddenWorst > OverheadVisibility.hiddenMax { bad.append(String(format: "a marine %.1f%% hidden > %.0f%%", hiddenWorst, OverheadVisibility.hiddenMax)) }
        AppLog.info(String(format: "oh vis summary samples=%d deck mean %.1f%% worst %.1f%% marine hidden worst %.1f%% → ", samples, mean, deckWorst, hiddenWorst)
                    + (bad.isEmpty ? "ok" : "FAIL (" + bad.joined(separator: "; ") + ")"))
    }
}
