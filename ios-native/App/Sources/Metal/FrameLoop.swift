import UIKit
import QuartzCore
import Metal
import SpriteKit

// ================================================================
//  FRAME LOOP — the app's one CAMetalLayer and its display link.
//  Every tick: take a frame slot and a drawable without waiting (at
//  most two frames on the GPU; drawables are requested ahead on a
//  background queue), run the scene through SKRenderer.update
//  (simulation, events, HUD, audio; MetalWorld builds a world frame
//  only when the tick draws), then in ONE command buffer: the world
//  into its offscreen target (world scale, 2x by default), the
//  composite into the drawable at the screen's scale, the HUD on top
//  (SKRenderer in the same encoder), one present. When the GPU or the
//  compositor is behind (no free slot / no drawable back yet), the
//  tick only simulates: the main thread never waits on either, so
//  input, simulation, audio and haptics keep their rate and the screen
//  keeps its last image until the next frame can be drawn.
//  Command-buffer timings (commit → scheduled → done, GPU time) are
//  kept in a small ring so CI can tell a host-GPU stall from app work.
// ================================================================

/// What GameScene needs from the loop that hosts it (an SKRenderer scene has no SKView).
protocol GameHost: AnyObject {
    /// Safe-area insets of the screen (points).
    var safeAreaInsets: UIEdgeInsets { get }
    /// The view touches are located in (points, top-left origin).
    var touchView: UIView? { get }
    /// This tick holds a free frame slot: what the scene builds now will be drawn.
    var frameOpen: Bool { get }
    /// Display rate: 30 (menus), 60, 120 (ProMotion, «высокая»).
    func setFrameRate(_ fps: Int)
    /// World target pixels per point (2 by default; 1.5 when the device runs hot).
    func setWorldScale(_ scale: CGFloat)
    var timeline: GPUTimeline { get }
    /// Timings of the previous tick (ms): update (scene + world build), draw (encode + HUD + commit).
    var lastTick: FrameLoop.Tick { get }
    /// Heartbeat counters since the last call: ticks without a free slot, ticks without a drawable, the slowest
    /// nextDrawable() on the drawable queue (ms; it waits there, never on the main thread).
    func takeCounters() -> (slotMisses: Int, noDrawable: Int, drawableMaxMs: Double)
    /// Ticks without a free frame slot / without a drawable since launch.
    var slotMissTotal: Int { get }
    var noDrawableTotal: Int { get }
}

/// The game view: one CAMetalLayer (world + HUD); touches go to the scene.
final class GameView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    weak var touchTarget: UIResponder?
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touchTarget?.touchesBegan(touches, with: event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touchTarget?.touchesMoved(touches, with: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touchTarget?.touchesEnded(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchTarget?.touchesCancelled(touches, with: event) }
}

/// Command-buffer timings, written from Metal's completion threads (lock-protected).
final class GPUTimeline {
    struct Record {
        var commit: Double = 0, scheduled: Double = 0, done: Double = 0, gpu: Double = 0
        /// commit → done (ms): how long the frame took to come back.
        var latencyMs: Double { done > commit ? (done - commit) * 1000 : 0 }
    }
    /// Per-heartbeat window.
    struct Window {
        var completed = 0
        /// Longest gap between two completed frames (ms): what the screen saw as a stall.
        var maxGapMs: Double = 0
        /// The frame with the worst commit → done.
        var worst = Record()
        var gpuMaxMs: Double = 0
    }
    private let lock = NSLock()
    private var ring = [Record](repeating: Record(), count: 16)
    private var lastDone: Double = 0
    private var window = Window()
    private(set) var gpuEmaMs: Double = 0
    private var completedTotal = 0

    func committed(_ id: Int, at t: Double) {
        lock.lock()
        ring[id & 15] = Record(commit: t)
        lock.unlock()
    }

    func scheduled(_ id: Int, at t: Double) {
        lock.lock()
        ring[id & 15].scheduled = t
        lock.unlock()
    }

    func completed(_ id: Int, at t: Double, gpu: Double) {
        lock.lock()
        var r = ring[id & 15]
        r.done = t
        r.gpu = gpu > 0 && gpu < 10 ? gpu : 0
        ring[id & 15] = r
        if lastDone > 0 { window.maxGapMs = max(window.maxGapMs, (t - lastDone) * 1000) }
        lastDone = t
        window.completed += 1
        completedTotal += 1
        if r.latencyMs > window.worst.latencyMs { window.worst = r }
        let g = r.gpu * 1000
        window.gpuMaxMs = max(window.gpuMaxMs, g)
        gpuEmaMs += (g - gpuEmaMs) * 0.1
        lock.unlock()
    }

    /// Frames completed since launch.
    var completedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return completedTotal
    }

    /// Window since the last call, then reset (heartbeat).
    func takeWindow() -> Window {
        lock.lock(); defer { lock.unlock() }
        let w = window
        window = Window()
        return w
    }

    /// Worst commit → done of the last 16 frames, for a hitch line: "cb=230ms (sched 228, gpu 0.1)".
    func worstRecent() -> String {
        lock.lock(); defer { lock.unlock() }
        var w = Record()
        for r in ring where r.done > 0 && r.latencyMs > w.latencyMs { w = r }
        if w.done == 0 { return "cb=-" }
        let sched = w.scheduled > w.commit ? (w.scheduled - w.commit) * 1000 : 0
        return String(format: "cb=%.0fms (sched %.0f, gpu %.1f)", w.latencyMs, sched, w.gpu * 1000)
    }
}

