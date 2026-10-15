import Foundation
import AVFoundation
import IceHiveCore

// ================================================================
//  AUDIO — first-playable engine on AVAudioPlayer voices.
//  Sounds/sounds-manifest.json gives files, base gain, distance
//  attenuation and the web SFX_GAP per sound; the beds (wind, swarm
//  chitter / rumble, flame, cryo, minigun spin) loop with levels
//  following the web rules. A proper AVAudioEngine mixer with the web
//  compressor is a later step; `-mute` disables everything.
// ================================================================
final class AudioEngine {
    private struct Def {
        let files: [URL]
        let gain: Float
        let attenuated: Bool
        let minInterval: Double
    }
    private var defs: [String: Def] = [:]
    private var voices: [String: [AVAudioPlayer]] = [:]
    private var last: [String: Double] = [:]
    private var loops: [String: AVAudioPlayer] = [:]
    private var loopGain: [String: Float] = [:]
    private var loopLevel: [String: Float] = [:]
    private(set) var enabled: Bool
    var master: Float = 0.8
    private(set) var played = 0
    private(set) var requested = 0
    private var clock: Double = 0

    init(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { AppLog.info("audio: muted"); return }
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
        if let sounds = root["sounds"] as? [String: Any] {
            for (name, v) in sounds {
                guard let s = v as? [String: Any] else { continue }
                let files = (s["files"] as? [String] ?? []).compactMap { AudioEngine.url($0) }
                if files.isEmpty { continue }
                let gain = Float((s["baseGain"] as? NSNumber)?.doubleValue ?? 0.5)
                let att = (s["attenuated"] as? Bool) ?? true
                let gap = (s["minInterval"] as? NSNumber)?.doubleValue ?? 0.03
                defs[name] = Def(files: files, gain: gain, attenuated: att, minInterval: gap)
            }
        }
        if let ls = root["loops"] as? [String: Any] {
            for (name, v) in ls {
                guard let s = v as? [String: Any], let f = (s["files"] as? [String])?.first, let u = AudioEngine.url(f) else { continue }
                if let p = try? AVAudioPlayer(contentsOf: u) {
                    p.numberOfLoops = -1
                    p.volume = 0
                    p.enableRate = name == "spin"
                    p.prepareToPlay()
                    loops[name] = p
                    loopGain[name] = Float((s["baseGain"] as? NSNumber)?.doubleValue ?? 0.1)
                    loopLevel[name] = 0
                }
            }
        }
        AppLog.info("audio: \(defs.count) sounds, \(loops.count) loops")
    }

    private static func url(_ file: String) -> URL? {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: base, withExtension: ext.isEmpty ? "wav" : ext)
    }

    private func voice(_ name: String, _ def: Def) -> AVAudioPlayer? {
        var list = voices[name] ?? []
        for p in list where !p.isPlaying { return p }
        if list.count >= 4 { return list.min { $0.currentTime > $1.currentTime } }
        let file = def.files[list.count % def.files.count]
        guard let p = try? AVAudioPlayer(contentsOf: file) else { return nil }
        p.prepareToPlay()
        list.append(p)
        voices[name] = list
        return p
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
        guard let p = voice(id.rawValue, def) else { return }
        last[id.rawValue] = clock
        p.currentTime = 0
        p.volume = def.gain * v * master
        p.play()
        played += 1
    }

    /// Beds: wind always, swarm chitter / rumble by bugs near the camera, weapon loops by the squad's firing.
    func update(dt: Float, game: Game?, bugsNear: Int, listener: Vec2, title: Bool) {
        clock += Double(dt)
        guard enabled else { return }
        var want: [String: Float] = ["wind": 1, "chitter": 0, "rumble": 0, "flame": 0, "cryo": 0, "spin": 0]
        let swarm = min(1, Float(bugsNear) / 500) * (title ? 0.4 : 1)
        want["chitter"] = swarm
        want["rumble"] = swarm
        var spinRate: Float = 0.2
        if let g = game {
            for m in g.marines where !m.downed {
                let d = ((m.x - listener.x) * (m.x - listener.x) + (m.z - listener.y) * (m.z - listener.y)).squareRoot()
                let near = max(0.1, min(1, 1.1 - d / 30)) * (m.isPlayer ? 1 : 0.6)
                if m.cls == .pyro && m.firing { want["flame"] = max(want["flame"] ?? 0, near) }
                if m.cls == .cryo && m.firing { want["cryo"] = max(want["cryo"] ?? 0, near) }
                if m.cls == .gunner {
                    want["spin"] = max(want["spin"] ?? 0, m.spin * m.spin * near)
                    spinRate = max(spinRate, (70 + 260 * m.spin) / 330)
                }
            }
        }
        for (name, p) in loops {
            let target = (want[name] ?? 0)
            var lvl = loopLevel[name] ?? 0
            let k = min(1, dt / (name == "flame" || name == "cryo" ? 0.06 : 0.3))
            lvl += (target - lvl) * k
            loopLevel[name] = lvl
            let vol = lvl * (loopGain[name] ?? 0.1) * master
            p.volume = vol
            if name == "spin" { p.rate = max(0.5, min(2, spinRate)) }
            if vol > 0.001 && !p.isPlaying { p.play() } else if vol <= 0.001 && p.isPlaying { p.pause() }
        }
    }

    func stopAll() {
        for p in loops.values { p.stop() }
        for list in voices.values { for p in list { p.stop() } }
    }
}
