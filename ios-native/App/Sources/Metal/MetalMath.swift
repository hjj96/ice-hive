import Foundation

// ================================================================
//  METAL MATH — a column-major 4x4 matrix with the memory layout of
//  Metal's float4x4 (four float4 columns), plus the camera helpers of
//  three.js the web game relies on (perspective, lookAt). Only stdlib
//  SIMD types: no simd module, so it also typechecks off Apple
//  platforms.
// ================================================================
typealias F3 = SIMD3<Float>
typealias F4 = SIMD4<Float>

struct Mat4 {
    var c0: F4, c1: F4, c2: F4, c3: F4

    static let identity = Mat4(c0: F4(1, 0, 0, 0), c1: F4(0, 1, 0, 0), c2: F4(0, 0, 1, 0), c3: F4(0, 0, 0, 1))

    @inline(__always) static func * (a: Mat4, b: Mat4) -> Mat4 {
        Mat4(c0: a.apply(b.c0), c1: a.apply(b.c1), c2: a.apply(b.c2), c3: a.apply(b.c3))
    }

    /// Matrix × column vector.
    @inline(__always) func apply(_ v: F4) -> F4 {
        c0 * v.x + c1 * v.y + c2 * v.z + c3 * v.w
    }

    /// Point (w = 1) transform without the projective divide.
    @inline(__always) func point(_ x: Float, _ y: Float, _ z: Float) -> F4 {
        c0 * x + c1 * y + c2 * z + c3
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> Mat4 {
        Mat4(c0: F4(1, 0, 0, 0), c1: F4(0, 1, 0, 0), c2: F4(0, 0, 1, 0), c3: F4(x, y, z, 1))
    }

    static func scale(_ s: Float) -> Mat4 {
        Mat4(c0: F4(s, 0, 0, 0), c1: F4(0, s, 0, 0), c2: F4(0, 0, s, 0), c3: F4(0, 0, 0, 1))
    }

    static func rotationX(_ a: Float) -> Mat4 {
        let c = cosf(a), s = sinf(a)
        return Mat4(c0: F4(1, 0, 0, 0), c1: F4(0, c, s, 0), c2: F4(0, -s, c, 0), c3: F4(0, 0, 0, 1))
    }

    static func rotationY(_ a: Float) -> Mat4 {
        let c = cosf(a), s = sinf(a)
        return Mat4(c0: F4(c, 0, -s, 0), c1: F4(0, 1, 0, 0), c2: F4(s, 0, c, 0), c3: F4(0, 0, 0, 1))
    }

    static func rotationZ(_ a: Float) -> Mat4 {
        let c = cosf(a), s = sinf(a)
        return Mat4(c0: F4(c, s, 0, 0), c1: F4(-s, c, 0, 0), c2: F4(0, 0, 1, 0), c3: F4(0, 0, 0, 1))
    }

    /// Right-handed perspective (camera looks down -z, like three.js) mapping depth to Metal's [0, 1].
    /// `fovY` in radians.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let f = 1 / tanf(fovY / 2)
        let r = far / (near - far)
        return Mat4(c0: F4(f / aspect, 0, 0, 0), c1: F4(0, f, 0, 0), c2: F4(0, 0, r, -1), c3: F4(0, 0, r * near, 0))
    }

    /// View matrix of a camera at `eye` looking at `target` (three.js Object3D.lookAt + matrixWorldInverse).
    static func lookAt(eye: F3, target: F3, up: F3 = F3(0, 1, 0)) -> Mat4 {
        var z = eye - target
        let zl = (z * z).sum().squareRoot()
        z = zl > 1e-6 ? z / zl : F3(0, 0, 1)
        var x = Mat4.cross(up, z)
        let xl = (x * x).sum().squareRoot()
        x = xl > 1e-6 ? x / xl : F3(1, 0, 0)
        let y = Mat4.cross(z, x)
        return Mat4(c0: F4(x.x, y.x, z.x, 0), c1: F4(x.y, y.y, z.y, 0), c2: F4(x.z, y.z, z.z, 0),
                    c3: F4(-Mat4.dot(x, eye), -Mat4.dot(y, eye), -Mat4.dot(z, eye), 1))
    }

    @inline(__always) static func cross(_ a: F3, _ b: F3) -> F3 {
        F3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    @inline(__always) static func dot(_ a: F3, _ b: F3) -> Float { (a * b).sum() }
}

@inline(__always) func clampf(_ v: Float, _ a: Float, _ b: Float) -> Float { v < a ? a : (v > b ? b : v) }
@inline(__always) func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func smooth01f(_ t0: Float) -> Float { let t = clampf(t0, 0, 1); return t * t * (3 - 2 * t) }

/// sRGB hex (0xRRGGBB) → linear RGB, like three.js Color.setHex with colour management on.
func linearRGB(_ hex: UInt32) -> F3 {
    func ch(_ v: UInt32) -> Float {
        let c = Float(v & 255) / 255
        return c < 0.04045 ? c * 0.0773993808 : powf(c * 0.9478672986 + 0.0521327014, 2.4)
    }
    return F3(ch(hex >> 16), ch(hex >> 8), ch(hex))
}

/// sRGB hex → display-space RGB 0…1 (no conversion; fog colour and the clear colour).
func displayRGB(_ hex: UInt32) -> F3 {
    F3(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255)
}
