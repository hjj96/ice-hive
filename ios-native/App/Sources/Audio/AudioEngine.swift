import Foundation
import AVFoundation
import IceHiveCore

// ================================================================
//  AUDIO — AVAudioEngine with a pool of player-node voices (cheap,
//  in-process scheduling; AVAudioPlayer calls were milliseconds each).
//  Sounds/sounds-manifest.json gives files, base gain, distance
//  attenuation and the web SFX_GAP per sound; the beds (wind, swarm
//  chitter / rumble, flame, cryo, minigun spin) loop on their own nodes
//  with levels following the web rules. `-mute` disables everything.
//  Interruptions (calls, Siri, another app), route / sample-rate changes
//  stop the engine: it is restarted and the voices and beds re-armed.
//  A media-services reset invalidates the whole graph: `onMediaReset`
//  asks the scene to build a new engine.
// ================================================================
final class AudioEngine {
    private struct Def {
        let buffers: [AVAudioPCMBuffer]
        let gain: Float
        let attenuated: Bool
        let minInterval: Double
        let duration: Double
    }
    private final class Voice {
        let node = AVAudioPlayerNode()
        var busyUntil: Double = 0
        var volume: Float = -1
    }
    private enum Bed: Int, CaseIterable { case wind, chitter, rumble, flame, cryo, spin
        var name: String {
            switch self {
            case .wind: return "wind"
            case .chitter: return "chitter"
            case .rumble: return "rumble"
            case .flame: return "flame"
            case .cryo: return "cryo"
            case .spin: return "spin"
            }
        }
        /// Web setTargetAtTime time constants (09-audio.js audioUpdate).
        var tau: Float {
            switch self {
            case .flame, .cryo: return 0.06
            case .spin: return 0.08
            case .chitter: return 0.3
            case .rumble: return 0.4
            case .wind: return 0.3
            }
        }
    }
    private final class Loop {
        let node = AVAudioPlayerNode()
        let gain: Float
        let buffer: AVAudioPCMBuffer
        var level: Float = 0
        var volume: Float = -1
        var varispeed: AVAudioUnitVarispeed?
        init(gain: Float, buffer: AVAudioPCMBuffer) { self.gain = gain; self.buffer = buffer }
    }

    private let engine = AVAudioEngine()
    /// Indexed by SoundID ordinal (no string hashing per play).
    private var defs: [Def?] = []
    private var last: [Double] = []
    private var voices: [Voice] = []
    /// The combo chime raises its pitch with the counter (web: 520 Hz · 1.06^min(24, combo / 5)).
    private let pitched = Voice()
    private let pitchUnit = AVAudioUnitVarispeed()
    private var loops: [Loop?] = []
    private var variant = 0
    private(set) var enabled: Bool
    /// Master gain (web AU.vol, 0 when muted).
    var master: Float = 0.8 { didSet { if master != oldValue { forceVolumes() } } }
    private(set) var played = 0
    private(set) var requested = 0
    private(set) var restarts = 0
    private var clock: Double = 0
    private var spinRate: Float = 1
    private var observers: [NSObjectProtocol] = []
    /// Media services were reset: the scene should drop this engine and build a new one.
    var onMediaReset: (() -> Void)?
    private static let ids: [SoundID] = SoundID.allCases
    private static let beds: [Bed] = Bed.allCases

