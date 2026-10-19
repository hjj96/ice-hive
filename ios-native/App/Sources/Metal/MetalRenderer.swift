import Foundation
import Metal
import QuartzCore

// ================================================================
//  METAL RENDERER — the frame graph of the world (WP1 «Кадр»): the
//  pipeline registry, the per-frame upload arena (a ring of three;
//  FrameLoop keeps at most two frames on the GPU), the pass scheduler
//  and the world target. One command buffer per frame (FrameLoop):
//
//    pre-passes     registerPrePass    compute / depth passes before    → own targets
//                                      the world (shadow: ShadowAtlas)
//    world          stage .opaque      level, mesh batches (squad,      → worldColor (world scale, 2x)
//                                      props, corpses), swarm             + depth (memoryless on device)
//                   stage .transparent haze, pad, glows, decals, floor
//                                      sprites, glints, particles,
//                                      ribbons, weather — same encoder
//    post slot      —                  HDR resolve, bloom, tone map, grade
//    composite      encodeComposite    world image → drawable at the screen's native scale (opens the final pass)
//    HUD            SKRenderer         same encoder as the composite (FrameLoop), then one present
//
//  Modules (one per package: WorldLevel, WorldSquad, WorldSwarm,
//  Corpses, GroundGlyphs, MetalEffects, LightGrid, ShadowAtlas,
//  Atmosphere) declare their pipelines as PipelineSpecs (compiled
//  together, in parallel, behind the loading cover) and register draw
//  items with an order key per stage; encodeWorld runs the stages in
//  order. Order keys in use (keep gaps for new items):
//    pre-pass     100 compute (particles) · 150 occupancy · 200 shadow
//    opaque       100 floors · 110 level props · 120 hazard strips · 200 mesh batches · 300 swarm
//    transparent  100 haze · 110 pad mark · 120 floor glows · 200 decals · 300 glow sprites · 310 progress rings
//                 · 320 ring sprites · 330 fill · 340 lanes · 400 glints · 500 particles (alpha) · 510 (add)
//                 · 600 ribbons · 700 weather
//    casters      100 mesh batches (castsShadow) · 200 swarm proxies
//  Draw items share the world encoder: an item that changes depth
//  bias, cull mode or depth state restores it. Pipelines / the main
//  texture are bound through use() / bindMain() (redundant binds
//  skipped).
// ================================================================

/// Vertex buffer layouts of the mesh pipelines (buffer BufferIndex.vertices).
enum VertexLayout {
    /// IHM1 (tools/export-meshes.mjs): float3 position, float3 normal, float3 colour, float aGlow, float3 aLeg — 52 B.
    case ihm1

    var descriptor: MTLVertexDescriptor {
        let vd = MTLVertexDescriptor()
        switch self {
        case .ihm1:
            let attrs: [(MTLVertexFormat, Int)] = [(.float3, 0), (.float3, 12), (.float3, 24), (.float, 36), (.float3, 40)]
            for (k, a) in attrs.enumerated() {
                vd.attributes[k].format = a.0
                vd.attributes[k].offset = a.1
                vd.attributes[k].bufferIndex = BufferIndex.vertices
            }
            vd.layouts[BufferIndex.vertices].stride = MeshStore.stride
            vd.layouts[BufferIndex.vertices].stepFunction = .perVertex
        }
        return vd
    }
}

/// Colour blending of a world pipeline.
enum BlendMode { case none, alpha, add, multiply }

/// One render pipeline a module draws with, compiled by MetalRenderer.compilePipelines.
struct PipelineSpec {
    enum Target {
        /// The world pass: colour (MetalRenderer.worldFormat) + depth.
        case world
        /// Depth only (shadow maps): no colour attachment, no fragment stage.
        case depthOnly
    }
    let label: String
    let vertex: String
    let fragment: String?
    let blend: BlendMode
    let layout: VertexLayout?
    let target: Target
    /// The world cannot be drawn without it: a failure shows the Metal failure screen instead of a broken frame.
    let required: Bool

