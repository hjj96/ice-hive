import Foundation
import IceHiveCore

// ================================================================
//  METAL CAMERA — the web game's perspective camera (03-render.js
//  resize, 12-main.js updateCamera): fov 40° landscape / 50° portrait,
//  pitch 57°, yaw 45°, distance fitted so ~11 m of world stay visible
//  on the short axis; the follow target, lead, floor-height follow,
//  shake and recoil kick come from CameraController (shared with the
//  SpriteKit renderer), the title sway and the extraction pull-back
//  are applied here. Also projects world points into HUD space.
// ================================================================
final class MetalCamera {
    static let pitch: Float = 57 * Float.pi / 180
    static let yaw: Float = Float.pi / 4

    /// View size in points (HUD space) and the drawable height in pixels.
    private(set) var viewW: Float = 402, viewH: Float = 874
    private(set) var drawableH: Float = 1748
    private(set) var fov: Float = 50
    private(set) var camDist: Float = 28
    private(set) var aspect: Float = 0.46
    private(set) var near: Float = 1
    private(set) var far: Float = 168
    private(set) var view = Mat4.identity
    private(set) var proj = Mat4.identity
    private(set) var viewProj = Mat4.identity
    private(set) var eye = F3(0, 20, 20)
    private(set) var focus = F3(0, 0, 0)
    private(set) var right = F3(1, 0, 0)
    private(set) var up = F3(0, 1, 0)
    private(set) var forward = F3(0, 0, -1)

    /// exp2 fog density of the web scene (0.42 / camDist).
    var fogDensity: Float { 0.42 / camDist }
    /// Drawable pixels per metre at unit view depth (web pxScale): point sprite sizes.
    var pxScale: Float { drawableH / (2 * tanf(fov * Float.pi / 360)) }

    func resize(width: Float, height: Float, drawableHeight: Float) {
        viewW = max(1, width)
        viewH = max(1, height)
        drawableH = max(1, drawableHeight)
        aspect = viewW / viewH
        fov = aspect < 1 ? 50 : 40
        let vis: Float = aspect < 1 ? 11.5 : 10.8
        camDist = vis / (tanf(fov * Float.pi / 360) * min(1, aspect))
        far = camDist + 140
    }

    /// `focus` = look-at point (target + recoil kick), `shake` = camera position jitter.
    func update(focus f: F3, shake: F3, title: Bool, time: Float, extract: Float) {
        focus = f
        let ex = extract
        let yaw = MetalCamera.yaw + (title ? sinf(time * 0.06) * 0.35 : 0)
        let pitch = MetalCamera.pitch - (title ? 0.08 : 0) + 0.12 * ex
        let dist = camDist * (title ? 1.12 : 1) * (1 + 0.35 * ex)
        eye = f + F3(sinf(yaw) * cosf(pitch) * dist, sinf(pitch) * dist, cosf(yaw) * cosf(pitch) * dist) + shake
        view = Mat4.lookAt(eye: eye, target: f)
        proj = Mat4.perspective(fovY: fov * Float.pi / 180, aspect: aspect, near: near, far: far)
        viewProj = proj * view
        right = F3(view.c0.x, view.c1.x, view.c2.x)
        up = F3(view.c0.y, view.c1.y, view.c2.y)
        forward = -F3(view.c0.z, view.c1.z, view.c2.z)
    }

    /// World point → HUD point (camera-local SpriteKit space: origin at the view centre, y up, points).
    @inline(__always) func hudPoint(_ x: Float, _ y: Float, _ z: Float) -> CGPoint {
        let c = viewProj.point(x, y, z)
        let w = c.w > 1e-4 ? c.w : 1e-4
        return CGPoint(x: CGFloat(c.x / w * viewW * 0.5), y: CGFloat(c.y / w * viewH * 0.5))
    }

    /// Clip-space visibility of a point with a margin (web writeBugInstances: 15 %).
    @inline(__always) func visible(_ x: Float, _ y: Float, _ z: Float, margin: Float = 1.15) -> Bool {
        let c = viewProj.point(x, y, z)
        if c.w <= 0 { return false }
        let m = margin * c.w
        return c.x <= m && c.x >= -m && c.y <= m && c.y >= -m
    }

    /// Where the ray through a view corner (ndc ±1) meets the plane y = h.
    func ground(ndcX: Float, ndcY: Float, height h: Float) -> Vec2 {
        let t = tanf(fov * Float.pi / 360)
        let d = forward + right * (ndcX * t * aspect) + up * (ndcY * t)
        let dy = min(-1e-3, d.y)
        let k = (h - eye.y) / dy
        return Vec2(eye.x + d.x * k, eye.z + d.z * k)
    }
}
