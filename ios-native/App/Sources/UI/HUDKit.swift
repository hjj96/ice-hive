import SpriteKit
import UIKit

// ================================================================
//  HUD KIT — the web game's CSS palette, fonts and small building
//  blocks (letter-spaced labels, bars, cut-corner panels).
// ================================================================
enum UIPalette {
    static func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat) -> SKColor {
        SKColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    static let ink = Tone.hex(0xdbe6ee)
    static let inkDim = Tone.hex(0x8b9cab)
    static let inkFaint = Tone.hex(0x4b5a68)
    static let teal = Tone.hex(0x3fe3d2)
    static let amber = Tone.hex(0xffb420)
    static let amberDim = Tone.hex(0x6b4a0d)
    static let red = Tone.hex(0xff3b3b)
    static let hp = Tone.hex(0xe8352e)
    static let hpBg = rgba(48, 10, 10, 0.75)
    static let panel = rgba(7, 11, 16, 0.86)
    static let panel2 = rgba(13, 20, 28, 0.94)
    static let line = rgba(120, 170, 190, 0.22)
    static let lineStrong = rgba(110, 215, 210, 0.55)
    static let tealTrack = rgba(63, 227, 210, 0.12)
    static let amberTrack = rgba(255, 180, 32, 0.15)
    static let white = SKColor.white
    static let black = SKColor.black
    static let stickRing = rgba(219, 230, 238, 0.28)
    static let stickFill = rgba(219, 230, 238, 0.05)
    static let knobFill = rgba(219, 230, 238, 0.22)
    static let knobRing = rgba(219, 230, 238, 0.65)
    static let fireRing = rgba(255, 75, 62, 0.4)
    static let fireKnobRing = rgba(255, 110, 90, 0.85)
    static let fireKnobFill = rgba(255, 75, 62, 0.22)
    static let bannerRed = rgba(30, 0, 0, 0.55)
    static let bannerTeal = rgba(0, 25, 25, 0.55)
    static let bg = Tone.hex(0x05070a)
    // v1.1 (web head.html regions A / C / D)
    static let tealDim = Tone.hex(0x135c57)
    static let redDim = Tone.hex(0x5c1515)
    static let cardSel = rgba(20, 30, 40, 0.96)
    /// The Матка's violet (--thr-queen) and its bar track.
    static let queen = Tone.hex(0xb866ff)
    static let queenTrack = rgba(184, 102, 255, 0.16)
    /// The converging objective box (--thr-red-bg).
    static let redPanel = rgba(40, 5, 7, 0.9)
    /// Class colours (--c-assault …), index = MarineClass.rawValue.
    static let classColors: [SKColor] = [Tone.hex(0xff4b3e), Tone.hex(0xffb42a), Tone.hex(0x4cc9ff), Tone.hex(0x62ff70)]
}

enum Fonts {
    static let regular = "Oswald-Regular"
    static let medium = "Oswald-Medium"
    static let semibold = "Oswald-SemiBold"
    static let bold = "Oswald-Bold"
    static let mono = "JetBrainsMono-Medium"
    static let monoBold = "JetBrainsMono-Bold"

    static func font(_ name: String, _ size: CGFloat) -> UIFont {
        if let f = UIFont(name: name, size: size) { return f }
        return UIFont.systemFont(ofSize: size, weight: name.contains("Bold") ? .bold : .medium)
    }

    static func logAvailability() {
        let names = [regular, medium, semibold, bold, mono, monoBold]
        let missing = names.filter { UIFont(name: $0, size: 12) == nil }
        if missing.isEmpty { AppLog.info("fonts: Oswald + JetBrains Mono registered") } else { AppLog.error("fonts missing: \(missing.joined(separator: ","))") }
    }
}

/// Label texts set since launch (each one makes SpriteKit render a new text texture). FrameLoop reads it around
/// SKRenderer.render: CI attributes slow HUD renders to text changes (or not).
enum LabelStats {
    static var textsSet = 0
}

/// SKLabelNode with letter spacing (attributed text), re-built only when the text changes.
final class Label {
    let node = SKLabelNode()
    private(set) var text = ""
    // every rebuild renders a new text texture: only when something actually changed
    var font: String { didSet { if font != oldValue { rebuild() } } }
    var size: CGFloat { didSet { if size != oldValue { rebuild() } } }
    var color: SKColor { didSet { if !color.isEqual(oldValue) { rebuild() } } }
    var kern: CGFloat
    var stroke: SKColor? = nil