    static func world(_ label: String, _ vs: String, _ fs: String, _ blend: BlendMode = .none, _ layout: VertexLayout? = nil,
                      required: Bool = false) -> PipelineSpec {
        PipelineSpec(label: label, vertex: vs, fragment: fs, blend: blend, layout: layout, target: .world, required: required)
    }

    static func depthOnly(_ label: String, _ vs: String, _ layout: VertexLayout? = nil) -> PipelineSpec {
        PipelineSpec(label: label, vertex: vs, fragment: nil, blend: .none, layout: layout, target: .depthOnly, required: false)
    }
}

/// Where a draw item runs (see the order keys in the header).
enum WorldStage { case opaque, transparent, shadowCasters }

/// A slice of the current frame's upload arena.
struct Region {
    var offset: Int = 0
    var count: Int = 0
    /// nil: this frame's arena; otherwise a persistent buffer (`EventPool`).
    var buffer: MTLBuffer? = nil
}

/// Which pipeline draws a mesh batch.
enum MeshPass: Int {
    /// MeshStandardMaterial with vertex colours + aGlow (marines, turret, medkits).
    case props
    /// Lambert with the instance colour (corpses).
    case lambert
    /// MeshBasicMaterial (glob, grenade, beacon tips).
    case unlit
}

/// Instanced draw of one exported mesh.
final class MeshBatch {
    let mesh: GPUMesh
    let pass: MeshPass
    /// Material constants (roughness, metalness, snow caps, glow).
    let material: MaterialUniforms
    var instances: [MeshInstance] = []
    var region = Region()
    /// Drawn into the flashlight shadow map (the squad: makeMarine castShadow).
    let castsShadow: Bool

    init(mesh: GPUMesh, pass: MeshPass, roughness: Float = 0.62, metalness: Float = 0.45, glow: Float = 2.2, snow: Bool = false,
         castsShadow: Bool = false, receivesShadow: Bool = false) {
        self.mesh = mesh
        self.pass = pass
        self.castsShadow = castsShadow
        material = MaterialUniforms(pbr: F4(roughness, metalness, snow ? 1 : 0, glow), floor: F4(0, 0, 0, receivesShadow ? 1 : 0))
        instances.reserveCapacity(8)
    }
}

/// The mesh batches one frame draws (MetalRenderer's batch service: opaque item 200, shadow casters item 100).
final class DrawList {
    var batches: [MeshBatch] = []
}

final class MetalRenderer {
    /// Upload arenas in the ring: one more than FrameLoop.framesInFlight, so the CPU never writes an arena the GPU reads.
    static let arenaSlots = 3
    /// Swarm speckles drawn again as anti-aliased dots (`-glintDots`; not in the web build). Off by default: at the 2x
    /// drawable the plain speckles match store 2-swarm.png's sparkle (blob count / size) better than the dots.
    static var glintDots = false
    private static let passOrder: [MeshPass] = [.props, .lambert, .unlit]
    /// Bytes per arena: the heaviest frame (high tier: 2500 bugs, 4000 + 2400 particles, 1500 stains, 520 corpses) needs
    /// ≈ 1 MB; an overflow drops that frame's later uploads and is logged once.
    static let arenaSize = 2 * 1024 * 1024

    /// The batch service's own pipelines (vertex functions in Characters.metal, fs_props in Level.metal).
    static let pipelines: [PipelineSpec] = [
        .world("meshProps", "vs_mesh", "fs_props", .none, .ihm1, required: true),
        .world("meshLambert", "vs_mesh", "fs_lambert", .none, .ihm1),
        .world("meshUnlit", "vs_mesh", "fs_unlit", .none, .ihm1),
        .depthOnly("shadowMesh", "vs_shadow_mesh", .ihm1),
    ]

    let device: MTLDevice
    let queue: MTLCommandQueue
    let store: MeshStore
    /// The world target's colour format (display-referred today; .rgba16Float once tone mapping moves to a post pass).
    let worldFormat: MTLPixelFormat = .bgra8Unorm
    /// The drawable's format (CAMetalLayer.pixelFormat, FrameLoop): the composite and the HUD write it.
    let drawableFormat: MTLPixelFormat = .bgra8Unorm
    let depthFormat: MTLPixelFormat = .depth32Float

