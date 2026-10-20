import SpriteKit
import IceHiveCore

// ================================================================
//  CAMERA — follows the player like updateCamera() of 12-main.js:
//  look-at point 2.4 m ahead along the aim, pushed toward screen-down
//  on touch (1.5 m portrait / 3 m landscape) so the thumbs hide less,
//  damped follow, floor-height follow, shake and a tiny recoil kick.
//  MetalCamera builds the web's perspective camera from `focus` and
//  `shakeOffset`. v1.1 VX-6 (portrait): the look-at point 3.2 m toward
//  screen-down and the lead split into screen axes (3.4 m sideways, 1.4 m
//  along the screen's depth): the portrait view is ~23 m wide but ~50 m
//  deep, so the narrow axis is the one worth leading into; `zoom` (1.10
//  in a packed screen, hysteresis 240 / 180 bugs) waits for MetalCamera to
//  apply it (handoff M2: `dist *= zoom`). `node` is the SpriteKit camera the HUD, menus and
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
    /// VX-6 crowd pull-back: camera distance factor, 1 … 1.10 (smoothed; not applied by the renderer yet — M2).
    private(set) var zoom: Float = 1
    private var zoomWant: Float = 1

    func addShake(_ a: Float) {
        shake = min(1.4, shake + a * (reducedMotion ? 0.35 : 1))
    }

    /// Snap to the player (new mission / teleport).
    func reset() { initialized = false }

    /// `feet` = interpolated player position; `title` = slow attract-mode camera.
    /// `bugsNear` = live bugs within 22 m of the camera target (web nearCam).
    func update(game: Game, feet: (Float, Float, Float), dt: Float, viewSize: CGSize, title: Bool, liftRise: Float, bugsNear: Int = 0) {
        let P = game.player
        let portrait = !title && viewSize.height > viewSize.width
        let lead: Float = title ? 0 : 2.4
        let dn: Float = title ? 0 : (portrait ? 3.2 : 3)
        // lead along the screen's axes (portrait: mostly sideways), then the push toward screen-down
        let sr = P.ax * RIGHT_X + P.az * RIGHT_Z, su = P.ax * FWD_X + P.az * FWD_Z
        let lr: Float = portrait ? 3.4 : lead, lu: Float = portrait ? 1.4 : lead
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
