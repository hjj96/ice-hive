import SpriteKit
import UIKit

/// Placeholder scene: dark background, centred title and a grid of 2000 moving sprites
/// sharing one texture (performance sanity check for the SpriteKit renderer).
final class GameScene: SKScene {
    static let spriteCount: Int = 2000

    private let options: LaunchOptions
    private let world = SKNode()
    private var sprites: [SKSpriteNode] = []
    private var basePositions: [CGPoint] = []
    private var phases: [CGFloat] = []
    private let titleLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let subtitleLabel = SKLabelNode(fontNamed: "Menlo-Regular")

    private var startTime: TimeInterval = -1
    private var lastTime: TimeInterval = 0
    private var frameCount: Int = 0
    private var fpsWindowStart: TimeInterval = 0
    private var lastHeartbeat: TimeInterval = 0
    private var reportedReady = false
    private var reportedDone = false

    init(size: CGSize, options: LaunchOptions) {
        self.options = options
        super.init(size: size)
        backgroundColor = Palette.background
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMove(to view: SKView) {
        if sprites.isEmpty {
            buildScene()
        }
        layoutScene()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        if !sprites.isEmpty {
            layoutScene()
        }
    }

    // MARK: - Build

    private static func makeDotTexture() -> SKTexture {
        let side: CGFloat = 16
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(white: 1.0, alpha: 1.0).cgColor, UIColor(white: 1.0, alpha: 0.0).cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0]) {
                let center = CGPoint(x: side / 2, y: side / 2)
                cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                      endCenter: center, endRadius: side / 2, options: [])
            }
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }

    private func buildScene() {
        addChild(world)
        let texture = GameScene.makeDotTexture()
        sprites.reserveCapacity(GameScene.spriteCount)
        for i in 0..<GameScene.spriteCount {
            let sprite = SKSpriteNode(texture: texture)
            sprite.size = CGSize(width: 9, height: 9)
            let t = CGFloat(i % 97) / 97.0
            sprite.color = t < 0.5 ? Palette.ice : Palette.teal
            sprite.colorBlendFactor = 1.0
            sprite.alpha = 0.55 + 0.4 * t
            sprite.blendMode = .add
            sprite.zPosition = 0
            world.addChild(sprite)
            sprites.append(sprite)
            phases.append(CGFloat(i) * 0.37)
        }
        basePositions = Array(repeating: .zero, count: sprites.count)

        titleLabel.text = "ЛЕДЯНОЙ УЛЕЙ"
        titleLabel.fontColor = SKColor(white: 0.95, alpha: 1.0)
        titleLabel.verticalAlignmentMode = .center
        titleLabel.horizontalAlignmentMode = .center
        titleLabel.zPosition = 10
        addChild(titleLabel)

        subtitleLabel.text = "v\(AppInfo.versionString) · core \(AppInfo.coreVersion) · \(GameScene.spriteCount) спрайтов"
        subtitleLabel.fontColor = Palette.ice
        subtitleLabel.verticalAlignmentMode = .center
        subtitleLabel.horizontalAlignmentMode = .center
        subtitleLabel.zPosition = 10
        addChild(subtitleLabel)
    }

    private func layoutScene() {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return }
        let count = sprites.count
        // Choose a grid whose aspect matches the screen.
        let cols = max(1, Int((Double(count) * Double(w / h)).squareRoot().rounded()))
        let rows = max(1, (count + cols - 1) / cols)
        let stepX = w / CGFloat(cols)
        let stepY = h / CGFloat(rows)
        for i in 0..<count {
            let c = i % cols
            let r = i / cols
            basePositions[i] = CGPoint(x: -w / 2 + stepX * (CGFloat(c) + 0.5),
                                       y: -h / 2 + stepY * (CGFloat(r) + 0.5))
        }
        titleLabel.fontSize = min(w, h) * 0.105
        titleLabel.position = CGPoint(x: 0, y: 0)
        subtitleLabel.fontSize = max(11, min(w, h) * 0.032)
        subtitleLabel.position = CGPoint(x: 0, y: -titleLabel.fontSize * 0.95)
    }

    // MARK: - Update

    override func update(_ currentTime: TimeInterval) {
        if startTime < 0 {
            startTime = currentTime
            lastTime = currentTime
            fpsWindowStart = currentTime
            lastHeartbeat = currentTime
        }
        let t = CGFloat(currentTime - startTime)
        lastTime = currentTime

        let amp: CGFloat = 6
        for i in 0..<sprites.count {
            let base = basePositions[i]
            let p = phases[i]
            sprites[i].position = CGPoint(x: base.x + amp * sin(t * 1.7 + p),
                                          y: base.y + amp * cos(t * 1.3 + p * 1.1))
        }
        let pulse = 0.85 + 0.15 * sin(t * 2.0)
        titleLabel.alpha = pulse

        frameCount += 1
        if !reportedReady {
            reportedReady = true
            AppLog.info("scene ready sprites=\(sprites.count) size=\(Int(size.width))x\(Int(size.height))")
        }
        if currentTime - lastHeartbeat >= 1.0 {
            let fps = Double(frameCount) / max(0.001, currentTime - fpsWindowStart)
            AppLog.info(String(format: "hb t=%.1f fps=%.1f nodes=%d demo=%@",
                               Double(t), fps, sprites.count + 3, options.demo ?? "-"))
            frameCount = 0
            fpsWindowStart = currentTime
            lastHeartbeat = currentTime
        }
        if let seconds = options.seconds, !reportedDone, Double(t) >= seconds {
            reportedDone = true
            AppLog.info("demo done after \(seconds)s")
        }
    }
}