    init(_ text: String, font: String, size: CGFloat, color: SKColor, kern: CGFloat = 0,
         align: SKLabelHorizontalAlignmentMode = .center, valign: SKLabelVerticalAlignmentMode = .center) {
        self.font = font
        self.size = size
        self.color = color
        self.kern = kern
        node.horizontalAlignmentMode = align
        node.verticalAlignmentMode = valign
        set(text, force: true)
    }

    func set(_ t: String, force: Bool = false) {
        if t == text && !force { return }
        text = t
        rebuild()
    }

    private func rebuild() {
        var attrs: [NSAttributedString.Key: Any] = [.font: Fonts.font(font, size), .foregroundColor: color, .kern: kern]
        if let s = stroke {
            attrs[.strokeColor] = s
            attrs[.strokeWidth] = 3.0
            attrs[.foregroundColor] = SKColor.clear
        }
        node.attributedText = NSAttributedString(string: text, attributes: attrs)
        LabelStats.textsSet += 1
    }

    /// Width of the rendered text (points).
    var width: CGFloat { node.frame.width }
}

/// Horizontal bar: track + fill (+ optional top line), anchored at its left-centre.
final class Bar {
    let node = SKNode()
    let track: SKSpriteNode
    let fill: SKSpriteNode
    private var topLine: SKSpriteNode?
    private(set) var width: CGFloat
    private var value: CGFloat = -1

    init(width: CGFloat, height: CGFloat, fill fillColor: SKColor, track trackColor: SKColor, topLine: SKColor? = nil, topHeight: CGFloat = 1) {
        self.width = width
        track = SKSpriteNode(color: trackColor, size: CGSize(width: width, height: height))
        track.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill = SKSpriteNode(color: fillColor, size: CGSize(width: width, height: height))
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        node.addChild(track)
        node.addChild(fill)
        if let tl = topLine {
            let l = SKSpriteNode(color: tl, size: CGSize(width: width, height: topHeight))
            l.anchorPoint = CGPoint(x: 0, y: 0.5)
            l.position = CGPoint(x: 0, y: height / 2 + topHeight / 2)
            node.addChild(l)
            self.topLine = l
        }
    }

    func set(_ f: CGFloat) {
        let v = max(0, min(1, f.isFinite ? f : 0))
        if abs(v - value) < 0.002 { return }
        value = v
        fill.xScale = max(0.0001, v)
    }

    /// Recolour (the objective bar's threat variants); `texture` = a horizontal gradient for the fill (nil = flat colour).
    func style(fill c: SKColor, track t: SKColor, texture: SKTexture? = nil) {
        fill.texture = texture
        fill.color = texture == nil ? c : .white
        fill.colorBlendFactor = texture == nil ? 1 : 0
        track.color = t
    }

    func resize(width w: CGFloat) {
        width = w
        // SKSpriteNode.size is the *scaled* size: reset the scale first or the base width becomes w / xScale
        track.size.width = w
        fill.xScale = 1
        fill.size = CGSize(width: w, height: fill.size.height)
        topLine?.size.width = w
        let v = value
        value = -1
        set(v < 0 ? 0 : v)
    }
}

/// Dotted ammo / heat bar of the player's nameplate (web .ps: 4 pt on / 2 pt off, clipped from the right by the value).
final class DashBar {
    let node = SKNode()
    private var segs: [SKSpriteNode] = []
    private let width: CGFloat
    private let height: CGFloat
    private var value: CGFloat = -1

    init(width: CGFloat, height: CGFloat, color: SKColor) {
        self.width = width
        self.height = height
        var x: CGFloat = 0
        while x < width {
            let s = SKSpriteNode(color: color, size: CGSize(width: 4, height: height))
            s.anchorPoint = CGPoint(x: 0, y: 0.5)
            s.position = CGPoint(x: x, y: 0)
            node.addChild(s)
            segs.append(s)
            x += 6
        }
    }

    func set(_ f: CGFloat) {
        let v = max(0, min(1, f.isFinite ? f : 0))
        if abs(v - value) < 0.005 { return }
        value = v
        let c = v * width
        for (k, s) in segs.enumerated() {
            let x0 = CGFloat(k) * 6
            let w = min(4, c - x0)
            if w <= 0.05 {
                if !s.isHidden { s.isHidden = true }
            } else {
                if s.isHidden { s.isHidden = false }
                s.size = CGSize(width: w, height: height)
            }
        }
    }
}

