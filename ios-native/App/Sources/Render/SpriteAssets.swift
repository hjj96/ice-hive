import SpriteKit
import IceHiveCore

// ================================================================
//  SPRITE MANIFEST — anchors and point sizes of every sprite set
//  (App/Resources/sprites-manifest.json, written by tools/render-sprites.mjs)
// ================================================================
struct SpriteSetInfo {
    let anchor: CGPoint
    let size: CGSize
}

final class SpriteManifest {
    private(set) var sets: [String: SpriteSetInfo] = [:]
    /// lift_rail_xx → offset (x, z) from the lift centre in metres.
    private(set) var liftRailOffsets: [String: (Float, Float)] = [:]

    init() {
        guard let url = Bundle.main.url(forResource: "sprites-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rootAny = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = rootAny as? [String: Any],
              let sets = root["sets"] as? [String: Any] else {
            AppLog.error("sprites-manifest.json missing or unreadable")
            return
        }
        for (key, value) in sets {
            guard let s = value as? [String: Any] else { continue }
            let a = SpriteManifest.numbers(s["anchor"])
            let sz = SpriteManifest.numbers(s["sizePoints"])
            let anchor = a.count >= 2 ? CGPoint(x: a[0], y: a[1]) : CGPoint(x: 0.5, y: 0.5)
            let size = sz.count >= 2 ? CGSize(width: sz[0], height: sz[1]) : CGSize(width: 32, height: 32)
            self.sets[key] = SpriteSetInfo(anchor: anchor, size: size)
            if key == "lift_rail", let offs = s["anchorsFromLiftCentre"] as? [String: Any] {
                for (name, v) in offs {
                    let n = SpriteManifest.numbers(v)
                    if n.count >= 3 { liftRailOffsets[name] = (Float(n[0]), Float(n[2])) }
                }
            }
        }
        AppLog.info("manifest: \(self.sets.count) sprite sets")
    }

    static func numbers(_ v: Any?) -> [Double] {
        guard let arr = v as? [Any] else { return [] }
        var out: [Double] = []
        for e in arr {
            if let d = e as? Double { out.append(d) } else if let n = e as? NSNumber { out.append(n.doubleValue) } else if let i = e as? Int { out.append(Double(i)) }
        }
        return out
    }

    func info(_ set: String) -> SpriteSetInfo {
        if let s = sets[set] { return s }
        return SpriteSetInfo(anchor: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: 32, height: 32))
    }
}

// ================================================================
//  ATLAS — one SKTextureAtlas with a name check (missing frames are
//  logged once instead of silently drawing the placeholder).
// ================================================================
final class Atlas {
    let name: String
    let atlas: SKTextureAtlas
    private var names: Set<String> = []
    private var cache: [String: SKTexture] = [:]
    private static var missingLogged = 0
    /// SKTextureAtlas.textureNamed costs ~1 ms per call on the simulator: count + time them.
    static var lookups = 0
    /// `-texlookup atlas` switches back to SKTextureAtlas.textureNamed (comparison runs).
    static var useNamedLookup = true
    static var lookupSeconds: Double = 0

    init(_ name: String) {
        self.name = name
        atlas = SKTextureAtlas(named: name)
        let t0 = ProcessInfo.processInfo.systemUptime
        for n in atlas.textureNames {
            var s = n
            if let dot = s.lastIndex(of: ".") { s = String(s[s.startIndex..<dot]) }
            if s.hasSuffix("@2x") || s.hasSuffix("@3x") { s = String(s.dropLast(3)) }
            names.insert(s)
        }
        let dt = ProcessInfo.processInfo.systemUptime - t0
        if dt > 0.05 { AppLog.info("atlas \(name): textureNames " + String(format: "%.0f ms", dt * 1000)) }
    }

    var count: Int { names.count }

    /// Every texture resolved so far (preload list).
    var cachedTextures: [SKTexture] { Array(cache.values) }

    func has(_ frame: String) -> Bool { names.contains(frame) }

    func texture(_ frame: String) -> SKTexture {
        if let t = cache[frame] { return t }
        if !names.isEmpty && !names.contains(frame) && Atlas.missingLogged < 12 {
            Atlas.missingLogged += 1
            AppLog.error("atlas \(name): missing frame \(frame)")
        }
        let t0 = ProcessInfo.processInfo.systemUptime
        // SKTexture(imageNamed:) resolves the frame inside the compiled sprite atlas lazily (~0.01 ms);
        // SKTextureAtlas.textureNamed costs ~3 ms per call on the simulator.
        let t = Atlas.useNamedLookup ? SKTexture(imageNamed: frame) : atlas.textureNamed(frame)
        Atlas.lookupSeconds += ProcessInfo.processInfo.systemUptime - t0
        Atlas.lookups += 1
        cache[frame] = t
        return t
    }
}

