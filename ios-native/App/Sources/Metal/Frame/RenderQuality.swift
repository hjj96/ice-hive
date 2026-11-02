import Foundation
import Metal
import UIKit

// ================================================================
//  RENDER QUALITY — visual tiers, the thermal ladder, dynamic
//  resolution, the 120 Hz policy and the device-class bug cap (WP1
//  «Кадр»). All GPU numbers are first-principles estimates for an
//  iPhone 12 (A14) with 1400 bugs, ±50 %; the simulator's GPU time
//  says nothing about a device (CI uses it as a tripwire only).
//
//  Tiers (the «Графика» setting → GameScene.applyQuality → fxK):
//    «высокая» (fxK 1.0)  HIGH       DRS 1.5–2.0 px/pt, bloom ½ res × 5,
//                                    heat distortion; GPU ≤ 10.5 ms
//                                    typical / 11.5 peak
//    «средняя» (0.7)      EFFICIENT  DRS 1.2–1.6 px/pt, bloom ¼ res × 4;
//                                    GPU ≤ 6.5 / 7.0 ms
//    «низкая» (0.4)       EFFICIENT  + floor 1.2 px/pt
//  Both: RG11B10Float, MSAA 4× memoryless, resolve, LUT grade.
//  Thermal ladder (down at once, back up after 30 s in a better state)
//  — the one owner of the thermal steps: the effect scale (`fxCap`,
//  MetalWorld) and the display rate (`frameRate`, GameScene asks every
//  0.25 s) follow it, nothing else reads the thermal state:
//    nominal   chosen tier, 120 Hz allowed (ProMotion)
//    fair      60 Hz for the rest of the mission, DRS floor + 0.1
//    serious   Efficient + DRS, effects at most «средняя» (fxK 0.7,
//              no flashlight shadow)
//    critical  Efficient at 1.2 px/pt, effects and weather at their
//              minimum (fxK 0.4); 30 Hz only as the last step — after
//              10 s at critical with DRS at its 1.2 px/pt floor
//  Dynamic resolution: the world target is allocated once at the
//  requested scale (RenderTargets); a controller on the measured GPU
//  time (EMA) moves the viewport scale inside the tier's range toward
//  11.5 ms (High, 60 Hz) / 6.8 ms (120 Hz) / 7.0 ms (Efficient).
//  `-mscale N` (CI) pins the scale. `-drsSweep` (and the CI `probe`
//  demo) steps the scale between the range ends 10 times, 2 s apart,
//  to prove the steps cost no hitch.
//  120 Hz: ProMotion only; allowed while High, thermal nominal, Low
//  Power off and the GPU EMA ≤ 6.5 ms for 2 s; left (not re-entered in
//  the mission) once DRS sat at its floor for 3 s.
//  Bug cap by device class (separate from the visual tier): A13 and
//  older 900, A14 1400, A15 / A16 1800, A17 Pro and later 2500;
//  GameScene.newGame caps the tier's cap (700 / 1400 / 2500) by it.
//  The simulator (CI) stands in for the reference device of every
//  budget here, the iPhone 12: cap 1400.
//  «Графика: авто» stays «средняя» (Efficient) on every device until
//  the iPhone 12 capture confirms the High budget; deviceDefaultTier
//  (High from A14) is the plan's target, logged only.
// ================================================================
enum RenderTier: String {
    case high, efficient
}

final class RenderQuality {
    enum Thermal: Int { case nominal = 0, fair, serious, critical }

    /// GPU generation (Metal GPU family). The simulator reports no Apple GPU family: it counts as A13-or-older there
    /// (`isSimulator` says so in the log).
    enum DeviceClass: Int { case a13OrOlder = 0, a14, a15, a17Plus }
    #if targetEnvironment(simulator)
    static let isSimulator = true
    #else
    static let isSimulator = false
    #endif

    let deviceClass: DeviceClass
    /// Live-bug cap of this device class (to replace the tier caps of Tuning.QualityTier: core owner).
    let deviceBugCap: Int
    /// The tier «Графика: авто» should mean on this device (A14 and later: High).
    let deviceDefaultTier: RenderTier

    /// Tier of the setting (fxK from GameScene).
    private(set) var chosen: RenderTier = .efficient
    /// «Низкая»: Efficient with the 1.2 px/pt floor.
    private(set) var low = false
    /// The thermal step in effect (with hysteresis).
    private(set) var ladder: Thermal = .nominal
    private var betterSince: Double = 0
    /// fair (or DRS at the floor at 120 Hz) seen this mission: no 120 Hz until the next one.
    private(set) var no120ThisMission = false
    /// The tier in effect.
    var tier: RenderTier { ladder.rawValue >= Thermal.serious.rawValue ? .efficient : chosen }

