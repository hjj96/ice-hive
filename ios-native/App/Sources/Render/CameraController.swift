import SpriteKit
import IceHiveCore

// ================================================================
//  CAMERA — follows the player like updateCamera() of 12-main.js:
//  look-at point 2.4 m ahead along the aim, pushed toward screen-down
//  on touch (1.5 m portrait / 3 m landscape) so the thumbs hide less,
//  damped follow, floor-height follow, shake and a tiny recoil kick.
//  Zoom matches the web field of view: 23 m across a portrait screen,
//  21.6 m top-to-bottom in landscape.
// ================================================================
final class CameraController {
    let node = SKCameraNode()
    private(set) var tx: Float = 0, ty: Float = 0, tz: Float = 0
    private(set) var scale: CGFloat = 1.35
    private(set) var viewSize = CGSize(width: 402, height: 874)
    private var initialized = false
    private var shake: Float = 0
    private var rng = SeededRNG(seed: 555)
    var reducedMotion = false
    /// Shake offset, re-rolled at the 60 Hz simulation rate (not every 120 Hz frame) so its jitter does not
    /// depend on the display rate.
    private var shakeOff: (Float, Float, Float) = (0, 0, 0)
    private var shakeAcc: Float = 0
    /// Look-at point of this frame (target + recoil kick) and the camera position jitter (shake): the Metal renderer
    /// builds the web's perspective camera from them.
    private(set) var focus: (Float, Float, Float) = (0, 0, 0)
    private(set) var shakeOffset: (Float, Float, Float) = (0, 0, 0)

    func addShake(_ a: Float) {
        shake = min(1.4, shake + a * (reducedMotion ? 0.35 : 1))
    }

    /// Snap to the player (new mission / teleport).
    func reset() { initialized = false }

    /// `feet` = interpolated player position; `title` = slow attract-mode camera.
    func update(game: Game, feet: (Float, Float, Float), dt: Float, viewSize: CGSize, title: Bool, liftRise: Float) {
        self.viewSize = viewSize
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
        let sx = shakeOff.0 * sk, sy = shakeOff.1 * sk, sz = shakeOff.2 * sk
        focus = (tx + kx, ty, tz + kz)
        shakeOffset = (sx, sy, sz)
        node.position = Iso.point(tx + kx + sx, ty + sy, tz + kz + sz)

        // field of view of the web camera
        let w = max(1, viewSize.width), h = max(1, viewSize.height)
        let screenPPM: CGFloat = landscape ? h / 21.6 : w / 23
        var s = Iso.ppm / screenPPM
        if title { s *= 1.12 }
        if extract {
            let u = max(0, min(1, game.extractT / 4.5))
            s *= CGFloat(1 + 0.35 * u * u * (3 - 2 * u))
        }
        scale = s
        node.setScale(s)
    }

    /// Visible part of the world (world points).
    var visibleRect: CGRect {
        let w = viewSize.width * scale, h = viewSize.height * scale
        return CGRect(x: node.position.x - w / 2, y: node.position.y - h / 2, width: w, height: h)
    }

    /// Screen points per metre.
    var screenPPM: CGFloat { Iso.ppm / scale }

    /// World points → screen points with the origin at the bottom-left of the view.
    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - node.position.x) / scale + viewSize.width / 2, y: (p.y - node.position.y) / scale + viewSize.height / 2)
    }

    /// World points → camera-local points (HUD space, origin at the view centre).
    func toHUD(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - node.position.x) / scale, y: (p.y - node.position.y) / scale)
    }

    /// Ground quad under the screen corners (aim assist only picks visible bugs).
    func setVisibleArea(of game: Game) {
        let r = visibleRect
        game.setVisibleQuad(Iso.ground(from: CGPoint(x: r.minX, y: r.minY), height: ty), Iso.ground(from: CGPoint(x: r.maxX, y: r.minY), height: ty),
                            Iso.ground(from: CGPoint(x: r.maxX, y: r.maxY), height: ty), Iso.ground(from: CGPoint(x: r.minX, y: r.maxY), height: ty))
    }
}