    // pipelines by label (PipelineSpec), plus the composite
    private var pipelineStates: [String: MTLRenderPipelineState] = [:]
    private var psMesh: [MTLRenderPipelineState?] = [nil, nil, nil]
    private var psShadowMesh: MTLRenderPipelineState?
    /// World target → drawable (no depth: the HUD shares this pass).
    private var psComposite: MTLRenderPipelineState?
    private(set) var dsOpaque: MTLDepthStencilState?
    private(set) var dsTransparent: MTLDepthStencilState?
    private(set) var ready = false
    private(set) var pipelineErrors: [String] = []

    // per-frame upload arena
    private var arenas: [MTLBuffer] = []
    private var arenaIndex = 0
    private var arenaOffset = 0
    private var arenaOverflow = false

    /// FrameLoop got a free frame slot this tick: MetalWorld may build a frame into the arena.
    var frameOpen = false
    /// MetalWorld built a complete frame this tick (encodeWorld draws it).
    var built = false
    /// The world target holds a finished image (kept on screen while the world is frozen behind a menu).
    private(set) var hasWorldImage = false
    // offscreen world target at the world scale: colour (sampled by the composite) + depth (never stored)
    private var worldColor: MTLTexture?
    private var worldDepth: MTLTexture?
    private let worldPass = MTLRenderPassDescriptor()
    private(set) var targetWidth = 0
    private(set) var targetHeight = 0

    var frame = FrameUniforms()
    let list = DrawList()
    /// Fragment textures bound for the whole world pass by slot (TextureIndex): 1 snow mask (WorldLevel), 2 particle
    /// noise, 3 flashlight shadow map (ShadowAtlas sets it every frame; nil binds nothing).
    var passTextures = [MTLTexture?](repeating: nil, count: 4)

    // the pass scheduler
    typealias PassEncode = (MTLRenderCommandEncoder) -> Void
    private struct DrawItem { let order: Int; let label: String; let encode: PassEncode }
    private struct PrePass { let order: Int; let label: String; let encode: (MTLCommandBuffer) -> Void }
    private var opaqueItems: [DrawItem] = []
    private var transparentItems: [DrawItem] = []
    private var casterItems: [DrawItem] = []
    private var prePasses: [PrePass] = []

    /// Pipeline / texture last bound by use() / bindMain() in the world encoder (redundant state changes are skipped).
    private var boundPipeline: MTLRenderPipelineState?
    private var boundMain: MTLTexture?

    // stats of the last encoded world frame (encode time smoothed)
    private(set) var drawCalls = 0
    private(set) var instanceCount = 0
    private(set) var triangles = 0
    private(set) var encodeMs: Double = 0
    private(set) var frames = 0

    /// `queue`: the app's one command queue (FrameLoop commits every frame on it).
    init?(device: MTLDevice, queue: MTLCommandQueue, store: MeshStore) {
        self.device = device
        self.queue = queue
        self.store = store
        for k in 0..<MetalRenderer.arenaSlots {
            guard let b = device.makeBuffer(length: MetalRenderer.arenaSize, options: [.storageModeShared, .cpuCacheModeWriteCombined]) else { return nil }
            b.label = "arena\(k)"
            arenas.append(b)
        }
    }

