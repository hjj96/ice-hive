import UIKit
import SpriteKit
import MetalKit

final class GameViewController: UIViewController {
    let options: LaunchOptions
    private var presentedScene: GameScene?
    private var observers: [NSObjectProtocol] = []

    init(options: LaunchOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The SpriteKit view: the whole game with `-renderer spritekit`; with `-renderer metal` only the HUD, menus and
    /// the loading cover, transparent over the MTKView that draws the world.
    private var skView: SKView!
    /// Metal world view (`-renderer metal`), drawn on demand from the scene's update (paused, no own display link).
    private(set) var metalView: MTKView?

    override func loadView() {
        let bounds = UIScreen.main.bounds
        let sk = SKView(frame: bounds)
        skView = sk
        if options.useMetal, let device = MTLCreateSystemDefaultDevice() {
            let root = UIView(frame: bounds)
            root.backgroundColor = Palette.backgroundUI
            let mv = MTKView(frame: bounds, device: device)
            mv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            mv.colorPixelFormat = .bgra8Unorm
            mv.depthStencilPixelFormat = .depth32Float
            mv.clearColor = MTLClearColor(red: 0x1a / 255.0, green: 0x27 / 255.0, blue: 0x37 / 255.0, alpha: 1)
            mv.isPaused = true
            mv.enableSetNeedsDisplay = false
            // the drawable size is set explicitly (applyMetalScale): UIKit resets contentScaleFactor to the screen's
            // scale when the view joins the window, so the default 2x drawable silently became 3x before (41337a8)
            mv.autoResizeDrawable = false
            mv.framebufferOnly = true
            mv.isUserInteractionEnabled = false
            mv.layer.magnificationFilter = .linear
            root.addSubview(mv)
            sk.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            sk.allowsTransparency = true
            sk.isOpaque = false
            sk.backgroundColor = .clear
            root.addSubview(sk)
            metalView = mv
            view = root
        } else {
            if options.useMetal { AppLog.error("metal: no Metal device, falling back to SpriteKit") }
            sk.backgroundColor = Palette.backgroundUI
            view = sk
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let view: SKView = skView
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true
        // every pool hides its unused / off-screen sprites and the level culls its own chunks: SpriteKit's per-node
        // visibility pass over ~7k nodes would only repeat that work (`-cull` turns it back on for A/B runs)
        view.shouldCullNonVisibleNodes = options.cull

        // 60 Hz like the 60 Hz simulation; the scene raises it to 120 on ProMotion only for «Графика: высокая»
        // while the device is cool and not in Low Power Mode (GameScene.applyFrameRate)
        let maxFPS = UIScreen.main.maximumFramesPerSecond
        view.preferredFramesPerSecond = 60

        var showHUD = options.debugHUD
        #if DEBUG
        showHUD = true
        #endif
        view.showsFPS = showHUD
        view.showsNodeCount = showHUD
        view.showsDrawCount = showHUD

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.appWillResignActive()
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.appDidBecomeActive()
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            AppLog.info("thermal state \(ProcessInfo.processInfo.thermalState.rawValue)")
            self?.presentedScene?.applyFrameRate()
        })
        observers.append(nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.applyFrameRate()
        })
        observers.append(nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.applyReduceMotion()
        })
        AppLog.info("SKView ready maxFPS=\(maxFPS) preferredFPS=\(view.preferredFramesPerSecond) cull=\(options.cull) hud=\(showHUD)"
                    + " renderer=\(metalView != nil ? "metal scale=\(metalScale)" : "spritekit")")
    }

    /// Pixels per point of the Metal drawable (`-mscale`, default 2 — the web phone build renders at a pixel ratio of
    /// 1.5 (med) / 2 (high) and lets the compositor scale it to the 3x screen).
    private var metalScale: CGFloat { CGFloat(options.metalScale ?? 2) }

    private func applyMetalScale() {
        guard let mv = metalView else { return }
        let b = mv.bounds.size
        let want = CGSize(width: (b.width * metalScale).rounded(), height: (b.height * metalScale).rounded())
        if want.width > 0, want.height > 0, mv.drawableSize != want { mv.drawableSize = want }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyMetalScale()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if presentedScene == nil {
            let scene = GameScene(size: size, options: options, metalView: metalView)
            scene.scaleMode = .resizeFill
            skView.presentScene(scene)
            presentedScene = scene
            AppLog.info("scene presented size=\(Int(size.width))x\(Int(size.height))")
        } else {
            presentedScene?.relayout()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        presentedScene?.relayout()
    }

    // hardware keyboard (simulator / iPad keyboards): WASD, IJKL, Space, Q, Esc
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let k = p.key { presentedScene?.keyDown(k.keyCode.rawValue); handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            if let k = p.key { presentedScene?.keyUp(k.keyCode.rawValue); handled = true }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for p in presses {
            if let k = p.key { presentedScene?.keyUp(k.keyCode.rawValue) }
        }
        super.pressesCancelled(presses, with: event)
    }

    override var prefersStatusBarHidden: Bool { return true }

    override var prefersHomeIndicatorAutoHidden: Bool { return false }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { return .bottom }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch options.orientation {
        case "landscape": return .landscape
        case "portrait": return .portrait
        default: return .allButUpsideDown
        }
    }

    override var shouldAutorotate: Bool { return true }
}