/// Frames of one animated sprite set, [dir][frame], resolved lazily (texture lookups are slow) and cached;
/// `warm` resolves a few per call so the tables fill up in the background.
final class FrameSet {
    let info: SpriteSetInfo
    let frameCount: Int
    let hasGlow: Bool
    private let lit: Atlas
    private let glowAtlas: Atlas?
    private let prefix: String
    private var litTex: [SKTexture?]
    private var glowTex: [SKTexture?]
    private var warmIndex = 0

    init(_ lit: Atlas, _ glow: Atlas?, _ prefix: String, frames: Int, info: SpriteSetInfo) {
        self.lit = lit
        self.glowAtlas = glow
        self.prefix = prefix
        self.frameCount = frames
        self.info = info
        self.hasGlow = glow != nil
        litTex = [SKTexture?](repeating: nil, count: 16 * frames)
        glowTex = [SKTexture?](repeating: nil, count: glow == nil ? 0 : 16 * frames)
    }

    private func name(_ dir: Int, _ f: Int) -> String {
        let dd = dir < 10 ? "0\(dir)" : "\(dir)"
        return frameCount > 1 ? "\(prefix)_\(dd)_\(f)" : "\(prefix)_\(dd)"
    }

    @inline(__always) func tex(_ dir: Int, _ f: Int) -> SKTexture {
        let k = dir * frameCount + f
        if let t = litTex[k] { return t }
        let t = lit.texture(name(dir, f))
        litTex[k] = t
        return t
    }

    @inline(__always) func glow(_ dir: Int, _ f: Int) -> SKTexture? {
        guard let ga = glowAtlas else { return nil }
        let k = dir * frameCount + f
        if let t = glowTex[k] { return t }
        let t = ga.texture(name(dir, f) + "_g")
        glowTex[k] = t
        return t
    }

    /// Resolve up to `count` more frames; returns false when the set is complete.
    func warm(_ count: Int) -> Bool {
        var n = 0
        while warmIndex < 16 * frameCount && n < count {
            let d = warmIndex / frameCount, f = warmIndex % frameCount
            _ = tex(d, f)
            _ = glow(d, f)
            warmIndex += 1
            n += 1
        }
        return warmIndex < 16 * frameCount
    }
}

// ================================================================
//  SPRITE ASSETS — every atlas + the frame tables the layers index
// ================================================================
final class SpriteAssets {
    let manifest = SpriteManifest()
    let bugs: Atlas, bugsGlow: Atlas, corpses: Atlas, marines: Atlas, marinesGlow: Atlas
    let props: Atlas, level: Atlas, levelGlow: Atlas, ground: Atlas, particles: Atlas
    let background: Atlas, backgroundGlow: Atlas

    // bugs, index = BugType.rawValue
    private(set) var bugWalk: [FrameSet] = []
    private(set) var bugClimb: [FrameSet] = []
    private(set) var bugCrest: [FrameSet] = []
    private(set) var bugShadow: [FrameSet] = []
    private(set) var bruteCharge: FrameSet
    private(set) var boomerSwell: FrameSet
    private(set) var corpseFrames: [[SKTexture]] = []
    private(set) var corpseInfo: [SpriteSetInfo] = []
    /// Sprite scale baked into the bug frames (BUG_SPECS scale).
    let bugBakedScale: [Float] = BugType.allCases.map { $0.spec.scale }

    // marines, index = MarineClass.rawValue
    private(set) var marineRun: [FrameSet] = []
    private(set) var marineStrafe: [FrameSet] = []
    private(set) var marineIdle: [FrameSet] = []
    private(set) var marineDash: [FrameSet] = []
    private(set) var marineDowned: [FrameSet] = []
    /// Warm-up order: what the first seconds of play need first.
    private var warmQueue: [FrameSet] = []

