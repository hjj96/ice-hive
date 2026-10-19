import Foundation
import Metal
import QuartzCore

// ================================================================
//  GPU COUNTERS — where the GPU time of a frame goes (WP1 «Кадр»).
//  On a device that samples counters at stage boundaries (Apple GPUs,
//  iOS 14+), every pass the renderer opens carries a timestamp sample
//  at its start (vertex) and end (fragment) in a per-frame
//  MTLCounterSampleBuffer (a ring of three, like the arena); the
//  samples are resolved when the command buffer completes and turned
//  into milliseconds per pass (GPU ticks calibrated against the host
//  clock with sampleTimestamps). The simulator has no counter sampling:
//  there only the command-buffer total (gpuStartTime → gpuEndTime) is
//  reported. The final pass (composite + HUD) is opened by FrameLoop;
//  until it carries a sample buffer too (attach(to:pass:), handoff to
//  the frame-loop owner) it is reported as the remainder
//  `final≈` = frame − the measured passes.
//  MetalWorld logs one `hb gpu` line per second (diagnostics):
//    hb gpu frame=… ema=… max=… shadow=… world=… bloom=… final≈… (ms)
// ================================================================
final class GPUCounters {
    /// Passes with their own slot pair in the sample buffer.
    enum Pass: Int, CaseIterable { case shadow = 0, world, bloom, final }
    static let passNames = ["shadow", "world", "bloom", "final"]

    let device: MTLDevice
    /// Per-pass stage-boundary sampling works on this device.
    let perPass: Bool
    private var buffers: [MTLCounterSampleBuffer?] = []
    private var slot = 0
    /// Passes that sample in a slot's frame (bit per Pass), read when that frame's command buffer completes (all
    /// encoding — the final pass too — is done by then; the slot is reused only after that).
    private final class Record { var mask = 0 }
    private var records: [Record] = (0..<MetalRenderer.arenaSlots).map { _ in Record() }
    /// The frame being encoded has world passes (FrameLoop's final pass may sample into the same slot).
    private(set) var frameOpen = false
    // calibration: seconds per GPU timestamp tick
    private var calCPU: Double = 0
    private var calGPU: MTLTimestamp = 0
    private var secondsPerTick: Double = 1e-9
    // results, written from completion threads
    private let lock = NSLock()
    private var sums = [Double](repeating: 0, count: Pass.allCases.count)
    private var frameSum: Double = 0
    private var frameMax: Double = 0
    private var frames = 0
    private var passFrames = 0

