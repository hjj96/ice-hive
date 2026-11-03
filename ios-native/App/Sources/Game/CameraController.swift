import SpriteKit
import IceHiveCore

// ================================================================
//  CAMERA — follows the player like updateCamera() of 12-main.js, for
//  the landscape-only screen (LAND): the view is ≈ 47 m across but only
//  ≈ 26 m of deck top to bottom, so the aim lead runs along the screen's
//  long axis (2.6 m sideways, 1.1 m along the depth, following a slowly
//  smoothed aim) and the look-at point sits 2.4 m toward screen-down — the
//  player stands a little above the centre, in the free band between the
//  top HUD row and the thumbs / armour bar at the bottom; damped follow
//  (3.4 /s), floor-height follow, a trauma shake for big events only and
//  a small recoil kick (native-vx-feel: a calmer camera). `zoom` (1.08 in
//  a packed screen, hysteresis 150 / 110 bugs near the target) is the
//  crowd pull-back MetalCamera applies to its distance. MetalCamera builds the web's perspective
//  camera from `focus`, `shakeOffset` and `zoom`. `node` is the SpriteKit
//  camera the HUD, menus and loading cover hang from: it stays at the
//  scene origin, unscaled, so HUD points are view points (origin at the
//  centre, y up).
// ================================================================
final class CameraController {
    let node = SKCameraNode()
    private(set) var tx: Float = 0, ty: Float = 0, tz: Float = 0
    private var initialized = false
    private var rng = SeededRNG(seed: 555)
    var reducedMotion = false
    /// Shake direction this frame: smooth value noise (14 Hz, advanced by time, so it does not depend on the display rate).
    private var shakeOff: (Float, Float, Float) = (0, 0, 0)
    /// Look-at point of this frame (target + recoil kick) and the camera position jitter (shake).
    private(set) var focus: (Float, Float, Float) = (0, 0, 0)
    private(set) var shakeOffset: (Float, Float, Float) = (0, 0, 0)
    /// Crowd pull-back: camera distance factor, 1 … 1.08 (smoothed; MetalCamera multiplies its distance by it).
    private(set) var zoom: Float = 1
    /// Aim lead along the screen's long (right) axis and its depth (up) axis, and the push toward screen-down (m).
    /// (native-vx-feel, a calmer camera: a shorter lead — 3.6 → 2.6 m sideways — that follows a slowly smoothed aim; the
    /// autopilot's aim snapping between targets swung the look-at point side to side by up to 7 m)
    static let leadSide: Float = 2.6, leadDepth: Float = 1.1, pushDown: Float = 2.4
    /// The aim direction the lead follows (smoothed, ~0.6 s), and the trauma of the shake (0…1; the offset is trauma²).
    private var leadAx: Float = 0, leadAz: Float = 0, trauma: Float = 0
    /// Smooth shake noise: two value-noise samples per axis, 14 Hz.
    private var noiseT: Float = 0
    private var n0: (Float, Float, Float) = (0, 0, 0), n1: (Float, Float, Float) = (0, 0, 0)
    private var zoomWant: Float = 1
    /// Per-round recoil of the player's weapon (native-vx-squad): each round kicks the look-at back along the aim with a
    /// fast attack and a ~45 ms half-life (the rifle's 9 rounds/s read as distinct thumps; the old `muzzle × 7 cm`
    /// sawtooth was ≈ 0.1° at the game camera — invisible); the rotary adds a fine rumble, the flamer and the cryo
    /// projector a low tremor while they run. Reduce Motion: 35 %.
    private var recoil: Float = 0
    private var lastMuzzle: Float = 0
    private var rumble: Float = 0

    /// Shake only on big events (trauma above a threshold; the offset grows with trauma²): a bite (0.12 + 0.012·dmg), the
    /// horde siren (0.25) or a distant blast stay under it; a blast near the player, a napalm / nova cast, the Queen and a
    /// down shake the camera. Reduce Motion: 35 %.
    static let shakeThreshold: Float = 0.26
    func addShake(_ a: Float) {
        let k = max(0, a - CameraController.shakeThreshold) * 1.6
        if k <= 0 { return }
        trauma = min(1, trauma + k * (reducedMotion ? 0.35 : 1))
    }

