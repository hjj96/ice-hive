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
//    world (R2)     stage .opaque      level, mesh batches (squad,      → MSAA 4× RG11B10Float + depth32F,
//                                      props, corpses), swarm             both memoryless on the device;
//                   stage .transparent haze, pad, glows, decals, floor      viewport = dynamic resolution;
//                                      sprites, glints, particles,        store = multisample resolve →
//                                      ribbons, weather — same encoder    sceneHDR (RenderTargets)
//    distortion(R3) stage .distortion  heat sprites, ¼ res RG8 (High;   → RenderTargets.distortion
//                                      skipped while nothing registers)
//    post (R4–R12)  PostChain          dual-Kawase bloom from sceneHDR
//    composite      encodeComposite    first draw of FrameLoop's final pass: upscale + bloom + exposure + ACES
//                                      + LUT grade + vignette + grain + dither → drawable (PostChain)
//    HUD            SKRenderer         same encoder as the composite (FrameLoop), then one present
//  Materials write linear radiance (Shaders/Common.h encodeColor);
//  RenderQuality picks the tier and the dynamic-resolution scale,
//  GPUCounters times the passes (hb gpu lines).
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
//  skipped). World pipelines are compiled for 4× MSAA and the
//  RG11B10Float target; .distortion ones for the RG8 heat target.
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
        /// The world pass: colour (MetalRenderer.worldFormat, 4× MSAA) + depth.
        case world
        /// Depth only (shadow maps): no colour attachment, no fragment stage.
        case depthOnly
        /// The ¼-res heat-distortion target (RG8Unorm, 0.5 = no offset; additive), no depth.
        case distortion
    }
    let label: String
    let vertex: String
    let fragment: String?
    let blend: BlendMode
    let layout: VertexLayout?
    let target: Target
    /// The world cannot be drawn without it: a failure shows the Metal failure screen instead of a broken frame.
    let required: Bool
    /// Compiled twice, once per tier (function constant FunctionConstant.tierHigh: true = High): the module draws with
    /// `renderer.tieredPipeline(label)(renderer.frameTier)`. Costs a second compile behind the loading cover — only for
    /// shaders whose tiers really differ (clear-coat lobe, shadow march, …).
    var tiered = false

    static func world(_ label: String, _ vs: String, _ fs: String, _ blend: BlendMode = .none, _ layout: VertexLayout? = nil,
                      required: Bool = false, tiered: Bool = false) -> PipelineSpec {
        PipelineSpec(label: label, vertex: vs, fragment: fs, blend: blend, layout: layout, target: .world, required: required,
                     tiered: tiered)
    }

    static func depthOnly(_ label: String, _ vs: String, _ layout: VertexLayout? = nil) -> PipelineSpec {
        PipelineSpec(label: label, vertex: vs, fragment: nil, blend: .none, layout: layout, target: .depthOnly, required: false)
    }

    static func distortion(_ label: String, _ vs: String, _ fs: String, _ layout: VertexLayout? = nil) -> PipelineSpec {
        PipelineSpec(label: label, vertex: vs, fragment: fs, blend: .add, layout: layout, target: .distortion, required: false)
    }
}

/// Function-constant indices shared by every shader file (Shaders/Common.h FC_*).
enum FunctionConstant {
    /// bool: the High tier's variant of a tiered pipeline (Common.h TIER_CONSTANT).
    static let tierHigh = 0

    /// `name` from `lib`, specialised for `tier` when given (a function that declares no tier constant ignores it).
    static func function(_ lib: MTLLibrary, _ name: String, tier: RenderTier?) -> MTLFunction? {
        guard let t = tier else { return lib.makeFunction(name: name) }
        let cv = MTLFunctionConstantValues()
        var high = t == .high
        cv.setConstantValue(&high, type: .bool, index: tierHigh)
        return (try? lib.makeFunction(name: name, constantValues: cv)) ?? lib.makeFunction(name: name)
    }
}

/// The two tier variants of a PipelineSpec.tiered pipeline; either may be nil (failed to compile: the other stands in).
struct TieredPipeline {
    let high: MTLRenderPipelineState?
    let efficient: MTLRenderPipelineState?

