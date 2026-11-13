import Foundation
import Metal
import IceHiveCore

// ================================================================
//  OCCUPANCY — where the swarm and the squad stand (owned by WP2 «Свет
//  и воздух»): a 256² RG8 map over the level's 128 × 128 m (0.5 m a
//  texel), rendered in pre-pass 150 before the world:
//    R  contact occlusion of this frame: one soft blob per live bug and
//       marine (overlapping blobs add up: a crowd darkens the deck
//       under it) — the deck / props shade it as contact shadow
//    G  trails: every blob also adds a little to G, and G fades with a
//       half-life of ~8 s — trampled snow, ichor smeared by the crowd
//  Two textures ping-pong: the fade pass reads last frame's map and
//  writes R = 0, G × decay (stochastic rounding by interleaved
//  gradient noise, so 8-bit trails fade all the way out), then the
//  blobs add on top. Materials read it through Lighting.h
//  (occupancyAt / contactAO, shadeLit's contact occlusion) at texture
//  slot 5. Cost: one 256² pass + ≤ 2600 tiny quads (≈ 0.03 ms).
// ================================================================
final class Occupancy {
    static let size = 256
    static let worldMin: Float = -64, worldSize: Float = 128
    /// Contact occlusion strength at a fully covered texel (LightBlock.ambient.z) and the trail half-life (s).
    static let contactStrength: Float = 0.55
    static let trailHalfLife: Double = 8
    /// Blobs: bug radius per unit of scale (m), contact per bug, trail gain per frame (× contact).
    static let bugRadius: Float = 0.5, bugContact: Float = 0.38, marineRadius: Float = 0.62, marineContact: Float = 0.6, trailGain: Float = 0.035
    static let maxBlobs = 2700

    // the RG8 target: the format and blending of the heat-distortion stage (PipelineSpec.Target.distortion: RG8Unorm,
    // one sample, no depth)
    static let pipelines: [PipelineSpec] = [
        PipelineSpec(label: "occFade", vertex: "vs_occ_fade", fragment: "fs_occ_fade", blend: .none, layout: nil, target: .distortion, required: false),
        PipelineSpec(label: "occBlob", vertex: "vs_occ_blob", fragment: "fs_occ_blob", blend: .add, layout: nil, target: .distortion, required: false),
    ]

    private var renderer: MetalRenderer!
    private var hub: LightingHub!
    private var maps: [MTLTexture] = []
    private var current = 0
    private var cleared = false
    private var psFade: MTLRenderPipelineState?, psBlob: MTLRenderPipelineState?
    private let pass = MTLRenderPassDescriptor()
    private var blobs: [F4] = []
    /// Blobs of the last collected frame (hb light).
    var blobCount: Int { blobs.count }
    private var lastEncode: Double = 0
    private var frameSeed: Float = 0

    func attach(_ r: MetalRenderer, hub h: LightingHub) {
        renderer = r
        hub = h
        hub.occupancy = self
        psFade = r.pipeline("occFade"); psBlob = r.pipeline("occBlob")
        for k in 0..<2 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg8Unorm, width: Occupancy.size, height: Occupancy.size, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            if let t = r.device.makeTexture(descriptor: d) { t.label = "occupancy \(k)"; maps.append(t) }
        }
        blobs.reserveCapacity(Occupancy.maxBlobs)
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        r.registerPrePass(order: 150, "occupancy") { [unowned self] cb in self.encode(cb) }
    }

    /// Stage 2 B5: blobs another module asks for this frame (x, z, radius, contact) — a boss's strike shadow growing on the
    /// deck as its head comes down, the coil's shade (WorldBoss); taken and cleared by `collect`.
    static var extra: [F4] = []

    /// This frame's blobs: every live bug and standing marine (LightGrid.fill calls this with the simulation).
    func collect(game: Game, poses: [MetalEffects.MarinePose]) {
        blobs.removeAll(keepingCapacity: true)
        let S = game.bugs
        let X = S.xs, Z = S.zs, SC = S.scales, dead = S.deadFlags, Y = S.heights
        for i in 0..<S.count where dead[i] == 0 && blobs.count < Occupancy.maxBlobs - 4 {
            // (Stage 2 B5: a boss's chain part stands on the deck only when it is low — the coil's ring, the deck chase; up on
            // the trunks it leaves no contact blob or trail under it)
            if S.bossPart(i) >= 0 && Y[i] - game.level.groundY(X[i], Z[i]) > 1.2 { continue }
            blobs.append(F4(X[i], Z[i], Occupancy.bugRadius * SC[i], Occupancy.bugContact))
        }
        for b in Occupancy.extra where blobs.count < Occupancy.maxBlobs { blobs.append(b) }
        Occupancy.extra.removeAll(keepingCapacity: true)
        for (k, m) in game.marines.enumerated() where k < poses.count && !m.downed {
            blobs.append(F4(poses[k].x, poses[k].z, Occupancy.marineRadius, Occupancy.marineContact))
        }
        // Stage 1 R3: a drop warning's growing dark shadow on the deck (design §1.1.4: «a closing ring and a growing dark
        // shadow»): a soft blob inside the ring, darkening as the drop nears (no drop zones on the classic station)
        for z in game.dropZones where z.active && blobs.count < Occupancy.maxBlobs {
            let p = z.progress
            blobs.append(F4(z.x, z.z, z.radius * (0.55 + 0.3 * p), 0.2 + 0.6 * p))
        }
    }

    /// Pre-pass 150: fade last frame's map into the other texture, add this frame's blobs; the world binds the result.
    private func encode(_ cb: MTLCommandBuffer) {
        guard maps.count == 2, let fade = psFade, let blob = psBlob else { hub.occTexture = nil; hub.header.occ.w = 0; return }
        let r = renderer!
        let now = FrameTimer.now()
        let dt = lastEncode > 0 ? min(0.25, now - lastEncode) : 0
        lastEncode = now
        let src = maps[current], dst = maps[1 - current]
        current = 1 - current
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = cleared ? .dontCare : .clear
        r.counters.detach(pass)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "occupancy"
        if cleared {
            frameSeed = frameSeed > 4096 ? 0 : frameSeed + 1
            var p = F4(Float(pow(0.5, dt / Occupancy.trailHalfLife)), frameSeed, 0, 0)
            enc.setRenderPipelineState(fade)
            enc.setFragmentBytes(&p, length: MemoryLayout<F4>.stride, index: 0)
            enc.setFragmentTexture(src, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        cleared = true
        if !blobs.isEmpty {
            let reg = r.upload(blobs)
            if reg.count > 0 {
                var m = F4(Occupancy.worldMin, Occupancy.worldMin, 1 / Occupancy.worldSize, Occupancy.trailGain * Float(min(1, dt * 60)))
                enc.setRenderPipelineState(blob)
                enc.setVertexBuffer(r.arena, offset: reg.offset, index: BufferIndex.instances)
                enc.setVertexBytes(&m, length: MemoryLayout<F4>.stride, index: BufferIndex.material)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: reg.count)
            }
        }
        enc.endEncoding()
        hub.occTexture = dst
        hub.header.occ = F4(Occupancy.worldMin, Occupancy.worldMin, 1 / Occupancy.worldSize, 1)
    }
}