    /// Snap to the player (new mission / teleport).
    func reset() { initialized = false }

    /// `feet` = interpolated player position; `title` = slow attract-mode camera.
    /// `bugsNear` = live bugs within 22 m of the camera target (web nearCam).
    func update(game: Game, feet: (Float, Float, Float), dt: Float, viewSize: CGSize, title: Bool, liftRise: Float, bugsNear: Int = 0) {
        let P = game.player
        let dn: Float = title ? 0 : CameraController.pushDown
        // lead along the screen's axes (mostly sideways: the long axis), then the push toward screen-down
        if !initialized { leadAx = P.ax; leadAz = P.az }
        let ka = 1 - expf(-1.7 * dt)
        leadAx += (P.ax - leadAx) * ka; leadAz += (P.az - leadAz) * ka
        let sr = leadAx * RIGHT_X + leadAz * RIGHT_Z, su = leadAx * FWD_X + leadAz * FWD_Z
        let lr: Float = title ? 0 : CameraController.leadSide, lu: Float = title ? 0 : CameraController.leadDepth
        let wantX = feet.0 + RIGHT_X * sr * lr + FWD_X * su * lu - FWD_X * dn
        let wantZ = feet.2 + RIGHT_Z * sr * lr + FWD_Z * su * lu - FWD_Z * dn
        // (the wave pacing's peaks are smaller: the pull-back from 150 bugs near, back below 110)
        if title { zoomWant = 1 } else if bugsNear > 150 { zoomWant = 1.08 } else if bugsNear < 110 { zoomWant = 1 }
        zoom += (zoomWant - zoom) * (1 - expf(-1.2 * dt))
        let extract = game.stage == .extract
        let wantY = game.level.groundY(feet.0, feet.2) + (extract && game.level.onLift(P.x, P.z) ? liftRise * 0.55 : 0)
        if !initialized {
            initialized = true
            tx = wantX; ty = wantY; tz = wantZ
        } else {
            let k = 1 - expf(-(title ? 1.5 : 3.4) * dt)
            tx += (wantX - tx) * k
            tz += (wantZ - tz) * k
            ty += (wantY - ty) * (1 - expf(-(extract ? 8 : 4) * dt))
        }
        trauma = max(0, trauma - 1.6 * dt)
        let sk = trauma * trauma * 0.42
        let armed = !(title || P.downed)
        let rm: Float = reducedMotion ? 0.35 : 1
        if armed && P.muzzle > lastMuzzle + 0.3 {
            recoil = min(1.2, recoil + (P.cls == .gunner ? 0.35 : 0.8))
            if P.cls == .gunner { rumble = min(0.5, rumble + 0.06) }
        }
        lastMuzzle = P.muzzle
        recoil *= expf(-15 * dt)
        let stream = armed && P.firing && (P.cls == .pyro || P.cls == .cryo)
        rumble = stream ? min(0.45, rumble + 2.5 * dt) : rumble * expf(-7 * dt)
        // (a third of the old kick: still a thump per round, no longer a constant jitter of the frame)
        let kick: Float = armed ? recoil * (P.cls == .gunner ? 0.04 : 0.07) * rm : 0
        let kx = -P.ax * kick, kz = -P.az * kick
        // smooth value noise (14 Hz) instead of a white jitter re-rolled every frame
        noiseT += dt * 14
        while noiseT >= 1 {
            noiseT -= 1
            n0 = n1
            n1 = ((rng.next() - 0.5) * 2, (rng.next() - 0.5) * 2, (rng.next() - 0.5) * 2)
        }
        let u = noiseT * noiseT * (3 - 2 * noiseT)
        shakeOff = (n0.0 + (n1.0 - n0.0) * u, n0.1 + (n1.1 - n0.1) * u, n0.2 + (n1.2 - n0.2) * u)
        focus = (tx + kx, ty, tz + kz)
        let rb = rumble * 0.02 * rm
        shakeOffset = (shakeOff.0 * (sk + rb), shakeOff.1 * (sk + rb * 0.5), shakeOff.2 * (sk + rb))
    }
}
