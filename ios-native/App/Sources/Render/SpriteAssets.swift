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
//  SPRITE SHEETS — every frame lives in one of five big sheets packed
//  by tools/pack-sheets.mjs (Resources/Sheets: sheet_*.png +
//  sheets.json), grouped by draw layer so SpriteKit batches them:
//  bugs, squad (marines, props, deck objects), glow (all additive
//  emissive layers), level (tiles, background), fx (flat / particles).
//  Frames are @2x and trimmed to their visible pixels; a Sprite keeps
//  where the trimmed rect sits in the full frame, so the manifest's
//  anchors and point sizes still apply (see SKSpriteNode.show).
// ================================================================

/// A packed frame: sub-texture of a sheet + its trimmed rect inside the full frame (normalised, origin bottom-left).
struct Sprite {
    let tex: SKTexture
    let rx: CGFloat, ry: CGFloat, rw: CGFloat, rh: CGFloat
    /// Sheet index (layers use it to keep one draw call per sheet).
    let sheet: Int

    /// Point size of the trimmed sprite for a full frame of `full` points.
    @inline(__always) func size(_ full: CGSize) -> CGSize { CGSize(width: full.width * rw, height: full.height * rh) }
    /// Anchor inside the trimmed sprite that puts the full frame's anchor `a` at the node position.
    @inline(__always) func anchor(_ a: CGPoint) -> CGPoint { CGPoint(x: (a.x - rx) / rw, y: (a.y - ry) / rh) }
}

extension SKSpriteNode {
    /// Show a packed frame with the full frame's point size and anchor (manifest values).
    @inline(__always) func show(_ s: Sprite, size full: CGSize, anchor a: CGPoint) {
        if texture !== s.tex { texture = s.tex }
        size = s.size(full)
        anchorPoint = s.anchor(a)
    }
}

final class SpriteSheets {
    /// One texture per sheet, in sheets.json order.
    private(set) var pages: [SKTexture] = []
    private(set) var pageNames: [String] = []
    private var raw: [String: [Int]] = [:]
    private var cache: [String: Sprite] = [:]
    private var missingLogged = 0
    private let placeholder: Sprite

