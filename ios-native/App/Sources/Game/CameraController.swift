import SpriteKit
import IceHiveCore

// ================================================================
//  CAMERA — follows the player like updateCamera() of 12-main.js:
//  look-at point 2.4 m ahead along the aim, pushed toward screen-down
//  on touch (1.5 m portrait / 3 m landscape) so the thumbs hide less,
//  damped follow, floor-height follow, shake and a tiny recoil kick.
//  MetalCamera builds the web's perspective camera from `focus` and
//  `shakeOffset`. `node` is the SpriteKit camera the HUD, menus and
//  loading cover hang from: it stays at the scene origin, unscaled, so
//  HUD points are view points (origin at the centre, y up).
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

    func addShake(_ a: Float) {
        shake = min(1.4, shake + a * (reducedMotion ? 0.35 : 1))
    }

    /// Snap to the player (new mission / teleport).
    func reset() { initialized = false }

    /// `feet` = interpolated player position; `title` = slow attract-mode camera.
    func update(game: Game, feet: (Float, Float, Float), dt: Float, viewSize: CGSize, title: Bool, liftRise: Float) {
        let P = game.player
        let landscape = viewSize.width > viewSize.height
        let lead: Float = title ? 0 : 2.4
        let dn: Float = title ? 0 : (landscape ? 3 : 1.5)
        let wantX = feet.0 + P.ax * lead - FWD_X * dn
        let wantZ = feet.2 + P.az * lead - FWD_Z * dn
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
        let kick: Float = (title || P.downed) ? 0 : max(0, P.muzzle) * (P.cls == .gunner ? 0.045 : 0.07) * (reducedMotion ? 0.35 : 1)
        let kx = -P.ax * kick, kz = -P.az * kick
        shakeAcc += dt
        if shakeAcc >= 1 / 60 {
            shakeAcc = min(shakeAcc - 1 / 60, 1 / 60)
            shakeOff = ((rng.next() - 0.5), (rng.next() - 0.5), (rng.next() - 0.5))
        }
        focus = (tx + kx, ty, tz + kz)
        shakeOffset = (shakeOff.0 * sk, shakeOff.1 * sk, shakeOff.2 * sk)
    }
}