/// Drawables come from a background queue: CAMetalLayer.nextDrawable() blocks (up to a second) while the compositor
/// still holds every drawable, and the main thread must never wait for that. One drawable is kept ready; a tick takes
/// it, or draws nothing if none came back yet. Size changes go through here too: they wait for the queue to be outside
/// nextDrawable() (retried on the next tick, never blocking) and drop a drawable fetched at the old size.
final class DrawableQueue {
    private let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "icehive.drawables", qos: .userInteractive)
    /// ready / fetching / generation / waitMax
    private let lock = NSLock()
    /// held around nextDrawable() and drawableSize changes
    private let layerLock = NSLock()
    private var ready: CAMetalDrawable?
    private var fetching = false
    /// Bumped by a resize: a drawable fetched before it is dropped.
    private var generation = 0
    private var waitMaxMs: Double = 0
    /// Main thread: a size change not applied yet (the queue was inside nextDrawable()).
    private var pending: (size: CGSize, scale: CGFloat)?

    init(layer: CAMetalLayer) { self.layer = layer }

    /// Main thread: the ready drawable, if any (and the next one is requested).
    func take() -> CAMetalDrawable? {
        lock.lock()
        let d = ready
        ready = nil
        lock.unlock()
        request()
        return d
    }

    /// Ask the queue for the next drawable unless one is ready or on its way.
    func request() {
        lock.lock()
        if fetching || ready != nil { lock.unlock(); return }
        fetching = true
        let gen = generation
        lock.unlock()
        queue.async { [weak self] in self?.fetch(gen) }
    }

    private func fetch(_ gen: Int) {
        let t0 = CACurrentMediaTime()
        layerLock.lock()
        let d = layer.nextDrawable()
        layerLock.unlock()
        let ms = (CACurrentMediaTime() - t0) * 1000
        lock.lock()
        fetching = false
        waitMaxMs = max(waitMaxMs, ms)
        let current = gen == generation
        if current { ready = d }
        lock.unlock()
        if d == nil {
            // timed out / no size yet: try again a frame later
            queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in self?.request() }
        } else if !current {
            request()
        }
    }

    /// Main thread: new drawable size (applied now, or on a later tick if the queue is inside nextDrawable()).
    func resize(_ size: CGSize, scale: CGFloat) {
        pending = (size, scale)
        applyPendingResize()
    }

    /// Main thread, every tick: apply a pending size change if the layer is free. true = applied now.
    @discardableResult
    func applyPendingResize() -> Bool {
        guard let p = pending, layerLock.try() else { return false }
        layer.contentsScale = p.scale
        layer.drawableSize = p.size
        layerLock.unlock()
        pending = nil
        lock.lock()
        ready = nil
        generation += 1
        lock.unlock()
        request()
        return true
    }

    /// Slowest nextDrawable() since the last call (ms).
    func takeWaitMax() -> Double {
        lock.lock(); defer { lock.unlock() }
        let w = waitMaxMs
        waitMaxMs = 0
        return w
    }
}