    init() {
        let t0 = FrameTimer.now()
        let empty = SKTexture()
        placeholder = Sprite(tex: empty, rx: 0, ry: 0, rw: 1, rh: 1, sheet: -1)
        guard let url = Bundle.main.url(forResource: "sheets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rootAny = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = rootAny as? [String: Any],
              let sheets = root["sheets"] as? [[String: Any]],
              let frames = root["frames"] as? [String: Any] else {
            AppLog.error("sheets.json missing or unreadable")
            return
        }
        let tJson = FrameTimer.now()
        for sh in sheets {
            let file = (sh["file"] as? String) ?? "missing.png"
            let base = file.hasSuffix(".png") ? String(file.dropLast(4)) : file
            var tex: SKTexture
            if Bundle.main.path(forResource: base, ofType: "png") != nil {
                // loose bundle PNG (not an asset catalog): decoded by SKTexture.preload behind the loading screen
                tex = SKTexture(imageNamed: base)
            } else {
                AppLog.error("sheet \(file) missing from the bundle")
                tex = SKTexture()
            }
            tex.filteringMode = .linear
            pages.append(tex)
            pageNames.append((sh["name"] as? String) ?? base)
            sizes.append(CGSize(width: SpriteSheets.number(sh["w"]), height: SpriteSheets.number(sh["h"])))
        }
        let tPages = FrameTimer.now()
        raw.reserveCapacity(frames.count)
        for (name, v) in frames {
            guard let arr = v as? [Any], arr.count >= 9 else { continue }
            raw[name] = arr.map { Int(SpriteSheets.number($0)) }
        }
        let t1 = FrameTimer.now()
        // RGBA8 once uploaded: on a device (unified memory) this counts toward the jetsam footprint even though the
        // simulator's phys_footprint stops showing it after the upload (the textures live in the host GPU process)
        let texMB = sizes.reduce(0) { $0 + Int($1.width) * Int($1.height) * 4 } / 1_048_576
        AppLog.info(String(format: "sheets.json %.0f ms, page textures %.0f ms, frame index %.0f ms, sheet textures %d MB decoded",
                           (tJson - t0) * 1000, (tPages - tJson) * 1000, (t1 - tPages) * 1000, texMB))
    }

    private var sizes: [CGSize] = []

    private static func number(_ v: Any?) -> CGFloat {
        if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
        if let d = v as? Double { return CGFloat(d) }
        if let i = v as? Int { return CGFloat(i) }
        return 0
    }

    var frameCount: Int { raw.count }

    func has(_ name: String) -> Bool { raw[name] != nil }

    /// The packed frame `name` (created on first use, then cached). Missing frames log once and draw nothing.
    func sprite(_ name: String) -> Sprite {
        if let s = cache[name] { return s }
        guard let f = raw[name], f[0] >= 0, f[0] < pages.count else {
            if missingLogged < 12 {
                missingLogged += 1
                AppLog.error("sheets: missing frame \(name)")
            }
            return placeholder
        }
        let page = f[0]
        let W = sizes[page].width, H = sizes[page].height
        let x = CGFloat(f[1]), y = CGFloat(f[2]), w = CGFloat(f[3]), h = CGFloat(f[4])
        let ox = CGFloat(f[5]), oy = CGFloat(f[6]), fw = CGFloat(max(1, f[7])), fh = CGFloat(max(1, f[8]))
        // sheet rows are top-down, SpriteKit texture space is bottom-up
        let rect = CGRect(x: x / W, y: 1 - (y + h) / H, width: w / W, height: h / H)
        let tex = SKTexture(rect: rect, in: pages[page])
        let s = Sprite(tex: tex, rx: ox / fw, ry: (fh - oy - h) / fh, rw: w / fw, rh: h / fh, sheet: page)
        cache[name] = s
        return s
    }

    /// Texture of an untrimmed frame (flat ground textures, particles: sized in metres by the caller).
    func texture(_ name: String) -> SKTexture { sprite(name).tex }

    /// Pixel size of sheet `i` (sheets.json), zero if absent.
    func pageSize(_ i: Int) -> CGSize { i >= 0 && i < sizes.count ? sizes[i] : .zero }

    /// Index of a sheet by name (bugs, squad, glow, level, fx), -1 if absent.
    func sheetIndex(_ name: String) -> Int { pageNames.firstIndex(of: name) ?? -1 }
}

/// Frames of one animated sprite set, [dir][frame], resolved up front (cheap sub-texture creation).
final class FrameSet {
    let info: SpriteSetInfo
    let frameCount: Int
    let hasGlow: Bool
    private var litTex: [Sprite] = []
    private var glowTex: [Sprite?] = []

    init(_ sheets: SpriteSheets, _ prefix: String, frames: Int, glow: Bool, info: SpriteSetInfo) {
        self.frameCount = frames
        self.info = info
        self.hasGlow = glow
        litTex.reserveCapacity(16 * frames)
        for d in 0..<16 {
            let dd = d < 10 ? "0\(d)" : "\(d)"
            for f in 0..<frames {
                let name = frames > 1 ? "\(prefix)_\(dd)_\(f)" : "\(prefix)_\(dd)"
                litTex.append(sheets.sprite(name))
                if glow { glowTex.append(sheets.has(name + "_g") ? sheets.sprite(name + "_g") : nil) }
            }
        }
    }

    @inline(__always) func tex(_ dir: Int, _ f: Int) -> Sprite { litTex[dir * frameCount + f] }

    @inline(__always) func glow(_ dir: Int, _ f: Int) -> Sprite? {
        if !hasGlow { return nil }
        return glowTex[dir * frameCount + f]
    }
}

// ================================================================
//  SPRITE ASSETS — the sheets + the frame tables the layers index
// ================================================================
final class SpriteAssets {
    let manifest: SpriteManifest
    let sheets: SpriteSheets