enum Shapes {
    private static var panelCache: [String: SKTexture] = [:]
    /// Memory warning: textures on screen stay alive through their nodes; the cache only re-renders the rest on demand.
    static func clearCache() { panelCache.removeAll() }

    private static func key(_ c: SKColor?) -> String {
        guard let c = c else { return "-" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        _ = c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f,%.3f,%.3f,%.3f", r, g, b, a)
    }

    /// Cut-corner panel as a textured sprite (anchor top-left, like the CSS box): one draw, cached per look.
    static func panel(width w0: CGFloat, height h0: CGFloat, cut c: CGFloat = 7, fill: SKColor = UIPalette.panel,
                      stroke: SKColor? = nil, lineWidth lw: CGFloat = 1) -> SKSpriteNode {
        let w = max(2, w0.rounded()), h = max(2, h0.rounded())
        let k = "\(Int(w))x\(Int(h))c\(Int(c))f" + key(fill) + "s" + key(stroke) + "l\(Int(lw * 10))"
        let tex: SKTexture
        if let t = panelCache[k] {
            tex = t
        } else {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
            let image = renderer.image { ctx in
                let cg = ctx.cgContext
                func outline(_ i: CGFloat) -> CGPath {
                    let p = CGMutablePath()
                    p.move(to: CGPoint(x: i, y: i))
                    p.addLine(to: CGPoint(x: w - c - i * 0.4, y: i))
                    p.addLine(to: CGPoint(x: w - i, y: c + i * 0.4))
                    p.addLine(to: CGPoint(x: w - i, y: h - i))
                    p.addLine(to: CGPoint(x: c + i * 0.4, y: h - i))
                    p.addLine(to: CGPoint(x: i, y: h - c - i * 0.4))
                    p.closeSubpath()
                    return p
                }
                cg.addPath(outline(0))
                cg.setFillColor(fill.cgColor)
                cg.fillPath()
                if let s = stroke {
                    cg.addPath(outline(lw / 2))
                    cg.setStrokeColor(s.cgColor)
                    cg.setLineWidth(lw)
                    cg.strokePath()
                }
            }
            tex = SKTexture(image: image)
            panelCache[k] = tex
        }
        let n = SKSpriteNode(texture: tex)
        n.size = CGSize(width: w, height: h)
        n.anchorPoint = CGPoint(x: 0, y: 1)
        return n
    }

    /// Filled + stroked circle as a cached texture (diameter 2r + stroke).
    static func circle(radius r: CGFloat, fill: SKColor, stroke: SKColor?, lineWidth lw: CGFloat = 2) -> SKSpriteNode {
        let side = (r * 2 + lw).rounded(.up)
        let k = "circle\(Int(r * 10))f" + key(fill) + "s" + key(stroke) + "l\(Int(lw * 10))"
        let tex: SKTexture
        if let t = panelCache[k] {
            tex = t
        } else {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
            let image = renderer.image { ctx in
                let cg = ctx.cgContext
                let rect = CGRect(x: lw / 2, y: lw / 2, width: side - lw, height: side - lw)
                cg.setFillColor(fill.cgColor)
                cg.fillEllipse(in: rect)
                if let s = stroke {
                    cg.setStrokeColor(s.cgColor)
                    cg.setLineWidth(lw)
                    cg.strokeEllipse(in: rect)
                }
            }
            tex = SKTexture(image: image)
            panelCache[k] = tex
        }
        let n = SKSpriteNode(texture: tex)
        n.size = CGSize(width: side, height: side)
        return n
    }

    /// Cooldown sweep resolution (7.5° steps).
    static let pieSteps = 48

    /// Pre-rendered cooldown pies, sweep from 12 o'clock clockwise: element k covers (k + 1) / pieSteps.
    /// Rendered once per radius at start-up (the HUD buttons only swap textures while abilities cool down).
    static func pies(radius r: CGFloat, color: SKColor) -> [SKTexture] {
        let side = (r * 2).rounded(.up)
        var out: [SKTexture] = []
        out.reserveCapacity(pieSteps)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        for k in 1...pieSteps {
            let f = CGFloat(k) / CGFloat(pieSteps)
            let image = renderer.image { ctx in
                let cg = ctx.cgContext
                let c = CGPoint(x: side / 2, y: side / 2)
                let p = CGMutablePath()
                p.move(to: c)
                // UIKit y points down: clockwise on screen from 12 o'clock = increasing angle from −π/2
                let start = -CGFloat.pi / 2
                p.addArc(center: c, radius: r, startAngle: start, endAngle: start + 2 * .pi * f, clockwise: false)
                p.closeSubpath()
                cg.addPath(p)
                cg.setFillColor(color.cgColor)
                cg.fillPath()
            }
            out.append(SKTexture(image: image))
        }
        return out
    }

    /// A plain panel of any width from one texture per height: the `baseWidth` panel stretched across its uniform
    /// middle with a nine-part centerRect (the cut corners keep their pixels, the middle columns are all the same), so
    /// a panel that follows a growing number gets no new texture per width. Same image as panel(width:height:).
    static func stretchedPanel(width w0: CGFloat, height h: CGFloat, baseWidth: CGFloat, cut c: CGFloat = 7, fill: SKColor = UIPalette.panel,
                               stroke: SKColor? = nil, lineWidth lw: CGFloat = 1) -> SKSpriteNode {
        let w = max(2, w0.rounded()), bw = max(2, min(baseWidth.rounded(), w))
        let n = panel(width: bw, height: h, cut: c, fill: fill, stroke: stroke, lineWidth: lw)
        let edge = c + 2 + (stroke == nil ? 0 : lw)
        guard w > bw, bw > 2 * edge else { return bw == w ? n : panel(width: w, height: h, cut: c, fill: fill, stroke: stroke, lineWidth: lw) }
        n.centerRect = CGRect(x: edge / bw, y: 0, width: (bw - 2 * edge) / bw, height: 1)
        n.xScale = w / bw
        return n
    }

    /// Ring with a soft glow (coach target pulse on a round button: `inner` glow toward the centre; around the
    /// objective marker: outward), cached per look.
    static func glowRing(radius r: CGFloat, color: SKColor, lineWidth lw: CGFloat = 3, glow: CGFloat = 14, inner: Bool) -> SKTexture {
        let k = "ring\(Int(r * 10))" + key(color) + "l\(Int(lw * 10))g\(Int(glow))" + (inner ? "i" : "o")
        if let t = panelCache[k] { return t }
        let side = ((r + (inner ? 0 : glow)) * 2 + lw).rounded(.up)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let c = CGPoint(x: side / 2, y: side / 2)
            let steps = 7
            for i in stride(from: steps, through: 1, by: -1) {
                let d = glow * CGFloat(i) / CGFloat(steps)
                let rr = inner ? r - lw / 2 - d : r + lw / 2 + d
                if rr <= 1 { continue }
                cg.setStrokeColor(color.withAlphaComponent(0.22 * (1 - CGFloat(i) / CGFloat(steps + 1))).cgColor)
                cg.setLineWidth(glow / CGFloat(steps) + 1)
                cg.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            }
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(lw)
            let rr = r - lw / 2
            cg.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        }
        let t = SKTexture(image: image)
        panelCache[k] = t
        return t
    }

