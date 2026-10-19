import Foundation
import Metal

// ================================================================
//  RENDER TARGETS — the world's targets (WP1 «Кадр»), allocated once at
//  the largest size asked for and never per scale change:
//    msaaColor  RG11B10Float × 4 samples   memoryless on the device
//    msaaDepth  depth32Float × 4 samples   memoryless on the device
//    scene      RG11B10Float, 1 sample     the multisample resolve
//                                          (sceneHDR), sampled by the
//                                          bloom and the composite
//    bloom[0…4] RG11B10Float ½ … 1/32 of the allocation (High starts at
//               [0], Efficient at [1])
//    distortion RG8Unorm ¼ of the allocation: heat offsets (High; 0.5 =
//               none), drawn by the .distortion stage
//  Dynamic resolution renders into a viewport (renderTargetWidth /
//  Height of the world pass) inside the allocation; the post chain
//  samples the viewport with a uv scale. A request bigger than the
//  allocation (rotation, a larger -mscale) grows it to the maximum of
//  both and is logged — once per launch in CI. The simulator has no
//  memoryless storage: there the MSAA attachments are private memory.
// ================================================================
final class RenderTargets {
    static let colorFormat: MTLPixelFormat = .rg11b10Float
    static let depthFormat: MTLPixelFormat = .depth32Float
    static let sampleCount = 4
    static let bloomLevels = 5
    static let distortionFormat: MTLPixelFormat = .rg8Unorm

    let device: MTLDevice
    private(set) var allocW = 0, allocH = 0
    /// This frame's viewport (pixels) inside the allocation.
    private(set) var viewW = 1, viewH = 1
    private(set) var msaaColor: MTLTexture?
    private(set) var msaaDepth: MTLTexture?
    private(set) var scene: MTLTexture?
    private(set) var bloom: [MTLTexture] = []
    private(set) var distortion: MTLTexture?
    /// Allocations since launch (1 = never reallocated).
    private(set) var allocations = 0
    /// The world pass: clear, draw, resolve the samples into `scene` (depth never stored).
    let worldPass = MTLRenderPassDescriptor()

    init(device: MTLDevice) {
        self.device = device
        let c = worldPass.colorAttachments[0]!
        c.loadAction = .clear
        c.storeAction = .multisampleResolve
        worldPass.depthAttachment.loadAction = .clear
        worldPass.depthAttachment.storeAction = .dontCare
        worldPass.depthAttachment.clearDepth = 1
    }

    /// Colour the world pass clears to (linear radiance: the fog).
    func setClearColor(_ c: F3) {
        worldPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1)
    }

    /// Make sure the allocation holds `w × h` pixels (grows only). true = (re)allocated (the old image is gone).
    @discardableResult
    func ensure(width w0: Int, height h0: Int) -> Bool {
        let w = max(1, w0), h = max(1, h0)
        if w <= allocW && h <= allocH && scene != nil { return false }
        let w2 = max(w, allocW), h2 = max(h, allocH)
        let t0 = FrameTimer.now()
        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int, memoryless: Bool, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = memoryless ? .renderTarget : [.renderTarget, .shaderRead]
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            #if targetEnvironment(simulator)
            d.storageMode = .private
            #else
            d.storageMode = memoryless ? .memoryless : .private
            #endif
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }
        let n = RenderTargets.sampleCount
        msaaColor = tex(RenderTargets.colorFormat, w2, h2, samples: n, memoryless: true, "world msaa")
        msaaDepth = tex(RenderTargets.depthFormat, w2, h2, samples: n, memoryless: true, "world depth")
        scene = tex(RenderTargets.colorFormat, w2, h2, samples: 1, memoryless: false, "sceneHDR")
        bloom = []
        var bw = w2, bh = h2
        for k in 0..<RenderTargets.bloomLevels {
            bw = max(1, bw / 2); bh = max(1, bh / 2)
            if let t = tex(RenderTargets.colorFormat, bw, bh, samples: 1, memoryless: false, "bloom\(k)") { bloom.append(t) }
        }
        distortion = tex(RenderTargets.distortionFormat, max(1, w2 / 4), max(1, h2 / 4), samples: 1, memoryless: false, "distortion")
        allocW = w2; allocH = h2
        allocations += 1
        let c = worldPass.colorAttachments[0]!
        c.texture = msaaColor
        c.resolveTexture = scene
        worldPass.depthAttachment.texture = msaaDepth
        setViewport(width: min(viewW, w2), height: min(viewH, h2))
        #if targetEnvironment(simulator)
        let mem = "MSAA private (simulator)"
        #else
        let mem = "MSAA memoryless"
        #endif
        AppLog.info("metal: world target \(w2)x\(h2) px (allocation \(allocations), RG11B10F, \(n)x MSAA, " + mem
                    + String(format: ", scene + bloom %.1f MB) in %.1f ms", Double(bytes) / 1_048_576, (FrameTimer.now() - t0) * 1000))
        return true
    }

    /// Bytes of the stored targets (the scene and the bloom levels; MSAA is tile memory on the device).
    var bytes: Int {
        var b = allocW * allocH * 4
        var bw = allocW, bh = allocH
        for _ in 0..<bloom.count { bw = max(1, bw / 2); bh = max(1, bh / 2); b += bw * bh * 4 }
        return b + max(1, allocW / 4) * max(1, allocH / 4) * 2
    }

    /// This frame's viewport (clamped to the allocation): the world pass renders only there.
    func setViewport(width: Int, height: Int) {
        viewW = max(1, min(width, max(1, allocW)))
        viewH = max(1, min(height, max(1, allocH)))
        worldPass.renderTargetWidth = viewW
        worldPass.renderTargetHeight = viewH
    }

    /// uv extent of the viewport in `scene` (and the scene's texel size).
    var sceneUV: F4 {
        F4(Float(viewW) / Float(max(1, allocW)), Float(viewH) / Float(max(1, allocH)), 1 / Float(max(1, allocW)), 1 / Float(max(1, allocH)))
    }
}