    // ---------------------------------------------------------------- setup
    /// Compile every pipeline of `specs` (call once, off the main thread; it may run while the MeshStore loads).
    func compilePipelines(_ specs: [PipelineSpec]) -> String {
        let t0 = FrameTimer.now()
        guard let lib = device.makeDefaultLibrary() else {
            pipelineErrors.append("no default library")
            return "pipelines: no default Metal library"
        }
        let errLock = NSLock()
        func fail(_ s: String) { errLock.lock(); pipelineErrors.append(s); errLock.unlock() }
        func make(_ sp: PipelineSpec) -> MTLRenderPipelineState? {
            guard let v = lib.makeFunction(name: sp.vertex) else { fail("\(sp.label): missing function \(sp.vertex)"); return nil }
            let d = MTLRenderPipelineDescriptor()
            d.label = sp.label
            d.vertexFunction = v
            d.vertexDescriptor = sp.layout?.descriptor
            switch sp.target {
            case .depthOnly:
                d.fragmentFunction = nil
                d.colorAttachments[0].pixelFormat = .invalid
                d.depthAttachmentPixelFormat = .depth32Float
            case .world:
                guard let fn = sp.fragment, let f = lib.makeFunction(name: fn) else {
                    fail("\(sp.label): missing function \(sp.vertex) / \(sp.fragment ?? "-")")
                    return nil
                }
                d.fragmentFunction = f
                d.depthAttachmentPixelFormat = depthFormat
                let c = d.colorAttachments[0]!
                c.pixelFormat = worldFormat
                switch sp.blend {
                case .none:
                    c.isBlendingEnabled = false
                case .alpha:
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .sourceAlpha
                    c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    c.sourceAlphaBlendFactor = .one
                    c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                case .add:
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .sourceAlpha
                    c.destinationRGBBlendFactor = .one
                    c.sourceAlphaBlendFactor = .zero
                    c.destinationAlphaBlendFactor = .one
                case .multiply:
                    c.isBlendingEnabled = true
                    c.sourceRGBBlendFactor = .destinationColor
                    c.destinationRGBBlendFactor = .zero
                    c.sourceAlphaBlendFactor = .zero
                    c.destinationAlphaBlendFactor = .one
                }
            }
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                fail("\(sp.label): \(error.localizedDescription)")
                return nil
            }
        }
        // every pipeline compiles in parallel (device-specific compilation dominates a cold first launch)
        var states = [MTLRenderPipelineState?](repeating: nil, count: specs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: specs.count) { i in
            let st = make(specs[i])
            lock.lock(); states[i] = st; lock.unlock()
        }
        var missingRequired: [String] = []
        for (i, sp) in specs.enumerated() {
            if let s = states[i] { pipelineStates[sp.label] = s } else if sp.required { missingRequired.append(sp.label) }
        }
        psMesh = MetalRenderer.passOrder.map { p -> MTLRenderPipelineState? in
            switch p {
            case .props: return pipelineStates["meshProps"]
            case .lambert: return pipelineStates["meshLambert"]
            case .unlit: return pipelineStates["meshUnlit"]
            }
        }
        psShadowMesh = pipelineStates["shadowMesh"]