final class FrameLoop: GameHost {
    struct Tick {
        var updateMs: Double = 0
        var drawMs: Double = 0
    }

    /// Frames on the GPU at most (the upload arena has one slot more).
    static let framesInFlight = 2

    let device: MTLDevice
    let queue: MTLCommandQueue
    let view: GameView
    let sk: SKRenderer
    let timeline = GPUTimeline()
    let drawables: DrawableQueue
    private(set) var scene: GameScene?
    private var link: CADisplayLink?
    private var linkTarget: DisplayLinkTarget?
    private let slots = DispatchSemaphore(value: FrameLoop.framesInFlight)
    private let finalPass = MTLRenderPassDescriptor()
    private var observers: [NSObjectProtocol] = []
    private var fps = 60
    /// Below the panel's rate, presents wait for the display link's target time (an even cadence).
    private var pacedPresent = false
    /// When the frame being built is due on screen (CADisplayLink.targetTimestamp of this tick).
    private var targetTime: CFTimeInterval = 0
    private var worldScale: CGFloat
    private var inBackground = false
    private var frameID = 0
    private(set) var frameOpen = false
    private(set) var lastTick = Tick()
    // heartbeat counters
    private(set) var slotMisses = 0
    private(set) var slotMissTotal = 0
    private(set) var noDrawable = 0
    private(set) var noDrawableTotal = 0

