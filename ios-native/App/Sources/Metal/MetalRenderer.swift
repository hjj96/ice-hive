import Foundation
import Metal
import QuartzCore

// ================================================================
//  METAL RENDERER — pipelines, the per-frame upload arena (a ring of
//  three; FrameLoop keeps at most two frames on the GPU) and the
//  world part of the frame. One command buffer per frame (FrameLoop):
//
//    1 shadow       encodeShadow       depth only, 1024², «высокая»     → shadowTex
//    2 world        encodeOpaque       level, squad, props, corpses,    → worldColor (world scale, 2x)
//                                      swarm                              + depth (memoryless on device)
//                   encodeTransparent  haze, pad, glows, decals, floor
//                                      sprites, particles, ribbons,
//                                      weather — same encoder (tile memory)
//    3 post         — (slot)           HDR resolve, bloom, tone map, grade: passes that read worldColor and
//                                      write the image the composite samples
//    4 composite    encodeComposite    world image → drawable at the screen's native scale (opens the final pass)
//    5 HUD          SKRenderer         same encoder as 4 (FrameLoop), then one present
//
//  Shading today tone-maps per material (ACES + sRGB in each fragment,
//  like three.js rendering straight to the canvas), so worldColor is
//  display-referred bgra8Unorm. An HDR chain changes three things:
//  worldFormat → .rgba16Float, encodeColor() in Shaders.metal → linear
//  out, and a tone-map / grade pass in slot 3. Vertex formats are
//  named by VertexLayout (one MTLVertexDescriptor each), so skinned or
//  vertex-animation-texture meshes add a layout + their vertex
//  functions without touching the existing pipelines.
//  MetalWorld fills the arena and a DrawList each drawn frame.
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

/// Everything one frame draws (offsets into the arena of that frame).
final class DrawList {
    var bugs = [Region](repeating: Region(), count: 4)
    var batches: [MeshBatch] = []
    var decals = Region()
    var glowSprites = Region()
    var ringSprites = Region()
    var fillSprites = Region()
    var laneSprites = Region()
    var indicators = Region()
    var pn = Region()
    var pa = Region()
    var ribbons = Region()
    var liftRise: Float = 0
    var weather = F4(0, 0, 0, 0)
    var snow = 0, motes = 0, mist = 0
    /// The player's flashlight casts shadows this frame («высокая»); proxies = bug blobs inside its cone.
    var shadowOn = false
    var proxies = Region()
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

    let device: MTLDevice
    let queue: MTLCommandQueue
    let store: MeshStore
    /// The world target's colour format (display-referred today; .rgba16Float once tone mapping moves to a post pass).
    let worldFormat: MTLPixelFormat = .bgra8Unorm
    /// The drawable's format (CAMetalLayer.pixelFormat, FrameLoop): the composite and the HUD write it.
    let drawableFormat: MTLPixelFormat = .bgra8Unorm
    let depthFormat: MTLPixelFormat = .depth32Float

    // pipelines
    private var psProps: MTLRenderPipelineState?
    private var psFloor: MTLRenderPipelineState?
    private var psTexturedOpaque: MTLRenderPipelineState?
    private var psTexturedAlpha: MTLRenderPipelineState?
    private var psGlowQuads: MTLRenderPipelineState?
    private var psHaze: MTLRenderPipelineState?
    private var psMeshProps: MTLRenderPipelineState?
    private var psMeshLambert: MTLRenderPipelineState?
    private var psMeshUnlit: MTLRenderPipelineState?
    private var psBug: MTLRenderPipelineState?
    private var psGlint: MTLRenderPipelineState?
    private var psDecal: MTLRenderPipelineState?
    private var psSprite: MTLRenderPipelineState?
    private var psParticleAdd: MTLRenderPipelineState?
    private var psParticleAlpha: MTLRenderPipelineState?
    private var psRibbon: MTLRenderPipelineState?
    private var psWeatherAlpha: MTLRenderPipelineState?
    private var psWeatherAdd: MTLRenderPipelineState?
    /// World target → drawable (no depth: the HUD shares this pass).
    private var psComposite: MTLRenderPipelineState?
    private var dsOpaque: MTLDepthStencilState?
    private var dsTransparent: MTLDepthStencilState?
    // flashlight shadow map (web «высокая»: spots[0].castShadow, 1024², PCF)
    static let shadowSize = 1024
    private var psShadowMesh: MTLRenderPipelineState?
    private var psShadowProxy: MTLRenderPipelineState?
    private var dsShadow: MTLDepthStencilState?
    private var shadowTex: MTLTexture?
    private var shadowDummy: MTLTexture?
    private let shadowPass = MTLRenderPassDescriptor()
    private var proxyVB: MTLBuffer?, proxyIB: MTLBuffer?
    private var proxyIndexCount = 0
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

