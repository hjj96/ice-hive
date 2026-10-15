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
    private static var missingLogged = 0

    init(_ name: String) {
        self.name = name
        atlas = SKTextureAtlas(named: name)
        for n in atlas.textureNames {
            var s = n
            if let dot = s.lastIndex(of: ".") { s = String(s[s.startIndex..<dot]) }
            if s.hasSuffix("@2x") || s.hasSuffix("@3x") { s = String(s.dropLast(3)) }
            names.insert(s)
        }
    }

    var count: Int { names.count }

    func has(_ frame: String) -> Bool { names.contains(frame) }

    func texture(_ frame: String) -> SKTexture {
        if !names.isEmpty && !names.contains(frame) && Atlas.missingLogged < 12 {
            Atlas.missingLogged += 1
            AppLog.error("atlas \(name): missing frame \(frame)")
        }
        return atlas.textureNamed(frame)
    }
}

/// Textures of one animated sprite set: [dir][frame], plus the parallel glow frames (nil = no glow layer).
struct DirFrames {
    let lit: [[SKTexture]]
    let glow: [[SKTexture]]?
    let info: SpriteSetInfo
    var frameCount: Int { lit.first?.count ?? 0 }
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
    private(set) var bugWalk: [DirFrames] = []
    private(set) var bugClimb: [DirFrames] = []
    private(set) var bugCrest: [DirFrames] = []
    private(set) var bugShadow: [DirFrames] = []
    private(set) var bruteCharge: DirFrames
    private(set) var boomerSwell: DirFrames
    private(set) var corpseFrames: [[SKTexture]] = []
    private(set) var corpseInfo: [SpriteSetInfo] = []
    /// Sprite scale baked into the bug frames (BUG_SPECS scale).
    let bugBakedScale: [Float] = BugType.allCases.map { $0.spec.scale }

    // marines, index = MarineClass.rawValue
    private(set) var marineRun: [DirFrames] = []
    private(set) var marineStrafe: [DirFrames] = []
    private(set) var marineIdle: [DirFrames] = []
    private(set) var marineDash: [DirFrames] = []
    private(set) var marineDowned: [DirFrames] = []

    init() {
        bugs = Atlas("Bugs"); bugsGlow = Atlas("BugsGlow"); corpses = Atlas("Corpses")
        marines = Atlas("Marines"); marinesGlow = Atlas("MarinesGlow"); props = Atlas("Props")
        level = Atlas("Level"); levelGlow = Atlas("LevelGlow"); ground = Atlas("Ground"); particles = Atlas("Particles")
        background = Atlas("Background"); backgroundGlow = Atlas("BackgroundGlow")
        bruteCharge = DirFrames(lit: [], glow: nil, info: SpriteSetInfo(anchor: .zero, size: .zero))
        boomerSwell = bruteCharge

        for t in BugType.allCases {
            let id = t.id
            bugWalk.append(dirFrames(bugs, bugsGlow, "\(id)_walk", frames: 8, set: "\(id)_walk"))
            bugClimb.append(dirFrames(bugs, bugsGlow, "\(id)_climb", frames: 4, set: "\(id)_climb"))
            bugCrest.append(dirFrames(bugs, bugsGlow, "\(id)_crest", frames: 2, set: "\(id)_crest"))
            bugShadow.append(dirFrames(bugs, nil, "\(id)_shadow", frames: 1, set: "\(id)_shadow"))
            var cf: [SKTexture] = []
            for v in 0..<6 { cf.append(corpses.texture("\(id)_corpse_\(v)")) }
            corpseFrames.append(cf)
            corpseInfo.append(manifest.info("corpse_\(id)"))
        }
        bruteCharge = dirFrames(bugs, bugsGlow, "brute_charge", frames: 4, set: "brute_charge")
        boomerSwell = dirFrames(bugs, bugsGlow, "boomer_swell", frames: 3, set: "boomer_swell")
        for c in MarineClass.allCases {
            let id = c.id
            marineRun.append(dirFrames(marines, marinesGlow, "\(id)_run", frames: 8, set: "\(id)_run"))
            marineStrafe.append(dirFrames(marines, marinesGlow, "\(id)_strafe", frames: 4, set: "\(id)_strafe"))
            marineIdle.append(dirFrames(marines, marinesGlow, "\(id)_idle", frames: 1, set: "\(id)_idle"))
            marineDash.append(dirFrames(marines, marinesGlow, "\(id)_dash", frames: 1, set: "\(id)_dash"))
            marineDowned.append(dirFrames(marines, marinesGlow, "\(id)_downed", frames: 1, set: "\(id)_downed"))
        }
        AppLog.info("atlases: bugs=\(bugs.count) glow=\(bugsGlow.count) marines=\(marines.count) level=\(level.count) ground=\(ground.count) particles=\(particles.count) props=\(props.count)")
    }

    private func dirFrames(_ lit: Atlas, _ glow: Atlas?, _ prefix: String, frames: Int, set: String) -> DirFrames {
        var l: [[SKTexture]] = []
        var g: [[SKTexture]] = []
        for d in 0..<16 {
            var lf: [SKTexture] = []
            var gf: [SKTexture] = []
            let dd = d < 10 ? "0\(d)" : "\(d)"
            for f in 0..<frames {
                let name = frames > 1 ? "\(prefix)_\(dd)_\(f)" : "\(prefix)_\(dd)"
                lf.append(lit.texture(name))
                if let ga = glow { gf.append(ga.texture(name + "_g")) }
            }
            l.append(lf)
            g.append(gf)
        }
        return DirFrames(lit: l, glow: glow == nil ? nil : g, info: manifest.info(set))
    }

    /// Load every atlas page up front (no hitch the first time a frame shows up).
    func preload(_ done: @escaping () -> Void) {
        let all: [SKTextureAtlas] = [bugs.atlas, bugsGlow.atlas, corpses.atlas, marines.atlas, marinesGlow.atlas, props.atlas,
                                     level.atlas, levelGlow.atlas, ground.atlas, particles.atlas, background.atlas, backgroundGlow.atlas]
        let t0 = Date()
        SKTextureAtlas.preloadTextureAtlases(all) {
            DispatchQueue.main.async {
                AppLog.info(String(format: "atlases preloaded in %.2fs", Date().timeIntervalSince(t0)))
                done()
            }
        }
    }
}