    init(device: MTLDevice) {
        self.device = device
        var ok = false
        if device.supportsCounterSampling(.atStageBoundary),
           let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) {
            for k in 0..<MetalRenderer.arenaSlots {
                let d = MTLCounterSampleBufferDescriptor()
                d.counterSet = set
                d.label = "pass timestamps \(k)"
                d.storageMode = .shared
                d.sampleCount = 2 * Pass.allCases.count
                buffers.append(try? device.makeCounterSampleBuffer(descriptor: d))
            }
            ok = buffers.allSatisfy { $0 != nil }
        }
        perPass = ok
        if ok { calibrate() }
    }

    /// Re-measure the GPU tick length against the host clock (call rarely: once per heartbeat).
    func calibrate() {
        guard perPass else { return }
        var cpu: MTLTimestamp = 0, gpu: MTLTimestamp = 0
        device.sampleTimestamps(&cpu, gpuTimestamp: &gpu)
        let now = CACurrentMediaTime()
        if calCPU > 0 && gpu > calGPU && now - calCPU > 0.2 {
            secondsPerTick = (now - calCPU) / Double(gpu - calGPU)
        }
        calCPU = now
        calGPU = gpu
    }

    /// Start of a frame's encoding (the arena slot it uses).
    func beginFrame(slot s: Int) {
        slot = s % records.count
        records[slot].mask = 0
        frameOpen = true
    }

    /// The frame's command buffer was committed (no more passes for this slot).
    func endFrame() { frameOpen = false }

    /// Sample the start / end of `pass` on this render pass descriptor (`first` / `last`: a pass made of several
    /// encoders samples its start on the first and its end on the last one). No-op without per-pass sampling.
    func attach(to desc: MTLRenderPassDescriptor, pass: Pass, first: Bool = true, last: Bool = true) {
        let a = desc.sampleBufferAttachments[0]!
        guard perPass, slot < buffers.count, let b = buffers[slot] else { a.sampleBuffer = nil; return }
        a.sampleBuffer = b
        a.startOfVertexSampleIndex = first ? 2 * pass.rawValue : MTLCounterDontSample
        a.endOfVertexSampleIndex = MTLCounterDontSample
        a.startOfFragmentSampleIndex = MTLCounterDontSample
        a.endOfFragmentSampleIndex = last ? 2 * pass.rawValue + 1 : MTLCounterDontSample
        if last { records[slot].mask |= 1 << pass.rawValue }
    }

    /// Detach from a descriptor reused for another pass (a pass without sampling must not write old indices).
    func detach(_ desc: MTLRenderPassDescriptor) {
        desc.sampleBufferAttachments[0]!.sampleBuffer = nil
    }

    /// The frame's command buffer: resolve the samples and add the totals when it completes.
    func track(_ cb: MTLCommandBuffer, quality: RenderQuality) {
        let s = slot, rec = records[slot]
        let buf: MTLCounterSampleBuffer? = perPass && s < buffers.count ? buffers[s] : nil
        let spt = secondsPerTick
        cb.addCompletedHandler { [weak self] c in
            let frameMs = (c.gpuEndTime - c.gpuStartTime) * 1000
            quality.reportGPU(ms: frameMs)
            var per = [Double](repeating: -1, count: Pass.allCases.count)
            let mask = rec.mask
            if let b = buf, mask != 0, let data = b.resolveCounterRange(0..<(2 * Pass.allCases.count)) {
                data.withUnsafeBytes { raw in
                    let ts = raw.bindMemory(to: MTLCounterResultTimestamp.self)
                    for p in Pass.allCases where mask & (1 << p.rawValue) != 0 && 2 * p.rawValue + 1 < ts.count {
                        let a = ts[2 * p.rawValue].timestamp, e = ts[2 * p.rawValue + 1].timestamp
                        // (an error sample reads all ones: the span check drops it)
                        let ms = e > a ? Double(e - a) * spt * 1000 : -1
                        if ms >= 0 && ms < 1000 { per[p.rawValue] = ms }
                    }
                }
            }
            self?.add(frameMs: frameMs, per: per)
        }
    }

    private func add(frameMs: Double, per: [Double]) {
        guard frameMs > 0 && frameMs < 1000 else { return }
        lock.lock()
        frames += 1
        frameSum += frameMs
        frameMax = max(frameMax, frameMs)
        if per.contains(where: { $0 >= 0 }) {
            passFrames += 1
            for k in 0..<per.count where per[k] >= 0 { sums[k] += per[k] }
        }
        lock.unlock()
    }

    /// Averages since the last call (ms): "frame=0.42 max=0.9 shadow=… world=… bloom=… final≈…", then reset.
    func takeSummary() -> String {
        lock.lock()
        let n = frames, pn = passFrames
        let avg = n > 0 ? frameSum / Double(n) : 0, mx = frameMax
        var parts: [String] = []
        if pn > 0 {
            var measured = 0.0
            for p in Pass.allCases {
                let v = sums[p.rawValue] / Double(pn)
                if p == .final && sums[p.rawValue] == 0 { continue }
                measured += v
                parts.append(GPUCounters.passNames[p.rawValue] + String(format: "=%.2f", v))
            }
            if sums[Pass.final.rawValue] == 0 { parts.append(String(format: "final≈%.2f", max(0, avg - measured))) }
        } else {
            parts.append("passes=- (no counter sampling: command-buffer totals only)")
        }
        frames = 0; passFrames = 0; frameSum = 0; frameMax = 0
        for k in 0..<sums.count { sums[k] = 0 }
        lock.unlock()
        return String(format: "frame=%.2f max=%.2f ", avg, mx) + parts.joined(separator: " ")
    }
}