    init(device: MTLDevice, queue: MTLCommandQueue, view: GameView, worldScale: CGFloat) {
        self.device = device
        self.queue = queue
        self.view = view
        self.worldScale = worldScale
        sk = SKRenderer(device: device)
        sk.ignoresSiblingOrder = true
        // the HUD hides what it does not show; SpriteKit's own visibility pass would only repeat that
        sk.shouldCullNonVisibleNodes = false
        let layer = view.metalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        drawables = DrawableQueue(layer: layer)
        let bg = Palette.backgroundUI
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        _ = bg.getRed(&r, green: &g, blue: &b, alpha: &a)
        finalPass.colorAttachments[0].loadAction = .clear
        finalPass.colorAttachments[0].storeAction = .store
        finalPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(r), green: Double(g), blue: Double(b), alpha: 1)
        let nc = NotificationCenter.default
        // no GPU work in the background (iOS kills apps that commit command buffers there): stop the loop
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setBackground(true)
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setBackground(false)
        })
    }

    deinit {
        link?.invalidate()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Start drawing `scene` (once).
    func present(_ scene: GameScene) {
        self.scene = scene
        sk.scene = scene
        view.touchTarget = scene
        layout()
        let t = DisplayLinkTarget(self)
        let l = t.makeLink()
        linkTarget = t
        link = l
        applyRate()
        l.add(to: .main, forMode: .common)
        AppLog.info("frame loop: display link started, \(FrameLoop.framesInFlight) frames in flight, max \(UIScreen.main.maximumFramesPerSecond) Hz")
    }

    /// The view's bounds changed (rotation, first layout): drawable at the screen scale, world target at the world
    /// scale, scene size in points.
    func layout() {
        let b = view.bounds.size
        guard b.width > 0, b.height > 0 else { return }
        let s = UIScreen.main.nativeScale
        let want = CGSize(width: (b.width * s).rounded(), height: (b.height * s).rounded())
        if want != drawableSize {
            drawableSize = want
            drawables.resize(want, scale: s)
            AppLog.info("metal: view \(Int(b.width))x\(Int(b.height)) pt, drawable \(Int(want.width))x\(Int(want.height)) px (scale \(s))")
        }
        if let sc = scene, sc.size != b { sc.size = b }
    }

    /// The drawable size last asked for (pixels).
    private var drawableSize = CGSize.zero

    private var worldPixels: (Int, Int) {
        let b = view.bounds.size
        return (Int((b.width * worldScale).rounded()), Int((b.height * worldScale).rounded()))
    }

    private func setBackground(_ on: Bool) {
        inBackground = on
        link?.isPaused = on
        AppLog.info(on ? "frame loop paused (background)" : "frame loop resumed")
    }

    // ---------------------------------------------------------------- GameHost
    var safeAreaInsets: UIEdgeInsets { view.safeAreaInsets }
    var touchView: UIView? { view }

    func setFrameRate(_ f: Int) {
        if f == fps { return }
        fps = f
        applyRate()
        AppLog.info("frame rate \(f) Hz")
    }

    func setWorldScale(_ s: CGFloat) {
        if s == worldScale { return }
        worldScale = s
        AppLog.info(String(format: "world scale %.1f", Double(s)))
    }

    private func applyRate() {
        guard let l = link else { return }
        let f = Float(fps)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(f, 60), maximum: f, preferred: f)
        // below the panel's rate (60 Hz on a 120 Hz ProMotion screen, the 30 Hz menus) each image is presented at
        // its tick's target time: presents land on an even vsync cadence instead of whenever the GPU finished
        pacedPresent = fps < UIScreen.main.maximumFramesPerSecond
    }

    // ---------------------------------------------------------------- frame
    func tick(_ link: CADisplayLink) {
        guard !inBackground, let scene = scene else { return }
        let t0 = FrameTimer.now()
        drawables.applyPendingResize()
        // never wait for the GPU or the compositor: no free slot or no drawable back yet = this tick simulates
        // without drawing
        var drawable: CAMetalDrawable?
        if slots.wait(timeout: .now()) == .success {
            drawable = drawables.take()
            if drawable == nil { slots.signal(); noDrawable += 1; noDrawableTotal += 1 }
        } else {
            slotMisses += 1
            slotMissTotal += 1
        }
        let open = drawable != nil
        frameOpen = open
        let r = scene.renderer
        if let r = r {
            let (w, h) = worldPixels
            r.setTargetSize(width: w, height: h)
            if open { r.beginFrame() } else { r.frameOpen = false }
        }
        targetTime = link.targetTimestamp
        sk.update(atTime: link.timestamp)
        let t1 = FrameTimer.now()
        if let d = drawable, !draw(r, d) {
            r?.frameOpen = false
            slots.signal()
        }
        let t2 = FrameTimer.now()
        lastTick.updateMs = (t1 - t0) * 1000
        lastTick.drawMs = (t2 - t1) * 1000
        frameOpen = false
    }

    /// Encode world + composite + HUD into one command buffer and present it. false = nothing was committed.
    private func draw(_ r: MetalRenderer?, _ d: CAMetalDrawable) -> Bool {
        guard let cb = queue.makeCommandBuffer() else { return false }
        cb.label = "frame"
        r?.encodeWorld(cb)
        let tex = d.texture
        finalPass.colorAttachments[0].texture = tex
        guard let enc = cb.makeRenderCommandEncoder(descriptor: finalPass) else { return false }
        enc.label = "composite + HUD"
        r?.encodeComposite(enc)
        sk.render(withViewport: CGRect(x: 0, y: 0, width: tex.width, height: tex.height), renderCommandEncoder: enc,
                  renderPassDescriptor: finalPass, commandQueue: queue)
        enc.endEncoding()
        finalPass.colorAttachments[0].texture = nil
        if pacedPresent && targetTime > 0 { cb.present(d, atTime: targetTime) } else { cb.present(d) }
        let id = frameID
        frameID += 1
        let tl = timeline, sem = slots
        tl.committed(id, at: CACurrentMediaTime())
        cb.addScheduledHandler { _ in tl.scheduled(id, at: CACurrentMediaTime()) }
        cb.addCompletedHandler { c in
            tl.completed(id, at: CACurrentMediaTime(), gpu: c.gpuEndTime - c.gpuStartTime)
            sem.signal()
        }
        cb.commit()
        return true
    }

    func takeCounters() -> (slotMisses: Int, noDrawable: Int, drawableMaxMs: Double) {
        let c = (slotMisses, noDrawable, drawables.takeWaitMax())
        slotMisses = 0
        noDrawable = 0
        return c
    }
}