        let od = MTLDepthStencilDescriptor()
        od.depthCompareFunction = .less
        od.isDepthWriteEnabled = true
        dsOpaque = device.makeDepthStencilState(descriptor: od)
        let td = MTLDepthStencilDescriptor()
        td.depthCompareFunction = .lessEqual
        td.isDepthWriteEnabled = false
        dsTransparent = device.makeDepthStencilState(descriptor: td)
        // world target → drawable: the final pass has no depth attachment (SKRenderer draws the HUD into it)
        if let v = lib.makeFunction(name: "vs_composite"), let f = lib.makeFunction(name: "fs_composite") {
            let d = MTLRenderPipelineDescriptor()
            d.label = "composite"
            d.vertexFunction = v
            d.fragmentFunction = f
            d.colorAttachments[0].pixelFormat = drawableFormat
            d.depthAttachmentPixelFormat = .invalid
            do { psComposite = try device.makeRenderPipelineState(descriptor: d) } catch {
                pipelineErrors.append("composite: \(error.localizedDescription)")
            }
        } else {
            pipelineErrors.append("composite: missing vs_composite / fs_composite")
        }
        ready = missingRequired.isEmpty && psComposite != nil && dsOpaque != nil && dsTransparent != nil
        return String(format: "pipelines built in %.0f ms (%d)", (FrameTimer.now() - t0) * 1000, pipelineStates.count + (psComposite == nil ? 0 : 1))
            + (pipelineErrors.isEmpty ? "" : " ERRORS: " + pipelineErrors.joined(separator: "; "))
    }

    /// A compiled pipeline by its PipelineSpec label (nil: it failed to compile — the module skips that draw).
    func pipeline(_ label: String) -> MTLRenderPipelineState? { pipelineStates[label] }

    /// Pass-wide state that needs the loaded store (after MeshStore.loadAll and compilePipelines).
    func bindResources() {
        passTextures[TextureIndex.noise] = store.noise
        let fogc = displayRGB(0x1a2737)
        worldPass.colorAttachments[0].loadAction = .clear
        worldPass.colorAttachments[0].storeAction = .store
        worldPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(fogc.x), green: Double(fogc.y), blue: Double(fogc.z), alpha: 1)
        worldPass.depthAttachment.loadAction = .clear
        worldPass.depthAttachment.storeAction = .dontCare
        worldPass.depthAttachment.clearDepth = 1
    }

    /// Size the offscreen world target (pixels); a new size drops the old image.
    func setTargetSize(width: Int, height: Int) {
        let w = max(1, width), h = max(1, height)
        if w == targetWidth && h == targetHeight && worldColor != nil { return }
        targetWidth = w
        targetHeight = h
        hasWorldImage = false
        let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: worldFormat, width: w, height: h, mipmapped: false)
        cd.usage = [.renderTarget, .shaderRead]
        cd.storageMode = .private
        worldColor = device.makeTexture(descriptor: cd)
        worldColor?.label = "world"
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthFormat, width: w, height: h, mipmapped: false)
        dd.usage = .renderTarget
        // tile memory only on the device (the depth is never stored); the simulator has no memoryless storage
        #if targetEnvironment(simulator)
        dd.storageMode = .private
        #else
        dd.storageMode = .memoryless
        #endif
        worldDepth = device.makeTexture(descriptor: dd)
        worldPass.colorAttachments[0].texture = worldColor
        worldPass.depthAttachment.texture = worldDepth
        AppLog.info("metal: world target \(w)x\(h) px")
    }

    // ---------------------------------------------------------------- scheduler
    /// Add a draw item to a stage of the world frame (call once, after the pipelines are compiled; main thread).
    func register(_ stage: WorldStage, order: Int, _ label: String, _ encode: @escaping PassEncode) {
        let item = DrawItem(order: order, label: label, encode: encode)
        switch stage {
        case .opaque: opaqueItems.append(item); opaqueItems.sort { $0.order < $1.order }
        case .transparent: transparentItems.append(item); transparentItems.sort { $0.order < $1.order }
        case .shadowCasters: casterItems.append(item); casterItems.sort { $0.order < $1.order }
        }
    }

    /// Add a pass that runs on the frame's command buffer before the world pass (compute, shadow maps).
    func registerPrePass(order: Int, _ label: String, _ encode: @escaping (MTLCommandBuffer) -> Void) {
        prePasses.append(PrePass(order: order, label: label, encode: encode))
        prePasses.sort { $0.order < $1.order }
    }

    /// Drop every registered item (the world that registered them is going away).
    func clearRegistrations() {
        opaqueItems.removeAll(); transparentItems.removeAll(); casterItems.removeAll(); prePasses.removeAll()
    }

    /// The shadow casters into an open depth-only encoder (ShadowAtlas calls this inside its pass).
    func encodeShadowCasters(_ enc: MTLRenderCommandEncoder) {
        for it in casterItems { it.encode(enc) }
    }

    // ---------------------------------------------------------------- arena
    /// FrameLoop holds a free frame slot: start filling the next arena of the ring (never waits — FrameLoop keeps at
    /// most two frames on the GPU, so the arena after the newest in-flight one is free).
    func beginFrame() {
        frameOpen = true
        built = false
        arenaIndex = (arenaIndex + 1) % MetalRenderer.arenaSlots
        arenaOffset = 0
        list.batches.removeAll(keepingCapacity: true)
    }

    /// Room for `count` values of T in this frame's arena (256-byte aligned); nil when the arena is full.
    func alloc<T>(_ type: T.Type, _ count: Int) -> (UnsafeMutablePointer<T>, Int)? {
        let size = MemoryLayout<T>.stride * max(1, count)
        let start = (arenaOffset + 255) & ~255
        if start + size > MetalRenderer.arenaSize {
            if !arenaOverflow { arenaOverflow = true; AppLog.error("metal: frame arena full (\(start + size) bytes)") }
            return nil
        }
        arenaOffset = start + size
        let p = (arenas[arenaIndex].contents() + start).bindMemory(to: T.self, capacity: max(1, count))
        return (p, start)
    }

    /// Copy an array into the arena.
    func upload<T>(_ values: [T]) -> Region {
        if values.isEmpty { return Region() }
        guard let a = alloc(T.self, values.count) else { return Region() }
        values.withUnsafeBufferPointer { src in a.0.update(from: src.baseAddress!, count: values.count) }
        return Region(offset: a.1, count: values.count)
    }

    /// Copy two arrays into one contiguous region (one instanced draw for both, `a` first).
    func upload<T>(_ a: [T], _ b: [T]) -> Region {
        if b.isEmpty { return upload(a) }
        if a.isEmpty { return upload(b) }
        guard let r = alloc(T.self, a.count + b.count) else { return Region() }
        a.withUnsafeBufferPointer { src in r.0.update(from: src.baseAddress!, count: a.count) }
        b.withUnsafeBufferPointer { src in (r.0 + a.count).update(from: src.baseAddress!, count: b.count) }
        return Region(offset: r.1, count: a.count + b.count)
    }

    /// The arena slot this frame fills (EventPool keeps one copy per slot).
    var arenaSlot: Int { arenaIndex }
    /// The buffer behind this frame's arena regions (Region.buffer == nil).
    var arena: MTLBuffer { arenas[arenaIndex] }

    // ---------------------------------------------------------------- frame
    /// The pre-passes, the world pass and the post slot for the world MetalWorld built this tick. No-op when nothing
    /// was built (a frozen world keeps its last image).
    func encodeWorld(_ cb: MTLCommandBuffer) {
        frameOpen = false
        guard built, ready, worldColor != nil else { built = false; return }
        built = false
        let t0 = FrameTimer.now()
        drawCalls = 0
        instanceCount = 0
        triangles = 0
        // compute / depth passes (shadow)
        for p in prePasses { p.encode(cb) }
        // the world: opaque, then transparent / additive in the same encoder (tile memory)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: worldPass) else { return }
        enc.label = "world"
        beginWorldPass(enc)
        enc.setCullMode(.back)
        enc.setDepthStencilState(dsOpaque)
        for it in opaqueItems { it.encode(enc) }
        enc.setDepthStencilState(dsTransparent)
        enc.setCullMode(.none)
        for it in transparentItems { it.encode(enc) }
        enc.endEncoding()
        // post slot: no passes yet — an HDR resolve / bloom / tone map / grade chain goes here and leaves its result
        // where encodeComposite samples it
        hasWorldImage = true
        frames += 1
        encodeMs += ((FrameTimer.now() - t0) * 1000 - encodeMs) * 0.1
    }

    /// The world image scaled into the drawable (final pass, before the HUD). false = no image yet.
    @discardableResult
    func encodeComposite(_ enc: MTLRenderCommandEncoder) -> Bool {
        guard hasWorldImage, let ps = psComposite, let tex = worldColor else { return false }
        enc.setRenderPipelineState(ps)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        return true
    }

    /// Frame uniforms and the pass-wide textures every world draw may read (snow mask, particle noise, shadow map).
    private func beginWorldPass(_ enc: MTLRenderCommandEncoder) {
        boundPipeline = nil
        boundMain = nil
        var F = frame
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setFragmentBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setFrontFacing(.counterClockwise)
        for slot in [TextureIndex.snow, TextureIndex.shadow, TextureIndex.noise] {
            if let t = passTextures[slot] { enc.setFragmentTexture(t, index: slot) }
        }
    }

    // ---------------------------------------------------------------- mesh batch service
    /// Opaque item 200: the instanced mesh batches of this frame (squad, props, corpses), grouped by pipeline.
    func encodeBatches(_ enc: MTLRenderCommandEncoder) {
        let arena = self.arena
        for (k, pass) in MetalRenderer.passOrder.enumerated() {
            guard let p = psMesh[k] else { continue }
            for b in list.batches where b.pass == pass && b.region.count > 0 {
                use(enc, p)
                var mat = b.material
                enc.setVertexBuffer(b.region.buffer ?? arena, offset: b.region.offset, index: BufferIndex.instances)
                enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
                drawMesh(enc, b.mesh, instances: b.region.count)
            }
        }
    }

    /// Shadow caster item 100: batches that cast (the squad), depth only.
    func encodeBatchCasters(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psShadowMesh else { return }
        let arena = self.arena
        enc.setRenderPipelineState(ps)
        for b in list.batches where b.castsShadow && b.region.count > 0 {
            enc.setVertexBuffer(b.region.buffer ?? arena, offset: b.region.offset, index: BufferIndex.instances)
            drawMesh(enc, b.mesh, instances: b.region.count)
        }
    }

    /// Register the batch service's items (MetalWorld, once).
    func registerBatchService() {
        register(.opaque, order: 200, "mesh batches") { [unowned self] enc in self.encodeBatches(enc) }
        register(.shadowCasters, order: 100, "mesh batch casters") { [unowned self] enc in self.encodeBatchCasters(enc) }
    }

    // ---------------------------------------------------------------- draw helpers (world encoder)
    /// Bind a pipeline unless it is already bound.
    @inline(__always) func use(_ enc: MTLRenderCommandEncoder, _ ps: MTLRenderPipelineState) {
        if boundPipeline !== ps { enc.setRenderPipelineState(ps); boundPipeline = ps }
    }

    /// Bind the main fragment texture (slot 0) unless it is already bound.
    @inline(__always) func bindMain(_ enc: MTLRenderCommandEncoder, _ t: MTLTexture) {
        if boundMain !== t { enc.setFragmentTexture(t, index: TextureIndex.main); boundMain = t }
    }

    /// A static (world-placed) mesh with its material constants in both stages.
    func drawStatic(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, _ mat: inout MaterialUniforms) {
        enc.setVertexBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        drawCalls += 1
        triangles += mesh.indexCount / 3
    }

    /// `instances` copies of a mesh (instance data already bound at BufferIndex.instances).
    func drawMesh(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, instances: Int) {
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices,
                                  indexBufferOffset: 0, instanceCount: instances)
        drawCalls += 1
        instanceCount += instances
        triangles += mesh.indexCount / 3 * instances
    }

    /// `n` instanced quads (6 vertices each).
    func drawQuads(_ enc: MTLRenderCommandEncoder, _ n: Int) {
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
        drawCalls += 1
        instanceCount += n
        triangles += 2 * n
    }

    /// Count a draw a module issued itself.
    func count(draws: Int = 1, instances: Int = 0, triangles t: Int) {
        drawCalls += draws
        instanceCount += instances
        triangles += t
    }
}

