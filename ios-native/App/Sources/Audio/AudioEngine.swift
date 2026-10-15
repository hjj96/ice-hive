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
    private final class Loop {
        let node = AVAudioPlayerNode()
        let gain: Float
        var level: Float = 0
        var volume: Float = -1
        var varispeed: AVAudioUnitVarispeed?
        init(gain: Float) { self.gain = gain }
    }

    private let engine = AVAudioEngine()
    private var defs: [String: Def] = [:]
    private var voices: [Voice] = []
    private var loops: [String: Loop] = [:]
    private var last: [String: Double] = [:]
    private var variant = 0
    private(set) var enabled: Bool
    var master: Float = 0.8
    private(set) var played = 0
    private(set) var requested = 0
    private var clock: Double = 0
    private var spinRate: Float = 1

    init(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { AppLog.info("audio: muted"); return }
        let t0 = ProcessInfo.processInfo.systemUptime
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
        if let sounds = root["sounds"] as? [String: Any] {
            for (name, v) in sounds {
                guard let s = v as? [String: Any] else { continue }
                let bufs = (s["files"] as? [String] ?? []).compactMap { AudioEngine.load($0) }
                if bufs.isEmpty { continue }
                if format == nil { format = bufs[0].format }
                let gain = Float((s["baseGain"] as? NSNumber)?.doubleValue ?? 0.5)
                let att = (s["attenuated"] as? Bool) ?? true
                let gap = (s["minInterval"] as? NSNumber)?.doubleValue ?? 0.03
                let dur = (s["duration"] as? NSNumber)?.doubleValue ?? 0.5
                defs[name] = Def(buffers: bufs, gain: gain, attenuated: att, minInterval: gap, duration: dur)
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
        var loopBuffers: [String: AVAudioPCMBuffer] = [:]
        if let ls = root["loops"] as? [String: Any] {
            for (name, v) in ls {
                guard let s = v as? [String: Any], let f = (s["files"] as? [String])?.first, let buf = AudioEngine.load(f) else { continue }
                let l = Loop(gain: Float((s["baseGain"] as? NSNumber)?.doubleValue ?? 0.1))
                engine.attach(l.node)
                if name == "spin" {
                    let vs = AVAudioUnitVarispeed()
                    engine.attach(vs)
                    engine.connect(l.node, to: vs, format: buf.format)
                    engine.connect(vs, to: mixer, format: buf.format)
                    l.varispeed = vs
                } else {
                    engine.connect(l.node, to: mixer, format: buf.format)
                }
                l.node.volume = 0
                loops[name] = l
                loopBuffers[name] = buf
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            AppLog.error("audio engine: \(error.localizedDescription) — sound off")
            self.enabled = false
            return
        }
        for v in voices { v.node.play() }
        for (name, l) in loops {
            if let b = loopBuffers[name] { l.node.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil) }
            l.node.play()
        }
        AppLog.info("audio: \(defs.count) sounds, \(loops.count) loops, \(voices.count) voices"
                    + String(format: " (%.0f ms)", (ProcessInfo.processInfo.systemUptime - t0) * 1000))
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

    /// Play a one-shot (pos nil = non-positional). Honours the per-sound minimum gap.
    func play(_ id: SoundID, pos: Vec2?, listener: Vec2) {
        requested += 1
        guard enabled, let def = defs[id.rawValue] else { return }
        if let t = last[id.rawValue], clock - t < def.minInterval { return }
        var v: Float = 1
        if def.attenuated, let p = pos {
            let d = ((p.x - listener.x) * (p.x - listener.x) + (p.y - listener.y) * (p.y - listener.y)).squareRoot()
            v = max(0.08, min(1, 1.1 - d / 34))
        }
        // a free voice, else the one that frees up first
        var best = voices[0]
        for vo in voices {
            if vo.busyUntil <= clock { best = vo; break }
            if vo.busyUntil < best.busyUntil { best = vo }
        }
        variant += 1
        let buf = def.buffers[variant % def.buffers.count]
        let vol = def.gain * v * master
        if abs(vol - best.volume) > 0.005 { best.node.volume = vol; best.volume = vol }
        best.node.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        best.busyUntil = clock + def.duration
        last[id.rawValue] = clock
        played += 1
    }

    /// Beds: wind always, swarm chitter / rumble by bugs near the camera, weapon loops by the squad's firing.
    func update(dt: Float, game: Game?, bugsNear: Int, listener: Vec2, title: Bool) {
        clock += Double(dt)
        guard enabled else { return }
        let swarm = min(1, Float(bugsNear) / 500) * (title ? 0.4 : 1)
        var flame: Float = 0, cryo: Float = 0, spin: Float = 0
        var rate: Float = 0.2
        if let g = game {
            for m in g.marines where !m.downed {
                let d = ((m.x - listener.x) * (m.x - listener.x) + (m.z - listener.y) * (m.z - listener.y)).squareRoot()
                let near = max(0.1, min(1, 1.1 - d / 30)) * (m.isPlayer ? 1 : 0.6)
                if m.cls == .pyro && m.firing { flame = max(flame, near) }
                if m.cls == .cryo && m.firing { cryo = max(cryo, near) }
                if m.cls == .gunner {
                    spin = max(spin, m.spin * m.spin * near)
                    rate = max(rate, (70 + 260 * m.spin) / 330)
                }
            }
        }
        for (name, l) in loops {
            let target: Float
            switch name {
            case "wind": target = 1
            case "chitter", "rumble": target = swarm
            case "flame": target = flame
            case "cryo": target = cryo
            case "spin": target = spin
            default: target = 0
            }
            let k = min(1, dt / (name == "flame" || name == "cryo" ? 0.06 : 0.3))
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
