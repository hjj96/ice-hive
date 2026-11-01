import SpriteKit
import IceHiveCore

// ================================================================
//  CAMERA — follows the player like updateCamera() of 12-main.js, for
//  the landscape-only screen (LAND): the view is ≈ 47 m across but only
//  ≈ 26 m of deck top to bottom, so the aim lead runs along the screen's
//  long axis (3.6 m sideways, 1.5 m along the depth) and the look-at
//  point sits 2.4 m toward screen-down — the player stands a little above
//  the centre, in the free band between the top HUD row and the thumbs
//  / armour bar at the bottom; damped follow, floor-height follow, shake
//  and a tiny recoil kick. `zoom` (1.10 in a packed screen, hysteresis
//  240 / 180 bugs near the target) is the crowd pull-back MetalCamera
//  applies to its distance. MetalCamera builds the web's perspective
//  camera from `focus`, `shakeOffset` and `zoom`. `node` is the SpriteKit
//  camera the HUD, menus and loading cover hang from: it stays at the
//  scene origin, unscaled, so HUD points are view points (origin at the
//  centre, y up).
// ================================================================
final class CameraController {
    let node = SKCameraNode()
    private(set) var tx: Float = 0, ty: Float = 0, tz: Float = 0
    private var initialized = false
    private var shake: Float = 0
    private var rng = SeededRNG(seed: 555)
    var reducedMotion = false
    /// Shake offset, re-rolled at the 60 Hz simulation rate (not every 120 Hz frame) so its jitter does not
    /// depend on the display rate.
    private var shakeOff: (Float, Float, Float) = (0, 0, 0)
    private var shakeAcc: Float = 0
    /// Look-at point of this frame (target + recoil kick) and the camera position jitter (shake).
    private(set) var focus: (Float, Float, Float) = (0, 0, 0)
    private(set) var shakeOffset: (Float, Float, Float) = (0, 0, 0)
    /// Crowd pull-back: camera distance factor, 1 … 1.10 (smoothed; MetalCamera multiplies its distance by it).
    private(set) var zoom: Float = 1
    /// Aim lead along the screen's long (right) axis and its depth (up) axis, and the push toward screen-down (m).
    static let leadSide: Float = 3.6, leadDepth: Float = 1.5, pushDown: Float = 2.4
    private var zoomWant: Float = 1
    /// Per-round recoil of the player's weapon (native-vx-squad): each round kicks the look-at back along the aim with a
    /// fast attack and a ~45 ms half-life (the rifle's 9 rounds/s read as distinct thumps; the old `muzzle × 7 cm`
    /// sawtooth was ≈ 0.1° at the game camera — invisible); the rotary adds a fine rumble, the flamer and the cryo
    /// projector a low tremor while they run. Reduce Motion: 35 %.
    private var recoil: Float = 0
    private var lastMuzzle: Float = 0
    private var rumble: Float = 0

    func addShake(_ a: Float) {
        shake = min(1.4, shake + a * (reducedMotion ? 0.35 : 1))
    }

    /// Snap to the player (new mission / teleport).
    func reset() { initialized = false }

    /// `feet` = interpolated player position; `title` = slow attract-mode camera.
    /// `bugsNear` = live bugs within 22 m of the camera target (web nearCam).
    func update(game: Game, feet: (Float, Float, Float), dt: Float, viewSize: CGSize, title: Bool, liftRise: Float, bugsNear: Int = 0) {
        let P = game.player
        let dn: Float = title ? 0 : CameraController.pushDown
        // lead along the screen's axes (mostly sideways: the long axis), then the push toward screen-down
        let sr = P.ax * RIGHT_X + P.az * RIGHT_Z, su = P.ax * FWD_X + P.az * FWD_Z
        let lr: Float = title ? 0 : CameraController.leadSide, lu: Float = title ? 0 : CameraController.leadDepth
        let wantX = feet.0 + RIGHT_X * sr * lr + FWD_X * su * lu - FWD_X * dn
        let wantZ = feet.2 + RIGHT_Z * sr * lr + FWD_Z * su * lu - FWD_Z * dn
        if title { zoomWant = 1 } else if bugsNear > 240 { zoomWant = 1.1 } else if bugsNear < 180 { zoomWant = 1 }
        zoom += (zoomWant - zoom) * (1 - expf(-1.2 * dt))
        let extract = game.stage == .extract
        let wantY = game.level.groundY(feet.0, feet.2) + (extract && game.level.onLift(P.x, P.z) ? liftRise * 0.55 : 0)
        if !initialized {
            initialized = true
            tx = wantX; ty = wantY; tz = wantZ
        } else {
            let k = 1 - expf(-(title ? 1.5 : 5) * dt)
            tx += (wantX - tx) * k
            tz += (wantZ - tz) * k
            ty += (wantY - ty) * (1 - expf(-(extract ? 8 : 4) * dt))
        }
        shake *= expf(-6 * dt)
        let sk = shake * 0.35
        let armed = !(title || P.downed)
        let rm: Float = reducedMotion ? 0.35 : 1
        if armed && P.muzzle > lastMuzzle + 0.3 {
            recoil = min(1.6, recoil + (P.cls == .gunner ? 0.5 : 1))
            if P.cls == .gunner { rumble = min(0.8, rumble + 0.12) }
        }
        lastMuzzle = P.muzzle
        recoil *= expf(-15 * dt)
        let stream = armed && P.firing && (P.cls == .pyro || P.cls == .cryo)
        rumble = stream ? min(0.45, rumble + 2.5 * dt) : rumble * expf(-7 * dt)
        let kick: Float = armed ? recoil * (P.cls == .gunner ? 0.12 : 0.2) * rm : 0
        let kx = -P.ax * kick, kz = -P.az * kick
        shakeAcc += dt
        if shakeAcc >= 1 / 60 {
            shakeAcc = min(shakeAcc - 1 / 60, 1 / 60)
            shakeOff = ((rng.next() - 0.5), (rng.next() - 0.5), (rng.next() - 0.5))
        }
        focus = (tx + kx, ty, tz + kz)
        let rb = rumble * 0.06 * rm
        shakeOffset = (shakeOff.0 * (sk + rb), shakeOff.1 * (sk + rb * 0.5), shakeOff.2 * (sk + rb))
    }
}
