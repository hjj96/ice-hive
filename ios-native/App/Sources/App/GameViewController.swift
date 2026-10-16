import UIKit
import SpriteKit

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

    private var skView: SKView {
        // swiftlint:disable:next force_cast
        return view as! SKView
    }

    override func loadView() {
        let skView = SKView(frame: UIScreen.main.bounds)
        skView.backgroundColor = Palette.backgroundUI
        view = skView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let view = skView
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
        AppLog.info("SKView ready maxFPS=\(maxFPS) preferredFPS=\(view.preferredFramesPerSecond) cull=\(options.cull) hud=\(showHUD)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if presentedScene == nil {
            let scene = GameScene(size: size, options: options)
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