    // bugs, index = BugType.rawValue
    private(set) var bugWalk: [FrameSet] = []
    private(set) var bugClimb: [FrameSet] = []
    private(set) var bugCrest: [FrameSet] = []
    private(set) var bugShadow: [FrameSet] = []
    let bruteCharge: FrameSet
    let boomerSwell: FrameSet
    private(set) var corpseFrames: [[Sprite]] = []
    private(set) var corpseInfo: [SpriteSetInfo] = []
    /// Sprite scale baked into the bug frames (BUG_SPECS scale).
    let bugBakedScale: [Float] = BugType.allCases.map { $0.spec.scale }

    // marines, index = MarineClass.rawValue
    private(set) var marineRun: [FrameSet] = []
    private(set) var marineStrafe: [FrameSet] = []
    private(set) var marineIdle: [FrameSet] = []
    private(set) var marineDash: [FrameSet] = []
    private(set) var marineDowned: [FrameSet] = []

    init() {
        let t0 = FrameTimer.now()
        manifest = SpriteManifest()
        sheets = SpriteSheets()
        let S = sheets
        let tSheets = FrameTimer.now()
        bruteCharge = FrameSet(S, "brute_charge", frames: 4, glow: true, info: manifest.info("brute_charge"))
        boomerSwell = FrameSet(S, "boomer_swell", frames: 3, glow: true, info: manifest.info("boomer_swell"))
        for t in BugType.allCases {
            let id = t.id
            bugWalk.append(FrameSet(S, "\(id)_walk", frames: 8, glow: true, info: manifest.info("\(id)_walk")))
            bugClimb.append(FrameSet(S, "\(id)_climb", frames: 4, glow: true, info: manifest.info("\(id)_climb")))
            bugCrest.append(FrameSet(S, "\(id)_crest", frames: 2, glow: true, info: manifest.info("\(id)_crest")))
            bugShadow.append(FrameSet(S, "\(id)_shadow", frames: 1, glow: false, info: manifest.info("\(id)_shadow")))
            corpseInfo.append(manifest.info("corpse_\(id)"))
            corpseFrames.append((0..<6).map { S.sprite("\(id)_corpse_\($0)") })
        }
        for c in MarineClass.allCases {
            let id = c.id
            marineRun.append(FrameSet(S, "\(id)_run", frames: 8, glow: true, info: manifest.info("\(id)_run")))
            marineStrafe.append(FrameSet(S, "\(id)_strafe", frames: 4, glow: true, info: manifest.info("\(id)_strafe")))
            marineIdle.append(FrameSet(S, "\(id)_idle", frames: 1, glow: true, info: manifest.info("\(id)_idle")))
            marineDash.append(FrameSet(S, "\(id)_dash", frames: 1, glow: true, info: manifest.info("\(id)_dash")))
            marineDowned.append(FrameSet(S, "\(id)_downed", frames: 1, glow: true, info: manifest.info("\(id)_downed")))
        }
        let t1 = FrameTimer.now()
        AppLog.info("sheets: \(sheets.pages.count) pages (\(sheets.pageNames.joined(separator: ","))), \(sheets.frameCount) frames"
                    + String(format: "; index %.0f ms, frame tables %.0f ms", (tSheets - t0) * 1000, (t1 - tSheets) * 1000))
    }

    /// Corpse frame of a bug type (6 variants).
    @inline(__always) func corpse(_ t: Int, _ v: Int) -> Sprite { corpseFrames[t][v % 6] }

    /// Packed frame / untrimmed texture by name (frame names are unique across all sheets).
    @inline(__always) func sprite(_ name: String) -> Sprite { sheets.sprite(name) }
    @inline(__always) func texture(_ name: String) -> SKTexture { sheets.texture(name) }
    @inline(__always) func has(_ name: String) -> Bool { sheets.has(name) }
}