    // static level meshes and their materials
    private var levelDraws: [(GPUMesh, MaterialUniforms, Int)] = []   // kind: 0 props, 1 floor grating, 2 floor slab, 3 lift floor, 4 lift props
    private var bugMeshes: [GPUMesh] = []
    // meshes / textures resolved once (no dictionary lookups while encoding)
    private var meshHazard: GPUMesh!, meshPad: GPUMesh!, meshGlow: GPUMesh!, meshHaze: GPUMesh!
    private var texSnow: MTLTexture!, texGrating: MTLTexture!, texSlab: MTLTexture!, texHazard: MTLTexture!, texPad: MTLTexture!
    private var texGlow: MTLTexture!, texRing: MTLTexture!, texFill: MTLTexture!, texLane: MTLTexture!, texDecals: MTLTexture!
    private var texDash: MTLTexture!, texStreak: MTLTexture!, texHaze: MTLTexture!
    /// Pipeline / textures last bound by encode() (redundant state changes are skipped).
    private var boundPipeline: MTLRenderPipelineState?
    private var boundMain: MTLTexture?
    private let matProps = MaterialUniforms(pbr: F4(0.62, 0.45, 1, 2.2), floor: F4(0, 0, 0, 1))

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
    /// Compile every pipeline (call once, off the main thread; it may run while the MeshStore loads).
    func compilePipelines() -> String {
        let t0 = FrameTimer.now()
        guard let lib = device.makeDefaultLibrary() else {
            pipelineErrors.append("no default library")
            return "pipelines: no default Metal library"
        }

        enum Blend { case none, alpha, add, multiply }
        let errLock = NSLock()
        func make(_ label: String, _ vs: String, _ fs: String, _ blend: Blend, _ layout: VertexLayout?) -> MTLRenderPipelineState? {
            guard let v = lib.makeFunction(name: vs), let f = lib.makeFunction(name: fs) else {
                errLock.lock(); pipelineErrors.append("\(label): missing function \(vs) / \(fs)"); errLock.unlock()
                return nil
            }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = v
            d.fragmentFunction = f
            d.vertexDescriptor = layout?.descriptor
            d.depthAttachmentPixelFormat = depthFormat
            let c = d.colorAttachments[0]!
            c.pixelFormat = worldFormat
            switch blend {
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
            do {
                return try device.makeRenderPipelineState(descriptor: d)
            } catch {
                errLock.lock(); pipelineErrors.append("\(label): \(error.localizedDescription)"); errLock.unlock()
                return nil
            }
        }
        // the 18 pipelines compile in parallel (device-specific compilation dominates a cold first launch)
        let specs: [(String, String, String, Blend, VertexLayout?)] = [
            ("props", "vs_static", "fs_props", .none, .ihm1), ("floor", "vs_static", "fs_floor", .none, .ihm1),
            ("hazard", "vs_static", "fs_textured", .none, .ihm1), ("pad", "vs_static", "fs_textured", .alpha, .ihm1),
            ("glowQuads", "vs_static", "fs_basic_textured", .add, .ihm1), ("haze", "vs_static", "fs_basic_textured", .alpha, .ihm1),
            ("meshProps", "vs_mesh", "fs_props", .none, .ihm1), ("meshLambert", "vs_mesh", "fs_lambert", .none, .ihm1),
            ("meshUnlit", "vs_mesh", "fs_unlit", .none, .ihm1), ("bug", "vs_bug", "fs_bug", .none, .ihm1),
            ("glint", "vs_glint", "fs_glint", .alpha, nil), ("decal", "vs_decal", "fs_decal", .multiply, nil),
            ("sprite", "vs_sprite", "fs_sprite", .add, nil), ("particleAdd", "vs_particle", "fs_particle_add", .add, nil),
            ("particleAlpha", "vs_particle", "fs_particle_alpha", .alpha, nil), ("ribbon", "vs_ribbon", "fs_ribbon", .add, nil),
            ("weatherAlpha", "vs_weather", "fs_weather", .alpha, nil), ("weatherAdd", "vs_weather", "fs_weather", .add, nil),
        ]
        var states = [MTLRenderPipelineState?](repeating: nil, count: specs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: specs.count) { i in
            let sp = specs[i]
            let st = make(sp.0, sp.1, sp.2, sp.3, sp.4)
            lock.lock(); states[i] = st; lock.unlock()
        }
        psProps = states[0]; psFloor = states[1]; psTexturedOpaque = states[2]; psTexturedAlpha = states[3]
        psGlowQuads = states[4]; psHaze = states[5]; psMeshProps = states[6]; psMeshLambert = states[7]
        psMeshUnlit = states[8]; psBug = states[9]; psGlint = states[10]; psDecal = states[11]
        psSprite = states[12]; psParticleAdd = states[13]; psParticleAlpha = states[14]; psRibbon = states[15]
        psWeatherAlpha = states[16]; psWeatherAdd = states[17]

        let od = MTLDepthStencilDescriptor()
        od.depthCompareFunction = .less
        od.isDepthWriteEnabled = true
        dsOpaque = device.makeDepthStencilState(descriptor: od)
        let td = MTLDepthStencilDescriptor()
        td.depthCompareFunction = .lessEqual
        td.isDepthWriteEnabled = false
        dsTransparent = device.makeDepthStencilState(descriptor: td)
        // depth-only shadow pipelines (no colour target, no fragment stage)
        func depthOnly(_ label: String, _ vs: String, _ layout: VertexLayout?) -> MTLRenderPipelineState? {
            guard let v = lib.makeFunction(name: vs) else { pipelineErrors.append("\(label): missing \(vs)"); return nil }
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = v
            d.fragmentFunction = nil
            d.vertexDescriptor = layout?.descriptor
            d.colorAttachments[0].pixelFormat = .invalid
            d.depthAttachmentPixelFormat = .depth32Float
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                pipelineErrors.append("\(label): \(error.localizedDescription)")
                return nil
            }
        }
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
        psShadowMesh = depthOnly("shadowMesh", "vs_shadow_mesh", .ihm1)
        psShadowProxy = depthOnly("shadowProxy", "vs_shadow_proxy", nil)
        let sd = MTLDepthStencilDescriptor()
        sd.depthCompareFunction = .less
        sd.isDepthWriteEnabled = true
        dsShadow = device.makeDepthStencilState(descriptor: sd)
        return String(format: "pipelines built in %.0f ms", (FrameTimer.now() - t0) * 1000)
            + (pipelineErrors.isEmpty ? "" : " ERRORS: " + pipelineErrors.joined(separator: "; "))
    }

