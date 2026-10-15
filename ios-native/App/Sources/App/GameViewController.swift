import UIKit
import SpriteKit

final class GameViewController: UIViewController {
    let options: LaunchOptions
    private var presentedScene: GameScene?
    private var resignObserver: NSObjectProtocol?

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
        view.shouldCullNonVisibleNodes = true

        // 120 Hz on ProMotion iPhones (needs CADisableMinimumFrameDurationOnPhone in Info.plist), else 60.
        let maxFPS = UIScreen.main.maximumFramesPerSecond
        view.preferredFramesPerSecond = maxFPS >= 120 ? 120 : 60

        var showHUD = options.debugHUD
        #if DEBUG
        showHUD = true
        #endif
        view.showsFPS = showHUD
        view.showsNodeCount = showHUD
        view.showsDrawCount = showHUD

        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.presentedScene?.appWillResignActive()
        }
        AppLog.info("SKView ready maxFPS=\(maxFPS) preferredFPS=\(view.preferredFramesPerSecond) hud=\(showHUD)")
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
