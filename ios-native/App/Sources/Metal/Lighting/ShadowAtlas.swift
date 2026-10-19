import Foundation
import Metal

// ================================================================
//  SHADOW ATLAS — flashlight shadows (owned by WP2 «Свет и воздух»).
//  One 2048 × 1024 depth atlas, rendered in the pre-pass (order 200)
//  before the world:
//     ┌──────────────┬───────┬───────┐
//     │              │ spot1 │ spot2 │   spot 0 (the player): 1024²
//     │   spot 0     │  512² │  512² │   spots 1–3 (the squad): 512²
//     │   1024²      ├───────┼───────┘   High: all four tiles;
//     │              │ spot3 │           Efficient: the player's only
//     └──────────────┴───────┘
//  Each tile is the spot's perspective (three.js SpotLightShadow: fov =
//  2 × the 0.5 rad angle, near 0.5, far 32); the casters are
//  MetalRenderer's shadow-caster items (the squad's batches, the
//  swarm's 20-triangle proxies), drawn once per tile with the tile's
//  matrix in the frame constants and a viewport + scissor on the tile.
//  Materials sample it at texture slot 3: the frame-only API's
//  spotShadow (the player's tile: FrameUniforms.shadowMatrix /
//  shadowParams, w = the tile's u scale) and the full API's
//  atlasShadow (any tile: LightBlock.spotRect / spotMatrix), both 4-tap
//  PCF of bilinear compares; the player's volumetric cone marches
//  through its tile on High (Atmosphere.metal fs_cone).
//  Format: depth32Float, the format MetalRenderer compiles depth-only
//  pipelines for (8 MB; D16 = 4 MB once the depth-only specs take
//  ShadowAtlas.format — handoff to the frame-graph owner).
//  `-noatlas`: the squad tiles stay off on High (device A/B timing).
// ================================================================
final class ShadowAtlas {
    static let width = 2048, height = 1024
    static let format: MTLPixelFormat = .depth32Float
    /// Tile rects in pixels (x, y, size): the player, then the squad.
    static let tiles: [(Int, Int, Int)] = [(0, 0, 1024), (1024, 0, 512), (1536, 0, 512), (1024, 512, 512)]
    /// three.js shadow.bias of the web build (NDC depth), PCF tap radius in texels.
    static let bias: Float = -0.0006
    static let pcfRadius: Float = 0.75

    private var renderer: MetalRenderer!
    private var hub: LightingHub!
    private var tex: MTLTexture?
    private var dummy: MTLTexture?
    private var ds: MTLDepthStencilState?
    private let pass = MTLRenderPassDescriptor()
    /// «Высокая» (fxK ≥ 0.85; MetalWorld sets it from the tier): the squad's flashlights cast shadows too (High tier).
    var enabled = false
    /// Tiles rendered this frame (bit k = spot k); the player's tile also on Efficient.
    private(set) var activeTiles = 0
    /// Spot tile matrices of this frame.
    private var matrices = [Mat4](repeating: .identity, count: 4)
    private let squadOff = LaunchOptions.current.unknown.contains("-noatlas")

    var on: Bool { activeTiles != 0 }