    /// Resolve the loaded meshes / textures the frame encodes (after MeshStore.loadAll and compilePipelines).
    func bindResources() {
        // static level: floors (grating / slab + snow mask), merged props, the lift deck and its props (they rise)
        func floorMat(_ bias: Float) -> MaterialUniforms { MaterialUniforms(pbr: F4(0.72, 0.42, 0, 0), floor: F4(bias, 1, 0, 1)) }
        levelDraws = [
            (store.mesh("level_floor_grating"), floorMat(0), 1),
            (store.mesh("level_floor_slab"), floorMat(0.18), 2),
            (store.mesh("lift_floor"), floorMat(0), 3),
            (store.mesh("level_props"), matProps, 0),
            (store.mesh("lift_props"), matProps, 4),
        ]
        bugMeshes = ["bug_runner", "bug_spitter", "bug_brute", "bug_boomer"].map { store.mesh($0) }
        meshHazard = store.mesh("level_hazard"); meshPad = store.mesh("level_pad_mark")
        meshGlow = store.mesh("level_glow"); meshHaze = store.mesh("level_haze")
        texSnow = store.texture("snow"); texGrating = store.texture("grating"); texSlab = store.texture("slab")
        texHazard = store.texture("hazard"); texPad = store.texture("pad"); texGlow = store.texture("glow")
        texRing = store.texture("ring"); texFill = store.texture("fill"); texLane = store.texture("lane")
        texDecals = store.texture("decals"); texDash = store.texture("dash"); texStreak = store.texture("streak")
        texHaze = store.texture("haze")
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
        dd.usage = [.shaderRead, .renderTarget]
        dd.storageMode = .private
        shadowDummy = device.makeTexture(descriptor: dd)
        // the shadow proxy: IcosahedronGeometry(0.3, 0)
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var iv: [Float] = []
        for v in [F3(-1, t, 0), F3(1, t, 0), F3(-1, -t, 0), F3(1, -t, 0), F3(0, -1, t), F3(0, 1, t), F3(0, -1, -t), F3(0, 1, -t),
                  F3(t, 0, -1), F3(t, 0, 1), F3(-t, 0, -1), F3(-t, 0, 1)] {
            let n = v / (v * v).sum().squareRoot() * 0.3
            iv += [n.x, n.y, n.z]
        }
        let ii: [UInt16] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                            3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        proxyVB = device.makeBuffer(bytes: iv, length: iv.count * 4, options: [])
        proxyIB = device.makeBuffer(bytes: ii, length: ii.count * 2, options: [])
        proxyIndexCount = ii.count
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1
        // the flashlight shadow map exists from the start (not created on the first «высокая» frame)
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: MetalRenderer.shadowSize,
                                                          height: MetalRenderer.shadowSize, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        shadowTex = device.makeTexture(descriptor: sd)
        shadowTex?.label = "flashlight shadow"
        let fogc = displayRGB(0x1a2737)
        worldPass.colorAttachments[0].loadAction = .clear
        worldPass.colorAttachments[0].storeAction = .store
        worldPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(fogc.x), green: Double(fogc.y), blue: Double(fogc.z), alpha: 1)
        worldPass.depthAttachment.loadAction = .clear
        worldPass.depthAttachment.storeAction = .dontCare
        worldPass.depthAttachment.clearDepth = 1
        // only what a frame cannot do without is required; an optional pass (shadow, glint dots, …) that failed to
        // compile is skipped by encode()
        ready = psProps != nil && psFloor != nil && psBug != nil && psMeshProps != nil && psComposite != nil
            && dsOpaque != nil && dsTransparent != nil
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