/// Instances that change only on events (ground stains, corpses, gore riding the lift): kept in persistent buffers,
/// one per arena slot, and copied into a slot again only when the data changed since that slot's last copy — not
/// ~250 KB through the arena every frame. A slot's buffer is written only by the frame that fills the same arena
/// slot, so the GPU is done with it (same guarantee as the arena).
final class EventPool<T> {
    private var buffers: [MTLBuffer?] = Array(repeating: nil, count: MetalRenderer.arenaSlots)
    private var copied = [Int](repeating: -1, count: MetalRenderer.arenaSlots)
    private let label: String
    /// Capacity to allocate up front (instances): the tier's ring size, so a buffer is made once.
    var capacity: Int

    init(_ label: String, capacity: Int) {
        self.label = label
        self.capacity = capacity
    }

    /// `version` changes whenever `values` does.
    func region(_ values: [T], version: Int, renderer r: MetalRenderer) -> Region {
        if values.isEmpty { return Region() }
        let s = r.arenaSlot
        let need = MemoryLayout<T>.stride * values.count
        if (buffers[s]?.length ?? 0) < need {
            let n = max(values.count, capacity)
            buffers[s] = r.device.makeBuffer(length: MemoryLayout<T>.stride * n, options: [.storageModeShared, .cpuCacheModeWriteCombined])
            buffers[s]?.label = label
            copied[s] = -1
        }
        guard let b = buffers[s] else { return r.upload(values) }
        if copied[s] != version {
            values.withUnsafeBufferPointer { src in
                b.contents().bindMemory(to: T.self, capacity: values.count).update(from: src.baseAddress!, count: values.count)
            }
            copied[s] = version
        }
        return Region(offset: 0, count: values.count, buffer: b)
    }
}
