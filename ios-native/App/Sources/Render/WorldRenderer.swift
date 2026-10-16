import SpriteKit
import IceHiveCore

// ================================================================
//  WORLD RENDERER — owns every world-space layer and draws one frame
//  of a Game: level (static, chunk-culled), squad, swarm, effects,
//  then the darkness overlay with the flashlights and point lights.
// ================================================================
final class WorldRenderer {
    let world = SKNode()
    /// Flat (top-down) textures live here: yScale = sin(pitch).
    let groundRoot = SKNode()
    let assets: SpriteAssets
    let levelLayer: LevelLayer
    let bugs: BugLayer
    let marines: MarineLayer
    let fx: FxLayer
    let lighting: LightingLayer
    let motes: MotesLayer
    let weather: WeatherLayer
    private var emberRng = SeededRNG(seed: 31337)
    let timer = FrameTimer(["lvl", "mar", "bug", "fx", "wx", "light"])
    /// Flashlights of this frame (stored: no array allocation per frame).
    private var flashlights: [LightingLayer.Flashlight] = []

    init(level: Level, assets: SpriteAssets, bugCapacity: Int) {
        self.assets = assets
        lighting = LightingLayer(level: level)
        groundRoot.yScale = Iso.groundSquash
        world.addChild(groundRoot)
        levelLayer = LevelLayer(level: level, assets: assets, groundRoot: groundRoot)
        world.addChild(levelLayer.root)
        bugs = BugLayer(assets: assets, capacity: bugCapacity)
        world.addChild(bugs.root)
        marines = MarineLayer(assets: assets)
        world.addChild(marines.root)
        fx = FxLayer(assets: assets, level: level, worldRoot: world, groundRoot: groundRoot)
        world.addChild(fx.root)
        motes = MotesLayer(texture: assets.texture("bg_motes"))
        weather = WeatherLayer(assets: assets, snow: 700, mist: 9)
        flashlights.reserveCapacity(4)
        world.addChild(weather.root)
        let pa = fx.pa
        bugs.onBurning = { [weak pa] x, y, z, s in
            guard let pa = pa else { return }
            pa.emit(x + pa.rr(-0.2, 0.2), y, z + pa.rr(-0.2, 0.2), 0, pa.rr(1, 2.2), 0, pa.rr(0.25, 0.45),
                    0.35 * s, 0.7 * s, 1, 0.6, 0.25, 0.55, -0.5, 1, 1, absolute: true)
        }
    }

    /// The darkness overlay and the mote field are camera children (screen space).
    func attach(to camera: CameraController) {
        camera.node.addChild(lighting.node)
        camera.node.addChild(motes.root)
    }

    func reset() { fx.reset() }

    /// Every pool filled up front (loading screen): ~5k hidden sprites, so neither a horde reaching the screen nor
    /// a burst of corpses / particles creates nodes during play.
    func reservePools(bugs n: Int) {
        let t0 = FrameTimer.now()
        let before = SpritePool.created
        bugs.reserve(n)
        fx.reserve()
        weather.reserve()
        AppLog.info(String(format: "pools reserved: %d sprites in %.0f ms", SpritePool.created - before,
                           (FrameTimer.now() - t0) * 1000))
    }

    func handle(_ e: GameEvent, game: Game) { fx.handle(e, game: game) }

    func update(game: Game, alpha: Float, dt: Float, time: Float, camera: CameraController) {
        let visible = camera.visibleRect
        let rise = game.liftRise
        timer.begin()
        levelLayer.update(visible: visible, liftRise: rise)
        timer.mark()
        fx.beginFrame()
        marines.update(game: game, alpha: alpha, dt: dt, time: time, liftRise: rise, ground: fx.ground)
        timer.mark()
        bugs.update(game: game, alpha: alpha, time: time, dt: dt, visible: visible)
        timer.mark()
        fx.update(game: game, dt: dt, time: time, visible: visible, liftRise: rise, feet: marines.feet)
        fx.endFrame()
        timer.mark()
        motes.update(camera: camera, time: time)
        weather.update(time: time, cx: camera.tx, cy: camera.ty, cz: camera.tz, visible: visible, cameraScale: camera.scale)
        timer.mark()

        // flashlights: the player's beam is the strongest (web spots: 62 player / 42 bots, 12 flickering when downed)
        flashlights.removeAll(keepingCapacity: true)
        let toShader: Float = 1 / Float.pi
        for (k, m) in game.marines.enumerated() where k < 4 {
            let f = marines.feet[k]
            var i: Float
            if m.downed {
                i = 12 * (0.6 + 0.4 * sinf(time * 9 + Float(k)))
            } else {
                i = (m.isPlayer ? 62 : 42) * (m.firing ? 1.12 : 1) * (m.hurtT > 0 ? 0.6 + 0.4 * sinf(time * 60) : 1)
            }
            flashlights.append(LightingLayer.Flashlight(x: f.0, y: f.1, z: f.2, ax: m.ax, az: m.az, intensity: i * toShader))
        }
        lighting.update(viewSize: camera.viewSize, ppm: camera.screenPPM, camera: camera.node.position, scale: camera.scale,
                        liftRise: rise, toScreen: { camera.toScreen($0) }, flashlights: flashlights, points: fx.lights)
        timer.mark()
    }

    var dynamicNodeCount: Int { bugs.nodeCount + fx.nodeCount + 16 }
}

/// Pink motes drifting up from the abyss (Background/bg_motes, additive), tiled in screen space with parallax.
final class MotesLayer {
    let root = SKNode()
    private var tiles: [SKSpriteNode] = []
    private let tile: CGFloat = 512

    init(texture: SKTexture) {
        root.zPosition = 0
        for k in 0..<12 {
            let s = SKSpriteNode(texture: texture)
            s.size = CGSize(width: tile, height: tile)
            s.blendMode = .add
            s.alpha = k < 6 ? 0.7 : 0.45
            s.zPosition = ZBand.background + 2
            root.addChild(s)
            tiles.append(s)
        }
    }

    func update(camera: CameraController, time: Float) {
        let W = camera.viewSize.width, H = camera.viewSize.height
        let cols = Int((W / tile).rounded(.up)) + 1
        let rows = Int((H / tile).rounded(.up)) + 1
        let p = camera.node.position
        var k = 0
        for layer in 0..<2 {
            let par: CGFloat = layer == 0 ? 0.35 : 0.6
            let rise = CGFloat(time) * (layer == 0 ? 6 : 10)
            var ox = (-p.x * par / camera.scale).truncatingRemainder(dividingBy: tile)
            var oy = (-p.y * par / camera.scale + rise).truncatingRemainder(dividingBy: tile)
            if ox > 0 { ox -= tile }
            if oy > 0 { oy -= tile }
            for r in 0..<rows {
                for c in 0..<cols {
                    if k >= tiles.count { break }
                    let s = tiles[k]
                    s.isHidden = false
                    s.position = CGPoint(x: -W / 2 + ox + CGFloat(c) * tile + tile / 2, y: -H / 2 + oy + CGFloat(r) * tile + tile / 2)
                    k += 1
                }
            }
        }
        while k < tiles.count { tiles[k].isHidden = true; k += 1 }
    }
}
