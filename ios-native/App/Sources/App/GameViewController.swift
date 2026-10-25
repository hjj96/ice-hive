import UIKit
import SpriteKit
import Metal

final class GameViewController: UIViewController {
    let options: LaunchOptions
    private var presentedScene: GameScene?
    private var observers: [NSObjectProtocol] = []
    private var lastLayoutSize = CGSize.zero

    init(options: LaunchOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The display link, the one CAMetalLayer (world + HUD) and SKRenderer for the HUD scene.
    private var loop: FrameLoop?
    /// Metal meshes / textures / pipelines, loading from loadView on.
    private var metalPreload: MetalPreload?

    /// «Не удалось запустить графику (Metal)» — shown instead of the game when Metal is unusable.
    static let metalFailureText = "Не удалось запустить графику (Metal).\nПерезапустите игру."

    override func loadView() {
        let bounds = UIScreen.main.bounds
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            // every iOS 16 device has Metal; without it there is nothing to draw with, not even the HUD
            AppLog.error("metal: no Metal device / command queue")
            view = GameViewController.failureView(bounds)
            return
        }
        queue.label = "IceHive"
        let gv = GameView(frame: bounds)
        gv.backgroundColor = Palette.backgroundUI
        gv.isOpaque = true
        gv.isMultipleTouchEnabled = true
        gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        loop = FrameLoop(device: device, queue: queue, view: gv, worldScale: CGFloat(options.metalScale ?? 2))
        metalPreload = MetalPreload(device: device, queue: queue, fail: options.failMetal)
        // first wrapped text layout of the process stalls for seconds: paid here, off the main thread
        TextWarmup.start()
        gv.onLayout = { [weak self] in self?.loop?.layout() }
        view = gv
    }

    /// Plain UIKit message (no Metal device at all).
    private static func failureView(_ bounds: CGRect) -> UIView {
        let v = UIView(frame: bounds)
        v.backgroundColor = Palette.backgroundUI
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let l = UILabel(frame: bounds.insetBy(dx: 24, dy: 0))
        l.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        l.text = metalFailureText
        l.textColor = UIColor(red: 0xdb / 255.0, green: 0xe6 / 255.0, blue: 0xee / 255.0, alpha: 1)
        l.font = UIFont(name: "Oswald-Medium", size: 17) ?? UIFont.systemFont(ofSize: 17, weight: .medium)
        l.numberOfLines = 0
        l.textAlignment = .center
        v.addSubview(l)
        return v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.appWillResignActive()
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.appDidBecomeActive()
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            AppLog.info("thermal state \(ProcessInfo.processInfo.thermalState.rawValue)")
            self?.presentedScene?.applyQuality()
        })
        observers.append(nc.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.applyFrameRate()
        })
        observers.append(nc.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.applyReduceMotion()
        })
        observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.didReceiveMemoryWarning()
        })
        AppLog.info("view ready maxFPS=\(UIScreen.main.maximumFramesPerSecond) scale=\(UIScreen.main.nativeScale) worldScale=\(options.metalScale ?? 2)"
                    + (loop == nil ? " (no Metal)" : ""))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let loop = loop else { return }
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if presentedScene == nil {
            let scene = GameScene(size: size, options: options, host: loop, metalPreload: metalPreload)
            scene.scaleMode = .fill
            presentedScene = scene
            loop.present(scene)
            scene.boot()
            AppLog.info("scene presented size=\(Int(size.width))x\(Int(size.height)) iface=\(interfaceOrientationName)")
        } else {
            loop.layout()
            if size != lastLayoutSize { AppLog.info("view resized \(Int(size.width))x\(Int(size.height)) iface=\(interfaceOrientationName)") }
        }
        lastLayoutSize = size
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

    /// Landscape only (Info.plist lists landscape right + left): the game, its HUD and its menus have one layout.
    /// `-orient left|right` pins one side (CI: the screenshots then rotate the same way every run).
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch options.orientation {
        case "left": return .landscapeLeft
        case "right": return .landscapeRight
        default: return .landscape
        }
    }

    /// Dynamic Island / notch on the left, home indicator at the bottom (the side the Info.plist lists first).
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        options.orientation == "left" ? .landscapeLeft : .landscapeRight
    }

    override var shouldAutorotate: Bool { return true }

    /// «landscapeRight» / «landscapeLeft» (CI turns its screenshots upright by it).
    private var interfaceOrientationName: String {
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeRight?: return "landscapeRight"
        case .landscapeLeft?: return "landscapeLeft"
        case .portrait?: return "portrait"
        case .portraitUpsideDown?: return "portraitUpsideDown"
        default: return "unknown"
        }
    }
}