    func callAsFunction(_ t: RenderTier) -> MTLRenderPipelineState? { t == .high ? (high ?? efficient) : (efficient ?? high) }
}

/// Where a draw item runs (see the order keys in the header).
enum WorldStage { case opaque, transparent, shadowCasters, distortion }

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
    /// encodeWorld slower than this (wall ms) is logged with its thread CPU time (diagnostics; ci/frame_metrics.py).
    static let slowEncodeMs: Double = 25

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
    /// The world target's colour format: linear HDR (RenderTargets).
    let worldFormat: MTLPixelFormat = RenderTargets.colorFormat
    /// Samples per pixel of the world pass.
    let worldSamples = RenderTargets.sampleCount
    /// The drawable's format (CAMetalLayer.pixelFormat, FrameLoop): the composite and the HUD write it.
    let drawableFormat: MTLPixelFormat = .bgra8Unorm
    let depthFormat: MTLPixelFormat = RenderTargets.depthFormat
    /// The world's targets (allocated once, dynamic-resolution viewport).
    let targets: RenderTargets
    /// Bloom, composite, exposure, grade.
    let post: PostChain
    /// Tiers, thermal ladder, dynamic resolution.
    let quality: RenderQuality
    /// Per-pass GPU timestamps (device) / command-buffer totals (simulator).
    let counters: GPUCounters

    // pipelines by label (PipelineSpec), plus the composite
    private var pipelineStates: [String: MTLRenderPipelineState] = [:]
    private var psMesh: [MTLRenderPipelineState?] = [nil, nil, nil]
    private var psShadowMesh: MTLRenderPipelineState?
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
    /// Pixels FrameLoop asks for (view points × GameScene's world scale): the allocation covers at least this.
    private(set) var requestedWidth = 0
    private(set) var requestedHeight = 0
    /// This frame's world viewport (pixels; the dynamic-resolution scale of the view's points).
    var targetWidth: Int { targets.viewW }
    var targetHeight: Int { targets.viewH }
    /// The viewport of the image in sceneHDR (the composite of a frozen world keeps sampling this one).
    private var imageView = (1, 1)
    /// Tier of the image in the scene / bloom targets.
    private var imageTier: RenderTier = .efficient
    private let distortionPass = MTLRenderPassDescriptor()
    private var distortionOn = false
    private var frameTime: Float = 0

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
    private var distortionItems: [DrawItem] = []
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
        targets = RenderTargets(device: device)
        post = PostChain(device: device)
        quality = RenderQuality(device: device)
        counters = GPUCounters(device: device)
        for k in 0..<MetalRenderer.arenaSlots {
            guard let b = device.makeBuffer(length: MetalRenderer.arenaSize, options: [.storageModeShared, .cpuCacheModeWriteCombined]) else { return nil }
            b.label = "arena\(k)"
            arenas.append(b)
        }
    }

    // ---------------------------------------------------------------- setup
    /// Compile every pipeline of `specs` and the post chain's (call once, off the main thread; it may run while the
    /// MeshStore loads). World pipelines get the HDR format and 4× MSAA.
    func compilePipelines(_ specs: [PipelineSpec]) -> String {
        let t0 = FrameTimer.now()
        guard let lib = device.makeDefaultLibrary() else {
            pipelineErrors.append("no default library")
            return "pipelines: no default Metal library"
        }
        let errLock = NSLock()
        func fail(_ s: String) { errLock.lock(); pipelineErrors.append(s); errLock.unlock() }
        func make(_ sp: PipelineSpec, _ tier: RenderTier?) throws -> MTLRenderPipelineState {
            guard let v = FunctionConstant.function(lib, sp.vertex, tier: tier) else {
                throw NSError(domain: "pipeline", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing function \(sp.vertex)"])
            }
            let d = MTLRenderPipelineDescriptor()
            d.label = sp.label + (tier.map { "." + $0.rawValue } ?? "")
            d.vertexFunction = v
            d.vertexDescriptor = sp.layout?.descriptor
            switch sp.target {
            case .depthOnly:
                d.fragmentFunction = nil
                d.colorAttachments[0].pixelFormat = .invalid
                d.depthAttachmentPixelFormat = .depth32Float
                return try device.makeRenderPipelineState(descriptor: d)
            case .world, .distortion:
                guard let fn = sp.fragment, let f = FunctionConstant.function(lib, fn, tier: tier) else {
                    throw NSError(domain: "pipeline", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing function \(sp.fragment ?? "-")"])
                }
                d.fragmentFunction = f
                if sp.target == .world {
                    d.depthAttachmentPixelFormat = depthFormat
                    d.rasterSampleCount = worldSamples
                }
            }
            let c = d.colorAttachments[0]!
            c.pixelFormat = sp.target == .distortion ? RenderTargets.distortionFormat : worldFormat
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
            return try device.makeRenderPipelineState(descriptor: d)
        }
        // every pipeline (world + post) compiles in parallel (device-specific compilation dominates a cold launch)
        // (a tiered spec is two jobs, "<label>.high" / "<label>.efficient")
        var jobs: [(String, () throws -> MTLRenderPipelineState)] = specs.flatMap { sp -> [(String, () throws -> MTLRenderPipelineState)] in
            sp.tiered ? [RenderTier.high, .efficient].map { t in (sp.label + "." + t.rawValue, { try make(sp, t) }) }
                      : [(sp.label, { try make(sp, nil) })]
        }
        let worldJobs = jobs.count
        jobs += post.pipelineJobs(lib, drawableFormat: drawableFormat)
        var states = [MTLRenderPipelineState?](repeating: nil, count: jobs.count)
        var ms = [Double](repeating: 0, count: jobs.count)
        let lock = NSLock()
        // the shader compiler's first request alone (on a cold first launch it carries the compiler service's start-up,
        // which no pipeline count changes): logged apart from the batch so a slow first launch can be attributed
        let firstIndex = jobs.count - 1
        let f0 = FrameTimer.now()
        do { states[firstIndex] = try jobs[firstIndex].1() } catch { fail("\(jobs[firstIndex].0): \(error.localizedDescription)") }
        let firstMs = (FrameTimer.now() - f0) * 1000
        ms[firstIndex] = firstMs
        let b0 = FrameTimer.now()
        DispatchQueue.concurrentPerform(iterations: jobs.count - 1) { i in
            let j0 = FrameTimer.now()
            do {
                let st = try jobs[i].1()
                lock.lock(); states[i] = st; ms[i] = (FrameTimer.now() - j0) * 1000; lock.unlock()
            } catch {
                fail("\(jobs[i].0): \(error.localizedDescription)")
            }
        }
        let batchMs = (FrameTimer.now() - b0) * 1000
        // the slowest compiles of the batch (a cold first launch compiles everything: CI gates its loading time)
        let slow = ms.indices.filter { $0 != firstIndex }.sorted { ms[$0] > ms[$1] }.prefix(5).map { jobs[$0].0 + String(format: " %.0f", ms[$0]) }
        var postStates: [String: MTLRenderPipelineState] = [:]
        for (i, job) in jobs.enumerated() {
            guard let st = states[i] else { continue }
            if i < worldJobs { pipelineStates[job.0] = st } else { postStates[job.0] = st }
        }
        post.bind(postStates)
        let missingRequired = specs.filter { sp in
            sp.required && (sp.tiered ? tieredPipeline(sp.label)(.high) == nil : pipelineStates[sp.label] == nil)
        }.map { $0.label }
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
        ready = missingRequired.isEmpty && post.ready && dsOpaque != nil && dsTransparent != nil
        return String(format: "pipelines built in %.0f ms (%d world + %d post; first request %.0f ms, then %d in parallel %.0f ms, slowest: ",
                      (FrameTimer.now() - t0) * 1000, pipelineStates.count, postStates.count, firstMs, jobs.count - 1, batchMs)
            + slow.joined(separator: ", ") + ")"
            + (pipelineErrors.isEmpty ? "" : " ERRORS: " + pipelineErrors.joined(separator: "; "))
    }

    /// A compiled pipeline by its PipelineSpec label (nil: it failed to compile — the module skips that draw).
    func pipeline(_ label: String) -> MTLRenderPipelineState? { pipelineStates[label] }

    /// Both variants of a PipelineSpec.tiered pipeline; draw with `variants(frameTier)`.
    func tieredPipeline(_ label: String) -> TieredPipeline {
        TieredPipeline(high: pipelineStates[label + ".high"], efficient: pipelineStates[label + ".efficient"])
    }

    /// Tier of the world frame being built / encoded (RenderQuality; the thermal ladder can change it between frames):
    /// modules pick tiered pipelines and skip High-only work by it.
    var frameTier: RenderTier { quality.tier }

    /// Pass-wide state that needs the loaded store (after MeshStore.loadAll and compilePipelines; off the main thread).
    func bindResources() -> String {
        passTextures[TextureIndex.noise] = store.noise
        distortionPass.colorAttachments[0].loadAction = .clear
        distortionPass.colorAttachments[0].storeAction = .store
        distortionPass.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0, alpha: 1)
        return post.loadResources()
    }

    /// FrameLoop's world size for this tick (view points × GameScene's world scale, pixels). The targets are allocated
    /// once to cover it (they grow only — a rotation or a larger -mscale); the frame's viewport comes from
    /// prepareViewport (dynamic resolution).
    func setTargetSize(width: Int, height: Int) {
        requestedWidth = max(1, width)
        requestedHeight = max(1, height)
        if targets.ensure(width: requestedWidth, height: requestedHeight) {
            hasWorldImage = false
            if targets.viewW <= 1 { targets.setViewport(width: requestedWidth, height: requestedHeight) }
        }
    }

    /// Main thread, every tick before the world is built: the tier, the thermal ladder and the dynamic-resolution
    /// scale of this frame → the viewport. `points`: the view (HUD) size.
    func prepareViewport(points: CGSize, hz: Int) {
        guard requestedWidth > 0 && requestedHeight > 0 else { return }
        let pw = Float(max(1, points.width)), ph = Float(max(1, points.height))
        let requested = Float(requestedWidth) / pw
        let s = quality.update(now: FrameTimer.now(), requested: requested, hz: hz)
        targets.setViewport(width: min(requestedWidth, Int((pw * s).rounded())), height: min(requestedHeight, Int((ph * s).rounded())))
        post.update(now: FrameTimer.now())
    }

    // ---------------------------------------------------------------- scheduler
    /// Add a draw item to a stage of the world frame (call once, after the pipelines are compiled; main thread).
    func register(_ stage: WorldStage, order: Int, _ label: String, _ encode: @escaping PassEncode) {
        let item = DrawItem(order: order, label: label, encode: encode)
        switch stage {
        case .opaque: opaqueItems.append(item); opaqueItems.sort { $0.order < $1.order }
        case .transparent: transparentItems.append(item); transparentItems.sort { $0.order < $1.order }
        case .shadowCasters: casterItems.append(item); casterItems.sort { $0.order < $1.order }
        case .distortion: distortionItems.append(item); distortionItems.sort { $0.order < $1.order }
        }
    }

    /// Add a pass that runs on the frame's command buffer before the world pass (compute, shadow maps).
    func registerPrePass(order: Int, _ label: String, _ encode: @escaping (MTLCommandBuffer) -> Void) {
        prePasses.append(PrePass(order: order, label: label, encode: encode))
        prePasses.sort { $0.order < $1.order }
    }

    /// Drop every registered item (the world that registered them is going away).
    func clearRegistrations() {
        opaqueItems.removeAll(); transparentItems.removeAll(); casterItems.removeAll(); distortionItems.removeAll(); prePasses.removeAll()
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
    /// The pre-passes, the world pass (resolved into sceneHDR), the distortion pass and the bloom for the world
    /// MetalWorld built this tick. No-op when nothing was built (a frozen world keeps its last image).
    func encodeWorld(_ cb: MTLCommandBuffer) {
        frameOpen = false
        counters.endFrame()
        guard built, ready, targets.scene != nil else { built = false; return }
        built = false
        let t0 = FrameTimer.now()
        // a slow encode (diagnostics) is logged with the thread's CPU time inside it: CI tells the app's own work from
        // time the thread spent off the CPU inside Metal calls (the simulator forwards them to the host)
        let c0 = AppLog.diagnostics ? CPUTime.thread() : 0
        defer {
            let wallMs = (FrameTimer.now() - t0) * 1000
            if AppLog.diagnostics && wallMs > MetalRenderer.slowEncodeMs {
                AppLog.info(String(format: "metal: slow world encode %.0f ms (thread cpu %.1f ms) wall=%.3f", wallMs,
                                   (CPUTime.thread() - c0) * 1000, Date().timeIntervalSince1970))
            }
        }
        drawCalls = 0
        instanceCount = 0
        triangles = 0
        let tier = quality.tier
        counters.beginFrame(slot: arenaIndex)
        // compute / depth passes (shadow)
        for p in prePasses { p.encode(cb) }
        // the world: opaque, then transparent / additive in the same encoder (tile memory), resolved at the end
        let wp = targets.worldPass
        counters.attach(to: wp, pass: .world)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: wp) else { return }
        enc.label = "world"
        beginWorldPass(enc)
        enc.setCullMode(.back)
        enc.setDepthStencilState(dsOpaque)
        for it in opaqueItems { it.encode(enc) }
        enc.setDepthStencilState(dsTransparent)
        enc.setCullMode(.none)
        for it in transparentItems { it.encode(enc) }
        enc.endEncoding()
        // R3 heat distortion (High, only while something draws into it)
        distortionOn = false
        if tier == .high, !distortionItems.isEmpty, let dt = targets.distortion {
            distortionPass.colorAttachments[0].texture = dt
            counters.detach(distortionPass)
            if let de = cb.makeRenderCommandEncoder(descriptor: distortionPass) {
                de.label = "distortion"
                var F = frame
                de.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
                de.setFragmentBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
                boundPipeline = nil
                boundMain = nil
                for it in distortionItems { it.encode(de) }
                de.endEncoding()
                distortionOn = true
            }
        }
        // R4–R12: bloom from sceneHDR
        post.encodeBloom(cb, targets, tier: tier, time: frame.camPos.w, counters: counters)
        counters.track(cb, quality: quality)
        imageView = (targets.viewW, targets.viewH)
        imageTier = tier
        hasWorldImage = true
        frames += 1
        encodeMs += ((FrameTimer.now() - t0) * 1000 - encodeMs) * 0.1
    }

    /// FrameLoop's final pass (composite + HUD): sample its start / end as the `final` pass when this tick encoded a
    /// world frame (call before making its encoder; `finishFinalPass` after endEncoding). Device only; no-op elsewhere.
    func instrumentFinalPass(_ desc: MTLRenderPassDescriptor) {
        if counters.frameOpen { counters.attach(to: desc, pass: .final) } else { counters.detach(desc) }
    }

    /// After FrameLoop's final pass: the descriptor stops sampling, the frame's slot is closed.
    func finishFinalPass(_ desc: MTLRenderPassDescriptor) {
        counters.detach(desc)
        counters.endFrame()
    }

    /// The world image into the drawable: the first draw of FrameLoop's final pass (before the HUD). false = no image
    /// yet.
    @discardableResult
    func encodeComposite(_ enc: MTLRenderCommandEncoder) -> Bool {
        guard hasWorldImage else { return false }
        // a frozen world keeps the viewport its image was rendered with
        let view = (targets.viewW, targets.viewH)
        if view != imageView { targets.setViewport(width: imageView.0, height: imageView.1) }
        defer { if view != imageView { targets.setViewport(width: view.0, height: view.1) } }
        return post.encodeComposite(enc, targets, tier: imageTier, time: frame.camPos.w, distortion: distortionOn ? targets.distortion : nil)
    }

    /// Frame uniforms, the viewport and the pass-wide textures every world draw may read (snow mask, particle noise,
    /// shadow map).
    private func beginWorldPass(_ enc: MTLRenderCommandEncoder) {
        boundPipeline = nil
        boundMain = nil
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(targets.viewW), height: Double(targets.viewH), znear: 0, zfar: 1))
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