    /// The coach's ghost thumb (web #ghost::after): a 44 pt disc, white 22 %, 2 pt white 75 % ring, soft white glow.
    static func ghostThumb() -> SKTexture {
        let k = "ghostThumb"
        if let t = panelCache[k] { return t }
        let r: CGFloat = 22, glow: CGFloat = 18
        let side = (r + glow) * 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let c = CGPoint(x: side / 2, y: side / 2)
            for i in stride(from: 9, through: 1, by: -1) {
                let rr = r + glow * CGFloat(i) / 9
                cg.setFillColor(UIColor(white: 1, alpha: 0.035 * (1 - CGFloat(i) / 10)).cgColor)
                cg.fillEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            }
            let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            cg.setFillColor(UIColor(white: 1, alpha: 0.22).cgColor)
            cg.fillEllipse(in: disc)
            cg.setStrokeColor(UIColor(white: 1, alpha: 0.75).cgColor)
            cg.setLineWidth(2)
            cg.strokeEllipse(in: disc.insetBy(dx: 1, dy: 1))
        }
        let t = SKTexture(image: image)
        panelCache[k] = t
        return t
    }

    /// Horizontal two-colour gradient (the Матка's bar: violet → red), 64 × 4 px, stretched by the bar.
    static func hGradient(_ a: SKColor, _ b: SKColor) -> SKTexture {
        let k = "grad" + key(a) + key(b)
        if let t = panelCache[k] { return t }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 4))
        let image = renderer.image { ctx in
            let colors = [a.cgColor, b.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 64, y: 0), options: [])
            }
        }
        let t = SKTexture(image: image)
        panelCache[k] = t
        return t
    }

    /// Objective marker chevron (points up), amber stroke with a soft glow, as one cached texture.
    static func chevron(color: SKColor) -> SKTexture {
        let w: CGFloat = 26, h: CGFloat = 20
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let p = CGMutablePath()
            p.move(to: CGPoint(x: w / 2 - 7, y: h / 2 + 5))
            p.addLine(to: CGPoint(x: w / 2, y: h / 2 - 4))
            p.addLine(to: CGPoint(x: w / 2 + 7, y: h / 2 + 5))
            for (lw, a) in [(CGFloat(7), CGFloat(0.18)), (CGFloat(5), CGFloat(0.3)), (CGFloat(3), CGFloat(1))] {
                cg.addPath(p)
                cg.setStrokeColor(color.withAlphaComponent(a).cgColor)
                cg.setLineWidth(lw)
                cg.strokePath()
            }
        }
        return SKTexture(image: image)
    }
}

