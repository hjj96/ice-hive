import CoreGraphics

// ================================================================
//  HUD PROJECTION / WORLD STATS — what the HUD and the heartbeat log
//  need from the world renderer.
// ================================================================

/// World → HUD mapping for the nameplates and the objective marker.
protocol HUDProjection: AnyObject {
    /// World point → HUD point (camera-local: origin at the view centre, y up, points).
    func hudPoint(_ x: Float, _ y: Float, _ z: Float) -> CGPoint
    /// Interpolated feet of marine k (world).
    func feet(_ k: Int) -> (Float, Float, Float)
}

/// Counters of the last built world frame, for the heartbeat log and the debug HUD.
struct WorldStats {
    var visibleBugs = 0
    var particles = 0
    var drawCalls = 0
    var instances = 0
    var triangles = 0
    /// CPU encode time of a world frame (ms, smoothed).
    var encodeMs: Double = 0
}
