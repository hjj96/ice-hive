import Foundation
import Metal
import UIKit

// ================================================================
//  BURST CAPTURE (CI look-dev, native-vx-squad): consecutive frames
//  out of the drawable, so the shooting effects can be checked frame
//  by frame. `simctl io screenshot` takes 5–30 s on the CI runners,
//  so it can only ever show one frame of a muzzle flash, a tracer or
//  a hit; this copies the presented image itself.
//
//  `-burst <name> <t0> <count> [every]`: from <t0> s after «scene
//  ready», the next <count> (≤ 96) presented frames (every <every>-th; 1 =
//  consecutive, the default) — the final image with the HUD, as the
//  phone shows it — are blitted from the drawable into a shared buffer
//  and written as Documents/burst/<name>-NN.jpg (quality 0.92, full
//  resolution, so 100 % crops work); CI copies them into the results.
//  One log line per frame: `burst <name> NN t=<s since ready>
//  dt=<ms since the previous captured frame>` (the simulator can skip
//  presents: dt says how far apart two images really are).
//  Off unless the flag is given; with it the layer is not
//  framebufferOnly (a blit source), so it changes nothing in play.
// ================================================================

final class BurstCapture {
    static let shared = BurstCapture()

    let on: Bool
    let name: String
    private let t0: Double
    private let count: Int
    private let every: Int
    private var taken = 0
    private var seen = 0
    private var lastT: Double = -1
    private var announced = false
    private let io = DispatchQueue(label: "icehive.burst", qos: .utility)
    private let dir: URL?

    private init() {
        let u = LaunchOptions.current.unknown
        if let i = u.firstIndex(of: "-burst"), i + 3 < u.count, let t = Double(u[i + 2]), let n = Int(u[i + 3]), n > 0 {
            on = true
            name = u[i + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            t0 = max(0, t)
            // (at most 96: B3's boss intro is 60 frames, every 4th present, for its clip; the others ask 10–24)
            count = min(96, n)
            every = i + 4 < u.count ? max(1, Int(u[i + 4]) ?? 1) : 1
        } else {
            on = false
            name = ""
            t0 = 0
            count = 0
            every = 1
        }
        if on, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let d = docs.appendingPathComponent("burst", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            // a previous run's frames of the same name go first
            if let old = try? FileManager.default.contentsOfDirectory(atPath: d.path) {
                for f in old where f.hasPrefix(name + "-") { try? FileManager.default.removeItem(at: d.appendingPathComponent(f)) }
            }
            dir = d
        } else {
            dir = nil
        }
    }

    /// FrameLoop.draw, after the composite + HUD encoder and before the present: copy this frame's drawable when it is
    /// one of the burst's. `sinceReady` < 0 while loading.
    func capture(_ cb: MTLCommandBuffer, _ tex: MTLTexture, device: MTLDevice, sinceReady: Double) {
        guard on, taken < count, sinceReady >= t0, let dir = dir else { return }
        if !announced {
            announced = true
            AppLog.info(String(format: "burst %@ start t=%.3f count=%d every=%d size=%dx%d", name, sinceReady, count, every,
                               tex.width, tex.height))
        }
        seen += 1
        if (seen - 1) % every != 0 { return }
        let w = tex.width, h = tex.height, bpr = w * 4
        guard tex.pixelFormat == .bgra8Unorm, let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.label = "burst capture"
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        let k = taken
        taken += 1
        let dt = lastT >= 0 ? (sinceReady - lastT) * 1000 : 0
        lastT = sinceReady
        AppLog.info(String(format: "burst %@ %02d t=%.3f dt=%.1fms", name, k, sinceReady, dt))
        let url = dir.appendingPathComponent(String(format: "%@-%02d.jpg", name, k))
        let q = io, last = taken == count, nm = name
        cb.addCompletedHandler { _ in
            q.async {
                BurstCapture.write(buf, width: w, height: h, to: url)
                if last { AppLog.info("burst \(nm) written (\(k + 1) frames)") }
            }
        }
    }

    /// BGRA8 (the drawable's bytes, already display-encoded) → JPEG.
    private static func write(_ buf: MTLBuffer, width w: Int, height h: Int, to url: URL) {
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: buf.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let img = ctx.makeImage(), let jpg = UIImage(cgImage: img).jpegData(compressionQuality: 0.92) else {
            AppLog.error("burst: could not encode \(url.lastPathComponent)")
            return
        }
        do { try jpg.write(to: url) } catch { AppLog.error("burst: could not write \(url.lastPathComponent): \(error)") }
    }
}