    /// `-mscale N`: the world scale is pinned (CI stress runs, store shots).
    let forcedScale: Float?
    /// Current DRS scale (px/pt) before the request clamp (starts above every range: the first frame is at the top).
    private(set) var drs: Float = 99
    /// Scale of the frame being built (px/pt).
    private(set) var scale: Float = 2.0
    private var lastControl: Double = 0
    private var atFloorSince: Double = 0
    // GPU time, written from command-buffer completion threads
    private let lock = NSLock()
    private var gpuSamples = 0
    private var gpuEmaLocked: Double = 0
    private var lowGpuSince: Double = 0
    /// Smoothed GPU time per frame (ms, command buffer start → end).
    var gpuEma: Double { lock.lock(); defer { lock.unlock() }; return gpuEmaLocked }

    // DRS sweep test
    private let sweep: Bool
    private var sweepStart: Double = 0
    private var sweepStep = 0
    /// Lines for the log (sweep steps, ladder changes), taken by MetalWorld.
    private(set) var events: [String] = []

    init(device: MTLDevice) {
        if device.supportsFamily(.apple9) { deviceClass = .a17Plus } else if device.supportsFamily(.apple8) { deviceClass = .a15 } else if device.supportsFamily(.apple7) { deviceClass = .a14 } else { deviceClass = .a13OrOlder }
        var cap: Int
        switch deviceClass {
        case .a13OrOlder: cap = 900
        case .a14: cap = 1400
        case .a15: cap = 1800
        case .a17Plus: cap = 2500
        }
        // the simulator reports no Apple GPU family: it stands in for the reference device (iPhone 12, A14) of the budgets
        if RenderQuality.isSimulator { cap = 1400 }
        deviceBugCap = cap
        deviceDefaultTier = deviceClass == .a13OrOlder ? .efficient : .high
        let o = LaunchOptions.current
        forcedScale = o.metalScale.map { Float($0) }
        sweep = o.unknown.contains("-drsSweep") || o.demo == "probe"
    }

    /// The «Графика» tier from GameScene's effect scale (1.0 high, 0.7 med, 0.4 low).
    func setChosen(fxK: Float) {
        chosen = fxK >= 0.85 ? .high : .efficient
        low = fxK < 0.5
    }

    /// A new mission: the per-mission 120 Hz lock-out ends (not while the device is still at fair or worse).
    func resetMission() { no120ThisMission = ladder.rawValue >= Thermal.fair.rawValue }

    /// Effect scale the thermal step allows (MetalWorld caps the «Графика» fxK by it): serious → «средняя» (0.7, no
    /// flashlight shadow), critical → the minimum (0.4: effects and weather at «низкая»'s counts).
    var fxCap: Float { ladder == .critical ? 0.4 : (ladder == .serious ? 0.7 : 1.0) }

    /// Display rate the ladder allows outside the menus (GameScene.applyFrameRate, every 0.25 s and on mode changes).
    private var at120 = false
    private var at30 = false
    private var criticalSince: Double = 0
    private var lastRateReason = ""

    /// 120 on ProMotion with «высокая» (`highSetting`) once the GPU has been light (EMA ≤ 6.5 ms) for 2 s, held until
    /// thermal fair, Low Power, or DRS at its floor at 120 Hz (no re-entry this mission); 30 only after 10 s at critical
    /// with DRS at its 1.2 px/pt floor (the last step); else 60. Each change is logged with its reason (`quality:` lines).
    func frameRate(now: Double, highSetting: Bool) -> Int {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let can120 = UIScreen.main.maximumFramesPerSecond >= 120 && highSetting && tier == .high && ladder == .nominal
            && !lowPower && !no120ThisMission
        if !can120 {
            if at120 {
                at120 = false
                let why = ladder != .nominal ? "thermal \(ladder)" : (lowPower ? "Low Power" : (no120ThisMission ? "DRS at its floor" : "tier"))
                events.append("frame rate 120 -> 60 Hz (\(why))")
            }
        } else if !at120 && lowGpuSince > 0 && now - lowGpuSince >= 2 {
            at120 = true
            events.append(String(format: "frame rate 60 -> 120 Hz (GPU ema %.2f ms <= 6.5 for 2 s)", gpuEma))
        }
        if ladder == .critical {
            if criticalSince == 0 { criticalSince = now }
        } else {
            criticalSince = 0
        }
        let want30 = criticalSince > 0 && now - criticalSince >= 10 && scale <= range.lo + 1e-3
        if want30 != at30 {
            at30 = want30
            events.append(want30 ? "frame rate -> 30 Hz (critical for 10 s at 1.2 px/pt: the last step)"
                                 : "frame rate 30 Hz -> back up (thermal \(ladder))")
        }
        return at30 ? 30 : (at120 ? 120 : 60)
    }

