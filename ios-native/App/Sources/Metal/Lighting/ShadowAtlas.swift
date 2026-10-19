import Foundation
import Metal

// ================================================================
//  SHADOW ATLAS — flashlight shadows (owned by WP2 «Свет и воздух»).
//  Today the web's «высокая» shadow: the player's flashlight (spot 0)
//  renders a 1024² depth map (three.js SpotLightShadow: fov = 2 ×
//  angle, near 0.5, far = distance 32) in a pre-pass (order 200)
//  before the world; the casters are MetalRenderer's shadow-caster
//  items (the squad's batches, the swarm's proxies). The world pass
//  samples it at texture slot 3 (Lighting.h spotShadow, 3 × 3 PCF).
//  WP2 grows it into the 4-spot D16 atlas (player 1024² + 3 × 512²).
// ================================================================
final class ShadowAtlas {
    static let size = 1024

    private var renderer: MetalRenderer!
    private var tex: MTLTexture?
    private var dummy: MTLTexture?
    private var ds: MTLDepthStencilState?
    private let pass = MTLRenderPassDescriptor()
    /// «Высокая»: the player's flashlight casts shadows (MetalWorld sets it from the tier).
    var enabled = false
    /// The pass runs this frame (enabled and the player's flashlight is on).
    private(set) var on = false

    /// Targets and state; register the shadow pre-pass (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
        dd.usage = [.shaderRead, .renderTarget]
        dd.storageMode = .private
        dummy = r.device.makeTexture(descriptor: dd)
        // the flashlight shadow map exists from the start (not created on the first «высокая» frame)
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: ShadowAtlas.size, height: ShadowAtlas.size,
                                                          mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        tex = r.device.makeTexture(descriptor: sd)
        tex?.label = "flashlight shadow"
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        let s = MTLDepthStencilDescriptor()
        s.depthCompareFunction = .less
        s.isDepthWriteEnabled = true
        ds = r.device.makeDepthStencilState(descriptor: s)
        r.passTextures[TextureIndex.shadow] = dummy
        r.registerPrePass(order: 200, "shadow") { [unowned self] cb in self.encode(cb) }
    }

    /// The shadow camera of this frame into `F` (`spot`: the player's flashlight, nil when it is off).
    func setup(_ F: inout FrameUniforms, spot: (pos: F3, dir: F3)?) {
        on = enabled && spot != nil
        if let s = spot, on {
            let view = Mat4.lookAt(eye: s.pos, target: s.pos + s.dir)
            F.shadowMatrix = Mat4.perspective(fovY: 1.0, aspect: 1, near: 0.5, far: 32) * view
            F.shadowParams = F4(1, -0.0006, 1 / Float(ShadowAtlas.size), 0)
        } else {
            F.shadowParams = F4(0, 0, 0, 0)
        }
    }

    /// Pre-pass 200: the casters into the depth map; the world pass then samples the map (or the dummy).
    private func encode(_ cb: MTLCommandBuffer) {
        let r = renderer!
        r.passTextures[TextureIndex.shadow] = dummy
        guard on, let t = tex else { return }
        pass.depthAttachment.texture = t
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "shadow"
        var F = r.frame
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setDepthStencilState(ds)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.front)
        r.encodeShadowCasters(enc)
        enc.endEncoding()
        r.passTextures[TextureIndex.shadow] = t
    }
}