    init(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { AppLog.info("audio: muted"); return }
        let t0 = FrameTimer.now()
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
        } catch {
            AppLog.error("audio session: \(error.localizedDescription)")
        }
        guard let url = Bundle.main.url(forResource: "sounds-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = any as? [String: Any] else {
            AppLog.error("audio: sounds-manifest.json missing")
            self.enabled = false
            return
        }
        var format: AVAudioFormat?
        defs = [Def?](repeating: nil, count: AudioEngine.ids.count)
        last = [Double](repeating: -1e9, count: AudioEngine.ids.count)
        if let sounds = root["sounds"] as? [String: Any] {
            for (k, id) in AudioEngine.ids.enumerated() {
                guard let s = sounds[id.rawValue] as? [String: Any] else { continue }
                let bufs = (s["files"] as? [String] ?? []).compactMap { AudioEngine.load($0) }
                if bufs.isEmpty { continue }
                if format == nil { format = bufs[0].format }
                let gain = Float((s["baseGain"] as? NSNumber)?.doubleValue ?? 0.5)
                let att = (s["attenuated"] as? Bool) ?? true
                let gap = (s["minInterval"] as? NSNumber)?.doubleValue ?? 0.03
                let dur = (s["duration"] as? NSNumber)?.doubleValue ?? 0.5
                defs[k] = Def(buffers: bufs, gain: gain, attenuated: att, minInterval: gap, duration: dur)
            }
        }
        guard let fmt = format else { self.enabled = false; AppLog.error("audio: no sounds loaded"); return }
        let mixer = engine.mainMixerNode
        for _ in 0..<20 {
            let v = Voice()
            engine.attach(v.node)
            engine.connect(v.node, to: mixer, format: fmt)
            voices.append(v)
        }
        engine.attach(pitched.node)
        engine.attach(pitchUnit)
        engine.connect(pitched.node, to: pitchUnit, format: fmt)
        engine.connect(pitchUnit, to: mixer, format: fmt)
        loops = [Loop?](repeating: nil, count: AudioEngine.beds.count)
        if let ls = root["loops"] as? [String: Any] {
            for bed in AudioEngine.beds {
                guard let s = ls[bed.name] as? [String: Any], let f = (s["files"] as? [String])?.first, let buf = AudioEngine.load(f) else { continue }
                let l = Loop(gain: Float((s["baseGain"] as? NSNumber)?.doubleValue ?? 0.1), buffer: buf)
                engine.attach(l.node)
                if bed == .spin {
                    let vs = AVAudioUnitVarispeed()
                    engine.attach(vs)
                    engine.connect(l.node, to: vs, format: buf.format)
                    engine.connect(vs, to: mixer, format: buf.format)
                    l.varispeed = vs
                } else {
                    engine.connect(l.node, to: mixer, format: buf.format)
                }
                l.node.volume = 0
                loops[bed.rawValue] = l
            }
        }
        engine.prepare()
        if !startEngine() {
            self.enabled = false
            return
        }
        observe()
        let nLoops = loops.compactMap { $0 }.count
        AppLog.info("audio: \(defs.compactMap { $0 }.count) sounds, \(nLoops) loops, \(voices.count) voices"
                    + String(format: " (%.0f ms)", (FrameTimer.now() - t0) * 1000))
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private static func load(_ file: String) -> AVAudioPCMBuffer? {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? "wav" : ext),
              let f = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
        do { try f.read(into: buf) } catch { return nil }
        return buf
    }

    /// Start the engine, then (only once it runs: play() on a stopped engine raises) arm every voice and bed.
    @discardableResult
    private func startEngine() -> Bool {
        do {
            try engine.start()
        } catch {
            AppLog.error("audio engine: \(error.localizedDescription) — sound off until the next restart")
            return false
        }
        for v in voices { v.node.play(); v.busyUntil = 0 }
        pitched.node.play()
        pitched.busyUntil = 0
        for case let l? in loops {
            l.node.stop()
            l.node.scheduleBuffer(l.buffer, at: nil, options: .loops, completionHandler: nil)
            l.node.play()
        }
        forceVolumes()
        return true
    }

    private func forceVolumes() {
        for v in voices { v.volume = -1 }
        pitched.volume = -1
        for case let l? in loops { l.volume = -1 }
    }

    /// Session back after an interruption, the app active again, or the engine stopped by a route change.
    func restart(_ why: String) {
        guard enabled, !engine.isRunning else { return }
        do { try AVAudioSession.sharedInstance().setActive(true, options: []) } catch {
            AppLog.error("audio session reactivate (\(why)): \(error.localizedDescription)")
        }
        if startEngine() {
            restarts += 1
            AppLog.info("audio: engine restarted (\(why))")
        }
    }

    private func observe() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let s = self else { return }
            let raw = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
            if AVAudioSession.InterruptionType(rawValue: raw) == .ended { s.restart("interruption ended") }
        })
        observers.append(nc.addObserver(forName: NSNotification.Name.AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart("configuration change")
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let s = self else { return }
            AppLog.info("audio: media services reset, rebuilding the engine")
            s.enabled = false
            s.onMediaReset?()
        })
    }

    /// Play a one-shot (pos nil = non-positional). Honours the per-sound minimum gap; `loud == false` (a bot's
    /// weapon / ability) plays at half volume like the web sfx(); `rate` pitches it (combo chime only).
    func play(_ id: SoundID, pos: Vec2?, listener: Vec2, loud: Bool? = nil, rate: Float = 1) {
        requested += 1
        guard enabled, engine.isRunning else { return }
        let k = id.ordinal
        guard k < defs.count, let def = defs[k] else { return }
        if clock - last[k] < def.minInterval { return }
        var v: Float = 1
        if def.attenuated, let p = pos {
            let d = ((p.x - listener.x) * (p.x - listener.x) + (p.y - listener.y) * (p.y - listener.y)).squareRoot()
            v = max(0.08, min(1, 1.1 - d / 34))
        }
        if loud == false { v *= 0.5 }
        var best: Voice
        if rate != 1 {
            best = pitched
            pitchUnit.rate = max(0.25, min(4, rate))
        } else {
            // a free voice, else the one that frees up first
            best = voices[0]
            for vo in voices {
                if vo.busyUntil <= clock { best = vo; break }
                if vo.busyUntil < best.busyUntil { best = vo }
            }
        }
        variant += 1
        let buf = def.buffers[variant % def.buffers.count]
        let vol = def.gain * v * master
        if abs(vol - best.volume) > 0.005 { best.node.volume = vol; best.volume = vol }
        best.node.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        best.busyUntil = clock + def.duration / Double(max(0.25, rate))
        last[k] = clock
        played += 1
    }

    /// Beds: wind always, swarm chitter / rumble by bugs near the camera, weapon loops by the squad's firing.
    /// `live` = the world runs (mission or title): under the pause menu, level-up cards and the report every
    /// bed but the wind falls silent (web: GS.screen === 'playing' || 'title').
    func update(dt: Float, game: Game?, bugsNear: Int, listener: Vec2, title: Bool, live: Bool) {
        clock += Double(dt)
        guard enabled else { return }
        let swarm: Float = live ? min(1, Float(bugsNear) / 500) * (title ? 0.4 : 1) : 0
        var flame: Float = 0, cryo: Float = 0, spin: Float = 0
        var rate: Float = 0.2
        if live, let g = game {
            for m in g.marines where !m.downed {
                let d = ((m.x - listener.x) * (m.x - listener.x) + (m.z - listener.y) * (m.z - listener.y)).squareRoot()
                let near = max(0.1, min(1, 1.1 - d / 30))
                if m.cls == .pyro && m.firing { flame = max(flame, near * (m.isPlayer ? 1 : 0.6)) }
                if m.cls == .cryo && m.firing { cryo = max(cryo, near * (m.isPlayer ? 1 : 0.6)) }
                if m.cls == .gunner {
                    spin = max(spin, m.spin * m.spin * near * (m.isPlayer ? 1 : 0.55))
                    rate = max(rate, (70 + 260 * m.spin) / 330)
                }
            }
        }
        for bed in AudioEngine.beds {
            guard let l = loops[bed.rawValue] else { continue }
            let target: Float
            switch bed {
            case .wind: target = 1
            case .chitter, .rumble: target = swarm
            case .flame: target = flame
            case .cryo: target = cryo
            case .spin: target = spin
            }
            let k = min(1, dt / bed.tau)
            l.level += (target - l.level) * k
            let vol = l.level * l.gain * master
            if abs(vol - l.volume) > 0.002 { l.node.volume = vol; l.volume = vol }
            if let vs = l.varispeed, abs(rate - spinRate) > 0.01 {
                spinRate = rate
                vs.rate = max(0.25, min(2, rate))
            }
        }
    }

    func stopAll() {
        if enabled { engine.stop() }
    }
}

extension SoundID {
    /// Position in `SoundID.allCases` (array index for per-sound tables).
    var ordinal: Int { SoundID.ordinals[self] ?? 0 }
    private static let ordinals: [SoundID: Int] = {
        var d: [SoundID: Int] = [:]
        for (k, id) in SoundID.allCases.enumerated() { d[id] = k }
        return d
    }()
}