    init() {
        bugs = Atlas("Bugs"); bugsGlow = Atlas("BugsGlow"); corpses = Atlas("Corpses")
        marines = Atlas("Marines"); marinesGlow = Atlas("MarinesGlow"); props = Atlas("Props")
        level = Atlas("Level"); levelGlow = Atlas("LevelGlow"); ground = Atlas("Ground"); particles = Atlas("Particles")
        background = Atlas("Background"); backgroundGlow = Atlas("BackgroundGlow")
        bruteCharge = FrameSet(bugs, bugsGlow, "brute_charge", frames: 4, info: manifest.info("brute_charge"))
        boomerSwell = FrameSet(bugs, bugsGlow, "boomer_swell", frames: 3, info: manifest.info("boomer_swell"))

        for t in BugType.allCases {
            let id = t.id
            bugWalk.append(dirFrames(bugs, bugsGlow, "\(id)_walk", frames: 8, set: "\(id)_walk"))
            bugClimb.append(dirFrames(bugs, bugsGlow, "\(id)_climb", frames: 4, set: "\(id)_climb"))
            bugCrest.append(dirFrames(bugs, bugsGlow, "\(id)_crest", frames: 2, set: "\(id)_crest"))
            bugShadow.append(dirFrames(bugs, nil, "\(id)_shadow", frames: 1, set: "\(id)_shadow"))
            corpseInfo.append(manifest.info("corpse_\(id)"))
        }
        for c in MarineClass.allCases {
            let id = c.id
            marineRun.append(dirFrames(marines, marinesGlow, "\(id)_run", frames: 8, set: "\(id)_run"))
            marineStrafe.append(dirFrames(marines, marinesGlow, "\(id)_strafe", frames: 4, set: "\(id)_strafe"))
            marineIdle.append(dirFrames(marines, marinesGlow, "\(id)_idle", frames: 1, set: "\(id)_idle"))
            marineDash.append(dirFrames(marines, marinesGlow, "\(id)_dash", frames: 1, set: "\(id)_dash"))
            marineDowned.append(dirFrames(marines, marinesGlow, "\(id)_downed", frames: 1, set: "\(id)_downed"))
        }
        warmQueue = marineIdle + marineRun + [bugWalk[0], bugShadow[0]] + marineStrafe + marineDash + marineDowned
            + [bugClimb[0], bugCrest[0], bugWalk[1], bugShadow[1], bugWalk[3], bugShadow[3], bugWalk[2], bugShadow[2],
               bruteCharge, boomerSwell, bugClimb[1], bugCrest[1], bugClimb[2], bugCrest[2], bugClimb[3], bugCrest[3]]
        AppLog.info("atlases: bugs=\(bugs.count) glow=\(bugsGlow.count) marines=\(marines.count) level=\(level.count) ground=\(ground.count) particles=\(particles.count) props=\(props.count)")
    }

    private func dirFrames(_ lit: Atlas, _ glow: Atlas?, _ prefix: String, frames: Int, set: String) -> FrameSet {
        FrameSet(lit, glow, prefix, frames: frames, info: manifest.info(set))
    }

    /// Corpse frames of a bug type (6 variants, resolved on first use).
    func corpse(_ t: Int, _ v: Int) -> SKTexture {
        if corpseFrames.isEmpty {
            for b in BugType.allCases { corpseFrames.append((0..<6).map { corpses.texture("\(b.id)_corpse_\($0)") }) }
        }
        return corpseFrames[t][v % 6]
    }

    /// Resolve every bug / marine / corpse frame (cheap with named lookups) so they can be preloaded.
    func resolveAll() {
        while let s = warmQueue.first {
            if !s.warm(64) { warmQueue.removeFirst() }
        }
        _ = corpse(0, 0)
    }

    /// All textures resolved in any atlas (for SKTexture.preload behind the loading screen).
    func allTextures() -> [SKTexture] {
        var out: [SKTexture] = []
        for a in [bugs, bugsGlow, corpses, marines, marinesGlow, props, level, levelGlow, ground, particles, background, backgroundGlow] {
            out.append(contentsOf: a.cachedTextures)
        }
        return out
    }

    /// Resolve frame textures for about `budget` seconds; returns true while work remains.
    @discardableResult
    func warm(budget: Double) -> Bool {
        let t0 = ProcessInfo.processInfo.systemUptime
        while let s = warmQueue.first {
            if !s.warm(4) { warmQueue.removeFirst() }
            if ProcessInfo.processInfo.systemUptime - t0 > budget { break }
        }
        return !warmQueue.isEmpty
    }

}