enum GeneratedTextures {
    /// Renderer for smooth, blurred full-screen gradients: 1× scale and the standard 8-bit range (a 256-pt texture
    /// at 3× with an extended-range format would be 768² × 8 bytes for a soft vignette).
    private static func lowResRenderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: f)
    }

    /// Radial vignette: transparent centre → `edge` colour at the corners.
    static func vignette(edge: UIColor, inner: CGFloat = 0.35) -> SKTexture {
        let side: CGFloat = 256
        let renderer = lowResRenderer(CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [edge.withAlphaComponent(0).cgColor, edge.cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [inner, 1.0]) {
                let c = CGPoint(x: side / 2, y: side / 2)
                cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: side * 0.72, options: [.drawsAfterEndLocation])
            }
        }
        return SKTexture(image: image)
    }

    private static var hazardCache: [String: SKTexture] = [:]
    static func clearCache() { hazardCache.removeAll() }

    /// Amber / black hazard stripes (CSS --hazard), width × height points; `cutRight` clips the right end at 45°
    /// like the web .hz band. Cached per size (layout runs on every rotation / safe-area change).
    static func hazard(width w0: CGFloat, height: CGFloat, cutRight: Bool = false) -> SKTexture {
        let width = max(2, w0.rounded())
        let key = "\(Int(width))x\(Int(height * 10))" + (cutRight ? "c" : "")
        if let t = hazardCache[key] { return t }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            if cutRight {
                let clip = CGMutablePath()
                clip.move(to: CGPoint(x: 0, y: 0))
                clip.addLine(to: CGPoint(x: width, y: 0))
                clip.addLine(to: CGPoint(x: width - height, y: height))
                clip.addLine(to: CGPoint(x: 0, y: height))
                clip.closeSubpath()
                cg.addPath(clip)
                cg.clip()
            }
            cg.setFillColor(UIPalette.bg.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            cg.setFillColor(UIPalette.amber.cgColor)
            var x: CGFloat = -height
            while x < width + height {
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x, y: height))
                p.addLine(to: CGPoint(x: x + 9, y: height))
                p.addLine(to: CGPoint(x: x + 9 + height, y: 0))
                p.addLine(to: CGPoint(x: x + height, y: 0))
                p.closeSubpath()
                cg.addPath(p)
                cg.fillPath()
                x += 18
            }
        }
        let t = SKTexture(image: image)
        hazardCache[key] = t
        return t
    }

    /// Soft disc (stick fills).
    static func disc(radius: CGFloat, color: UIColor) -> SKTexture {
        let side = radius * 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [color.cgColor, color.withAlphaComponent(0.3).cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0]) {
                let c = CGPoint(x: radius, y: radius)
                cg.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
                cg.clip()
                cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
            }
        }
        return SKTexture(image: image)
    }
}

/// Memory warning: drop the HUD's rebuildable texture caches.
enum HUDKitCaches {
    static func clear() {
        Shapes.clearCache()
        GeneratedTextures.clearCache()
    }
}