    /// The arena slot this frame fills (EventPool keeps one copy per slot).
    var arenaSlot: Int { arenaIndex }

    // ---------------------------------------------------------------- frame
    /// Passes 1–3 of the frame (header) for the world MetalWorld built this tick. No-op when nothing was built (a
    /// frozen world keeps its last image).
    func encodeWorld(_ cb: MTLCommandBuffer) {
        frameOpen = false
        guard built, ready, worldColor != nil else { built = false; return }
        built = false
        let t0 = FrameTimer.now()
        drawCalls = 0
        instanceCount = 0
        triangles = 0
        // 1 shadow
        if list.shadowOn { encodeShadow(cb) }
        // 2 world: opaque, then transparent / additive in the same encoder
        guard let enc = cb.makeRenderCommandEncoder(descriptor: worldPass) else { return }
        enc.label = "world"
        let arena = arenas[arenaIndex]
        beginWorldPass(enc)
        encodeOpaque(enc, arena)
        encodeTransparent(enc, arena)
        enc.endEncoding()
        // 3 post: no passes yet — an HDR resolve / bloom / tone map / grade chain goes here and leaves its result
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

    // ---------------------------------------------------------------- encoding
    /// The player's flashlight shadow map: the squad's meshes and the bug proxies inside the cone (back faces, like
    /// three.js shadowSide for front-sided materials).
    private func encodeShadow(_ cb: MTLCommandBuffer) {
        guard let tex = shadowTex, let psM = psShadowMesh, let psP = psShadowProxy else { list.shadowOn = false; return }
        shadowPass.depthAttachment.texture = tex
        guard let enc = cb.makeRenderCommandEncoder(descriptor: shadowPass) else { list.shadowOn = false; return }
        enc.label = "shadow"
        let arena = arenas[arenaIndex]
        var F = frame
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setDepthStencilState(dsShadow)
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.front)
        enc.setRenderPipelineState(psM)
        for b in list.batches where b.castsShadow && b.region.count > 0 {
            enc.setVertexBuffer(b.region.buffer ?? arena, offset: b.region.offset, index: BufferIndex.instances)
            drawMesh(enc, b.mesh, instances: b.region.count)
        }
        if list.proxies.count > 0, let vb = proxyVB, let ib = proxyIB {
            enc.setRenderPipelineState(psP)
            enc.setVertexBuffer(vb, offset: 0, index: BufferIndex.vertices)
            enc.setVertexBuffer(arena, offset: list.proxies.offset, index: BufferIndex.instances)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: proxyIndexCount, indexType: .uint16, indexBuffer: ib,
                                      indexBufferOffset: 0, instanceCount: list.proxies.count)
            drawCalls += 1
            instanceCount += list.proxies.count
            triangles += 20 * list.proxies.count
        }
        enc.endEncoding()
    }

    /// Bind a pipeline unless it is already bound.
    @inline(__always) private func use(_ enc: MTLRenderCommandEncoder, _ ps: MTLRenderPipelineState) {
        if boundPipeline !== ps { enc.setRenderPipelineState(ps); boundPipeline = ps }
    }

    /// Bind the main fragment texture (slot 0) unless it is already bound.
    @inline(__always) private func bindMain(_ enc: MTLRenderCommandEncoder, _ t: MTLTexture) {
        if boundMain !== t { enc.setFragmentTexture(t, index: TextureIndex.main); boundMain = t }
    }

    /// Frame uniforms and the textures every world draw may read (snow mask, particle noise, shadow map).
    private func beginWorldPass(_ enc: MTLRenderCommandEncoder) {
        boundPipeline = nil
        boundMain = nil
        var F = frame
        enc.setVertexBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setFragmentBytes(&F, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        enc.setFrontFacing(.counterClockwise)
        // the snow mask, the particle noise and the shadow map stay bound for the whole pass (slots 1, 2, 3)
        enc.setFragmentTexture(texSnow, index: TextureIndex.snow)
        enc.setFragmentTexture(list.shadowOn ? shadowTex : shadowDummy, index: TextureIndex.shadow)
        if let n = store.noise { enc.setFragmentTexture(n, index: TextureIndex.noise) }
    }

    /// Opaque geometry, depth-tested and written: the level, the instanced meshes, the swarm.
    private func encodeOpaque(_ enc: MTLRenderCommandEncoder, _ arena: MTLBuffer) {
        enc.setCullMode(.back)
        enc.setDepthStencilState(dsOpaque)
        // ---- opaque level: the floors (one pipeline), then the merged props
        if let ps = psFloor {
            use(enc, ps)
            for (mesh, mat0, kind) in levelDraws where kind >= 1 && kind <= 3 {
                var mat = mat0
                if kind == 3 { mat.floor.z = list.liftRise }
                bindMain(enc, kind == 2 ? texSlab : texGrating)
                drawStatic(enc, mesh, &mat)
            }
        }
        if let ps = psProps {
            use(enc, ps)
            for (mesh, mat0, kind) in levelDraws where kind == 0 || kind == 4 {
                var mat = mat0
                if kind == 4 { mat.floor.z = list.liftRise }
                drawStatic(enc, mesh, &mat)
            }
        }
        // hazard strips just above the floor
        if let ps = psTexturedOpaque {
            use(enc, ps)
            bindMain(enc, texHazard)
            var mat = MaterialUniforms(pbr: F4(0.8, 0.1, 0, 0), floor: F4(0, 0, 0, 1))
            enc.setDepthBias(-1, slopeScale: -1, clamp: 0)
            drawStatic(enc, meshHazard, &mat)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        // ---- squad, props, corpses (instanced meshes), grouped by pipeline
        for pass in MetalRenderer.passOrder {
            let ps: MTLRenderPipelineState?
            switch pass {
            case .props: ps = psMeshProps
            case .lambert: ps = psMeshLambert
            case .unlit: ps = psMeshUnlit
            }
            guard let p = ps else { continue }
            for b in list.batches where b.pass == pass && b.region.count > 0 {
                use(enc, p)
                var mat = b.material
                enc.setVertexBuffer(b.region.buffer ?? arena, offset: b.region.offset, index: BufferIndex.instances)
                enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
                drawMesh(enc, b.mesh, instances: b.region.count)
            }
        }

        // ---- swarm: one instanced draw per bug type
        if let ps = psBug {
            use(enc, ps)
            for t in 0..<4 where list.bugs[t].count > 0 {
                enc.setVertexBuffer(arena, offset: list.bugs[t].offset, index: BufferIndex.instances)
                drawMesh(enc, bugMeshes[t], instances: list.bugs[t].count)
            }
        }
    }

    /// Blended geometry over the opaque depth (tested, not written), back to front by kind like the web scene's
    /// renderOrder: haze, pad mark, floor glows, decals (multiply), floor sprites, glint dots, particles (alpha, then
    /// additive), ribbons, weather.
    private func encodeTransparent(_ enc: MTLRenderCommandEncoder, _ arena: MTLBuffer) {
        enc.setDepthStencilState(dsTransparent)
        enc.setCullMode(.none)
        if let ps = psHaze {
            use(enc, ps)
            bindMain(enc, texHaze)
            var mat = MaterialUniforms(pbr: .zero, floor: .zero)
            drawStatic(enc, meshHaze, &mat)
        }
        if let ps = psTexturedAlpha {
            use(enc, ps)
            bindMain(enc, texPad)
            var mat = MaterialUniforms(pbr: F4(0.85, 0, 0, 0), floor: .zero)
            enc.setDepthBias(-2, slopeScale: -2, clamp: 0)
            drawStatic(enc, meshPad, &mat)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if let ps = psGlowQuads {
            use(enc, ps)
            bindMain(enc, texGlow)
            var mat = MaterialUniforms(pbr: .zero, floor: .zero)
            drawStatic(enc, meshGlow, &mat)
        }
        if let ps = psDecal, list.decals.count > 0 {
            use(enc, ps)
            enc.setDepthBias(-4, slopeScale: -2, clamp: 0)
            enc.setVertexBuffer(list.decals.buffer ?? arena, offset: list.decals.offset, index: BufferIndex.instances)
            bindMain(enc, texDecals)
            drawQuads(enc, list.decals.count)
            enc.setDepthBias(0, slopeScale: 0, clamp: 0)
        }
        if let ps = psSprite {
            sprites(enc, ps, arena, list.glowSprites, texGlow)
            sprites(enc, ps, arena, list.indicators, texGlow)
            sprites(enc, ps, arena, list.ringSprites, texRing)
            sprites(enc, ps, arena, list.fillSprites, texFill)
            sprites(enc, ps, arena, list.laneSprites, texLane)
        }
        // swarm glints: one soft dot per speckle of every visible bug (instance = bug × speckle)
        if let ps = psGlint, MetalRenderer.glintDots {
            for t in 0..<4 where list.bugs[t].count > 0 && !bugMeshes[t].glints.isEmpty {
                use(enc, ps)
                let g = bugMeshes[t].glints
                var n = UInt32(g.count / 2)
                enc.setVertexBuffer(arena, offset: list.bugs[t].offset, index: BufferIndex.instances)
                g.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: BufferIndex.material) }
                enc.setVertexBytes(&n, length: 4, index: 4)
                drawQuads(enc, list.bugs[t].count * Int(n))
            }
        }
        if let ps = psParticleAlpha, list.pn.count > 0 {
            use(enc, ps)
            enc.setVertexBuffer(arena, offset: list.pn.offset, index: BufferIndex.instances)
            drawQuads(enc, list.pn.count)
        }
        if let ps = psParticleAdd, list.pa.count > 0 {
            use(enc, ps)
            enc.setVertexBuffer(arena, offset: list.pa.offset, index: BufferIndex.instances)
            drawQuads(enc, list.pa.count)
        }
        if let ps = psRibbon, list.ribbons.count > 0 {
            use(enc, ps)
            enc.setVertexBuffer(arena, offset: list.ribbons.offset, index: BufferIndex.instances)
            bindMain(enc, texDash)
            enc.setFragmentTexture(texStreak, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: list.ribbons.count)
            drawCalls += 1
            triangles += list.ribbons.count / 3
        }
        // weather: snowfall + mist (alpha), motes rising from the abyss (additive)
        if let ps = psWeatherAlpha, list.snow + list.mist > 0 {
            use(enc, ps)
            if list.snow > 0 { weather(enc, kind: 0, count: list.snow) }
            if list.mist > 0 { weather(enc, kind: 2, count: list.mist) }
        }
        if let ps = psWeatherAdd, list.motes > 0 {
            use(enc, ps)
            weather(enc, kind: 1, count: list.motes)
        }
    }

    private func sprites(_ enc: MTLRenderCommandEncoder, _ ps: MTLRenderPipelineState, _ arena: MTLBuffer, _ r: Region, _ tex: MTLTexture) {
        if r.count == 0 { return }
        use(enc, ps)
        enc.setVertexBuffer(arena, offset: r.offset, index: BufferIndex.instances)
        bindMain(enc, tex)
        drawQuads(enc, r.count)
    }

    private func drawStatic(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, _ mat: inout MaterialUniforms) {
        enc.setVertexBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setFragmentBytes(&mat, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
        drawCalls += 1
        triangles += mesh.indexCount / 3
    }

    private func drawMesh(_ enc: MTLRenderCommandEncoder, _ mesh: GPUMesh, instances: Int) {
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: BufferIndex.vertices)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices,
                                  indexBufferOffset: 0, instanceCount: instances)
        drawCalls += 1
        instanceCount += instances
        triangles += mesh.indexCount / 3 * instances
    }

    private func drawQuads(_ enc: MTLRenderCommandEncoder, _ n: Int) {
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: n)
        drawCalls += 1
        instanceCount += n
        triangles += 2 * n
    }

    private func weather(_ enc: MTLRenderCommandEncoder, kind: Float, count: Int) {
        var w = (F4(list.weather.x, list.weather.y, list.weather.z, kind), F4(Float(count), 0, 0, 0))
        enc.setVertexBytes(&w, length: MemoryLayout<F4>.stride * 2, index: BufferIndex.instances)
        drawQuads(enc, count)
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