    /// px/pt range of the tier in effect, after the thermal step.
    var range: (lo: Float, hi: Float) {
        if ladder == .critical { return (1.2, 1.2) }
        var r: (lo: Float, hi: Float) = tier == .high ? (1.5, 2.0) : (1.2, 1.6)
        if ladder == .fair { r.lo = min(r.hi, r.lo + 0.1) }
        return r
    }

    /// GPU time of a completed frame (any thread).
    func reportGPU(ms: Double) {
        guard ms > 0 && ms < 1000 else { return }
        lock.lock()
        gpuSamples += 1
        // the first second of frames (pipelines and textures warming up behind the loading cover) does not steer DRS
        if gpuSamples > 60 { gpuEmaLocked += (ms - gpuEmaLocked) * (gpuSamples < 70 ? 0.5 : 0.1) }
        lock.unlock()
    }

    /// GPU target for the controller (ms).
    private func targetMs(hz: Int) -> Double { tier == .high ? (hz > 60 ? 6.8 : 11.5) : 7.0 }

    /// Main thread, once per tick: thermal ladder, DRS controller, the sweep. `requested`: px/pt FrameLoop asked for
    /// (GameScene's world scale). Returns the scale of this frame.
    func update(now: Double, requested: Float, hz: Int) -> Float {
        stepLadder(now: now)
        let r = range
        let hi = forcedScale ?? min(r.hi, requested)
        let lo = forcedScale ?? min(r.lo, hi)
        if sweep && forcedScale == nil {
            if sweepStart == 0 { sweepStart = now + 3 }
            let k = Int((now - sweepStart) / 2)
            if now >= sweepStart && k >= sweepStep && sweepStep < 10 {
                sweepStep += 1
                let from = drs
                drs = sweepStep % 2 == 1 ? lo : hi
                events.append(String(format: "drs sweep step %d/10: %.2f -> %.2f px/pt", sweepStep, from, drs))
                scale = drs
                return scale
            }
            if sweepStep > 0 && sweepStep < 10 { scale = min(max(drs, lo), hi); return scale }
        }
        if forcedScale != nil {
            drs = hi
        } else if now - lastControl >= 0.25 {
            lastControl = now
            let ema = gpuEma, target = targetMs(hz: hz)
            if ema > target {
                drs *= Float(max(0.92, (target / ema).squareRoot()))
            } else if ema > 0 && ema < 0.8 * target {
                drs *= Float(min(1.04, (0.9 * target / ema).squareRoot()))
            }
            drs = (drs * 20).rounded() / 20
        }
        drs = min(max(drs, lo), hi)
        scale = drs
        // 120 Hz bookkeeping: GPU light enough for 2 s, DRS at its floor for 3 s
        if gpuEma <= 6.5 { if lowGpuSince == 0 { lowGpuSince = now } } else { lowGpuSince = 0 }
        if scale <= lo + 1e-3 && lo < hi { if atFloorSince == 0 { atFloorSince = now } } else { atFloorSince = 0 }
        if hz > 60 && atFloorSince > 0 && now - atFloorSince >= 3 && !no120ThisMission {
            no120ThisMission = true
            events.append("120 Hz off for this mission (DRS at its floor for 3 s)")
        }
        return scale
    }

    /// The policy's 120 Hz state (for the `hb gpu` line): on now, or the entry test (ProMotion, High, nominal, Low Power
    /// off, GPU EMA ≤ 6.5 ms for 2 s, not locked out) passes.
    func allows120Hz(now: Double) -> Bool {
        at120 || (UIScreen.main.maximumFramesPerSecond >= 120 && tier == .high && ladder == .nominal
            && !ProcessInfo.processInfo.isLowPowerModeEnabled && !no120ThisMission && lowGpuSince > 0 && now - lowGpuSince >= 2)
    }

    private func stepLadder(now: Double) {
        let s: Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s = .nominal
        case .fair: s = .fair
        case .serious: s = .serious
        case .critical: s = .critical
        @unknown default: s = .serious
        }
        if s.rawValue > ladder.rawValue {
            events.append("thermal ladder \(ladder) -> \(s)")
            ladder = s
            betterSince = 0
        } else if s.rawValue < ladder.rawValue {
            if betterSince == 0 { betterSince = now }
            if now - betterSince >= 30 {
                events.append("thermal ladder \(ladder) -> \(s) (30 s better)")
                ladder = s
                betterSince = 0
            }
        } else {
            betterSince = 0
        }
        if ladder.rawValue >= Thermal.fair.rawValue && !no120ThisMission { no120ThisMission = true }
    }

    /// Log lines since the last call.
    func takeEvents() -> [String] {
        let e = events
        events.removeAll()
        return e
    }
}
