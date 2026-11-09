import Foundation
import CoreGraphics
import Metal
import ImageIO

// ================================================================
//  FILM CAPTURE (test branches native-vx-video / native-vx-film; never merged): a gameplay video out of
//  the CI simulator that is smooth whatever the runner's speed.
//
//  `-videoStep N`: every drawn frame advances exactly 1/N s (VideoClock).
//  The frame loop waits for a frame slot and a drawable instead of
//  skipping the tick, the scene runs on VideoClock (SKRenderer.update),
//  and FrameTimer.now() reads it too, so the wall-time animations (HUD
//  pulses, the occupancy fade, the exposure dip) move by the same step.
//
//  `-film <name> <t0> <count> [every]`: from <t0> s after «scene ready»
//  (VideoClock seconds), every <every>-th presented frame — the final
//  image with the HUD, as the phone shows it — is blitted out of the
//  drawable and written as Documents/film/<name>-NNNNN.jpg at full
//  resolution, <count> frames in all (CI assembles them into an .mp4).
//  A small pool of readback buffers: when the JPEG encoder is behind,
//  the loop waits (the clock stands still meanwhile). Log lines:
//  `film <name> start …`, `film <name> NNNNN t=…` every 100 frames,
//  `film <name> written (N frames, F failed)`.
//  Off unless the flags are given.
// ================================================================

enum VideoClock {
    /// Seconds per drawn frame (`-videoStep N` → 1/N), nil = real time.
    static let step: Double? = {
        let u = LaunchOptions.current.unknown
        guard let i = u.firstIndex(of: "-videoStep"), i + 1 < u.count, let n = Double(u[i + 1]), n >= 10, n <= 240 else { return nil }
        return 1 / n
    }()
    static let on = step != nil
    /// Uptime at the clock's first use; the clock runs from there.
    private static let base = ProcessInfo.processInfo.systemUptime
    /// Frames drawn on the clock (main thread).
    private(set) static var frames = 0
    /// The clock (seconds, uptime-like).
    static var now: Double { base + Double(frames) * (step ?? 0) }
    /// One frame of time (FrameLoop, once per drawn frame, before the scene update).
    static func advance() { if on { frames += 1 } }
}

/// `-filmZoom f` (film branch only): the game camera's distance × f (0.3 … 1) — the swarm reel's closer look at a pack at
/// the game's own pitch, yaw and lighting. Not on the title.
enum FilmZoom {
    static let factor: Float = {
        let u = LaunchOptions.current.unknown
        guard let i = u.firstIndex(of: "-filmZoom"), i + 1 < u.count, let f = Float(u[i + 1]) else { return 1 }
        return max(0.3, min(1, f))
    }()
}

final class FilmCapture {
    static let shared = FilmCapture()
    static let poolSize = 6

    let on: Bool
    let name: String
    private let t0: Double
    private let count: Int
    private let every: Int
    private var taken = 0
    private var seen = 0
    private var announced = false
    private let dir: URL?
    // readback buffers (free list under the lock; the semaphore counts the free ones)
    private let lock = NSLock()
    private var pool: [MTLBuffer] = []
    private let slots = DispatchSemaphore(value: FilmCapture.poolSize)
    private var written = 0
    private var failed = 0
    private let io = DispatchQueue(label: "icehive.film", qos: .userInitiated, attributes: .concurrent)

    private init() {
        let u = LaunchOptions.current.unknown
        if let i = u.firstIndex(of: "-film"), i + 3 < u.count, let t = Double(u[i + 2]), let n = Int(u[i + 3]), n > 0 {
            on = true
            name = u[i + 1].filter { $0.isLetter || $0.isNumber || $0 == "-" }
            t0 = max(0, t)
            count = min(20_000, n)
            every = i + 4 < u.count ? max(1, Int(u[i + 4]) ?? 1) : 1
        } else {
            on = false
            name = ""
            t0 = 0
            count = 0
            every = 1
        }
        if on, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let d = docs.appendingPathComponent("film", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            if let old = try? FileManager.default.contentsOfDirectory(atPath: d.path) {
                for f in old where f.hasPrefix(name + "-") { try? FileManager.default.removeItem(at: d.appendingPathComponent(f)) }
            }
            dir = d
        } else {
            dir = nil
        }
    }

    /// FrameLoop.draw, after the composite + HUD encoder and before the present: copy this frame's drawable when it is
    /// one of the film's. `sinceReady` < 0 while loading.
    func capture(_ cb: MTLCommandBuffer, _ tex: MTLTexture, device: MTLDevice, sinceReady: Double) {
        guard on, taken < count, sinceReady >= t0, let dir = dir else { return }
        let w = tex.width, h = tex.height, bpr = w * 4
        if !announced {
            announced = true
            AppLog.info(String(format: "film %@ start t=%.3f count=%d every=%d size=%dx%d step=%.4f", name, sinceReady, count, every,
                               w, h, VideoClock.step ?? 0))
            if tex.pixelFormat != .bgra8Unorm { AppLog.error("film: drawable format \(tex.pixelFormat.rawValue), not bgra8Unorm") }
        }
        seen += 1
        if (seen - 1) % every != 0 { return }
        guard tex.pixelFormat == .bgra8Unorm else { return }
        // a free readback buffer: wait while the encoder is behind (every frame of the film is kept)
        slots.wait()
        lock.lock()
        var buf = pool.popLast()
        lock.unlock()
        if let b = buf, b.length < bpr * h { buf = nil }
        if buf == nil { buf = device.makeBuffer(length: bpr * h, options: .storageModeShared) }
        guard let b = buf, let blit = cb.makeBlitCommandEncoder() else {
            if let b = buf { lock.lock(); pool.append(b); lock.unlock() }
            slots.signal()
            AppLog.error("film: no readback buffer / blit encoder")
            return
        }
        blit.label = "film capture"
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: b, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        let k = taken
        taken += 1
        if k % 100 == 0 { AppLog.info(String(format: "film %@ %05d t=%.3f", name, k, sinceReady)) }
        let url = dir.appendingPathComponent(String(format: "%@-%05d.jpg", name, k))
        cb.addCompletedHandler { [weak self] _ in
            guard let s = self else { return }
            s.io.async {
                let ok = FilmCapture.write(b, width: w, height: h, to: url)
                s.finished(b, ok: ok, file: url.lastPathComponent)
            }
        }
    }

    /// A frame's JPEG is on disk (or failed): its buffer goes back to the pool; the last one logs the total.
    private func finished(_ b: MTLBuffer, ok: Bool, file: String) {
        lock.lock()
        pool.append(b)
        if ok { written += 1 } else { failed += 1 }
        let done = written + failed, w = written, f = failed
        lock.unlock()
        slots.signal()
        if !ok { AppLog.error("film: could not write \(file)") }
        if done == count { AppLog.info("film \(name) written (\(w) frames, \(f) failed)") }
    }

    /// BGRA8 (the drawable's bytes, already display-encoded) → JPEG (quality 0.92).
    private static func write(_ buf: MTLBuffer, width w: Int, height h: Int, to url: URL) -> Bool {
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: buf.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
              let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(dst)
    }
}