    /// Targets and state; register the shadow pre-pass (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        hub = LightingHub.current ?? LightingHub()
        hub.attach(r)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShadowAtlas.format, width: 1, height: 1, mipmapped: false)
        dd.usage = [.shaderRead, .renderTarget]
        dd.storageMode = .private
        dummy = r.device.makeTexture(descriptor: dd)
        // the atlas exists from the start (not created on the first «высокая» frame)
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ShadowAtlas.format, width: ShadowAtlas.width, height: ShadowAtlas.height,
                                                          mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        tex = r.device.makeTexture(descriptor: sd)
        tex?.label = "flashlight shadow atlas"
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        let s = MTLDepthStencilDescriptor()
        s.depthCompareFunction = .less
        s.isDepthWriteEnabled = true
        ds = r.device.makeDepthStencilState(descriptor: s)
        r.passTextures[TextureIndex.shadow] = dummy
        r.registerPrePass(order: 200, "shadow atlas") { [unowned self] cb in self.encode(cb) }
    }

    /// The tiles of this frame into `F` (frame-only API: the player's tile) and the light block (every tile). Call after
    /// LightGrid.fill (it reads the four spots from `F`); `spot`: the player's flashlight, nil when it is off.
    func setup(_ F: inout FrameUniforms, spot: (pos: F3, dir: F3)?) {
        let high = renderer?.frameTier == .high
        let sp = [F.spotPos.0, F.spotPos.1, F.spotPos.2, F.spotPos.3], sd = [F.spotDir.0, F.spotDir.1, F.spotDir.2, F.spotDir.3]
        activeTiles = 0
        var h = hub.header
        for k in 0..<4 {
            let lit = sp[k].w > 0
            let want = k == 0 ? (spot != nil && lit) : (high && enabled && !squadOff && lit)
            if want {
                let pos = F3(sp[k].x, sp[k].y, sp[k].z), dir = F3(sd[k].x, sd[k].y, sd[k].z)
                let view = Mat4.lookAt(eye: pos, target: pos + dir)
                matrices[k] = Mat4.perspective(fovY: 1.0, aspect: 1, near: 0.5, far: 32) * view
                activeTiles |= 1 << k
            }
            let t = ShadowAtlas.tiles[k]
            let rect = F4(Float(t.0) / Float(ShadowAtlas.width), Float(t.1) / Float(ShadowAtlas.height),
                          Float(t.2) / Float(ShadowAtlas.width), Float(t.2) / Float(ShadowAtlas.height))
            let r = want ? rect : F4(0, 0, 0, 0)
            let m = matrices[k]
            switch k {
            case 0: h.spotRect.0 = r; h.spotMatrix.0 = m
            case 1: h.spotRect.1 = r; h.spotMatrix.1 = m
            case 2: h.spotRect.2 = r; h.spotMatrix.2 = m
            default: h.spotRect.3 = r; h.spotMatrix.3 = m
            }
        }
        h.shadow = F4(ShadowAtlas.bias, 1 / Float(ShadowAtlas.width), 1 / Float(ShadowAtlas.height), ShadowAtlas.pcfRadius)
        hub.header = h
        if activeTiles & 1 != 0 {
            F.shadowMatrix = matrices[0]
            F.shadowParams = F4(1, ShadowAtlas.bias, 1 / Float(ShadowAtlas.tiles[0].2), Float(ShadowAtlas.tiles[0].2) / Float(ShadowAtlas.width))
        } else {
            F.shadowParams = F4(0, 0, 0, 0)
        }
    }

    /// Pre-pass 200: the casters into each active tile; the world pass then samples the atlas (or the dummy).
    private func encode(_ cb: MTLCommandBuffer) {
        let r = renderer!
        r.passTextures[TextureIndex.shadow] = dummy
        guard activeTiles != 0, let t = tex else { return }
        pass.depthAttachment.texture = t
        r.counters.attach(to: pass, pass: .shadow)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "shadow atlas"
        enc.setDepthStencilState(ds)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.front)
        var F = r.frame
        for k in 0..<4 where activeTiles & (1 << k) != 0 {
            let tile = ShadowAtlas.tiles[k]
            enc.setViewport(MTLViewport(originX: Double(tile.0), originY: Double(tile.1), width: Double(tile.2), height: Double(tile.2), znear: 0, zfar: 1))
            enc.setScissorRect(MTLScissorRect(x: tile.0, y: tile.1, width: tile.2, height: tile.2))
            F.shadowMatrix = matrices[k]
            enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
            r.encodeShadowCasters(enc)
        }
        enc.endEncoding()
        r.passTextures[TextureIndex.shadow] = t
    }
}
