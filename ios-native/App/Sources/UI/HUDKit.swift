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
    static let redDim = Tone.hex(0x5c1515)
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

/// SKLabelNode with letter spacing (attributed text), re-built only when the text changes.
final class Label {
    let node = SKLabelNode()
    private(set) var text = ""
    var font: String { didSet { rebuild() } }
    var size: CGFloat { didSet { rebuild() } }
    var color: SKColor { didSet { rebuild() } }
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
    }

    /// Width of the rendered text (points).
    var width: CGFloat { node.frame.width }
}

/// Horizontal bar: track + fill (+ optional top line), anchored at its left-centre.
final class Bar {
    let node = SKNode()
    private let track: SKSpriteNode
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

enum Shapes {
    /// CSS clip-path --cut-s: top-left origin, extends right / down (y negative).
    static func cutPanel(width w: CGFloat, height h: CGFloat, cut c: CGFloat = 7) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: w - c, y: 0))
        p.addLine(to: CGPoint(x: w, y: -c))
        p.addLine(to: CGPoint(x: w, y: -h))
        p.addLine(to: CGPoint(x: c, y: -h))
        p.addLine(to: CGPoint(x: 0, y: -h + c))
        p.closeSubpath()
        return p
    }

    private static var panelCache: [String: SKTexture] = [:]

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

    /// Pie (cooldown sweep) from 12 o'clock clockwise, fraction 0…1.
    static func pie(radius r: CGFloat, fraction f: CGFloat) -> CGPath {
        let p = CGMutablePath()
        if f <= 0.001 { return p }
        p.move(to: .zero)
        let start = CGFloat.pi / 2
        p.addArc(center: .zero, radius: r, startAngle: start, endAngle: start - 2 * .pi * min(1, f), clockwise: true)
        p.closeSubpath()
        return p
    }
}

enum GeneratedTextures {
    /// Radial vignette: transparent centre → `edge` colour at the corners.
    static func vignette(edge: UIColor, inner: CGFloat = 0.35) -> SKTexture {
        let side: CGFloat = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
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

    /// Amber / black hazard stripes (CSS --hazard), width × height points.
    static func hazard(width: CGFloat, height: CGFloat) -> SKTexture {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
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
        return SKTexture(image: image)
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
