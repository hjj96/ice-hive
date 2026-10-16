import SpriteKit
import IceHiveCore

// ================================================================
//  WORLD PRESENTER — what GameScene needs from a world renderer, so
//  the same scene (simulation loop, events, HUD, audio, demos) drives
//  either the SpriteKit WorldRenderer or the Metal renderer
//  (`-renderer metal|spritekit`).
// ================================================================

/// World → HUD mapping for the nameplates and the objective marker.
protocol HUDProjection: AnyObject {
    /// World point → HUD point (camera-local: origin at the view centre, y up, points).
    func hudPoint(_ x: Float, _ y: Float, _ z: Float) -> CGPoint
    /// Interpolated feet of marine k (world).
    func feet(_ k: Int) -> (Float, Float, Float)
}

/// Per-frame counters for the heartbeat log and the debug HUD.
struct WorldStats {
    var visibleBugs = 0
    var particles = 0
    /// SpriteKit: visible level chunks; Metal: draw calls.
    var chunks = 0
    /// SpriteKit: nodes; Metal: instances drawn.
    var nodes = 0
    var drawCalls = 0
    var instances = 0
    var triangles = 0
    /// Metal only: CPU encode time, GPU time of the frame, wait for a free frame slot (ms).
    var encodeMs: Double = 0
    var gpuMs: Double = 0
    var waitMs: Double = 0
}

protocol WorldPresenter: HUDProjection {
    var rendererName: String { get }
    /// Effect density of the quality tier (web fxK).
    var fxK: Float { get set }
    var timer: FrameTimer { get }
    var stats: WorldStats { get }
    func reset()
    func handle(_ e: GameEvent, game: Game)
    func update(game: Game, alpha: Float, dt: Float, time: Float, camera: CameraController)
}

extension WorldRenderer: WorldPresenter {
    var rendererName: String { "spritekit" }

    var fxK: Float {
        get { fx.fxK }
        set { fx.fxK = newValue }
    }

    var stats: WorldStats {
        var s = WorldStats()
        s.visibleBugs = bugs.visibleCount
        s.particles = fx.pa.visibleCount + fx.pn.visibleCount
        s.chunks = levelLayer.visibleChunks
        s.nodes = levelLayer.nodeCount + dynamicNodeCount
        return s
    }

    func hudPoint(_ x: Float, _ y: Float, _ z: Float) -> CGPoint {
        guard let c = cameraRef else { return .zero }
        return c.toHUD(Iso.point(x, y, z))
    }

    func feet(_ k: Int) -> (Float, Float, Float) {
        k >= 0 && k < marines.feet.count ? marines.feet[k] : (0, 0, 0)
    }
}
