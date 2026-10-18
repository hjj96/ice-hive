import SpriteKit
import UIKit

// ================================================================
//  GLYPH LABELS — the HUD's fast-changing numbers (kills, time, combo,
//  armour, level, marker distance, the debug panel) in JetBrains Mono
//  drawn from a glyph atlas rendered once. An SKLabelNode renders a
//  new text texture for every new string (the kill counter alone ten
//  times a second); a GlyphLabel only re-points a few sprites at atlas
//  cells. Same font, size, colour and placement as the SKLabelNode it
//  replaces: the vertical alignment and the width are calibrated
//  against an SKLabelNode with the same attributes.
// ================================================================

/// One monospace font at one size: every glyph of `charset` rendered white at the screen scale into one texture.
final class GlyphAtlas {
    let font: UIFont
    /// Pen advance per character (points; monospace).
    let advance: CGFloat
    /// Cell size (points) and where the baseline sits in a cell, from its bottom.
    let cell: CGSize
    let cellBaseline: CGFloat
    /// Left padding of a cell (the pen starts there).
    let pad: CGFloat
    /// Line height for multi-line text (points).
    let lineHeight: CGFloat
    /// Pixels per point of the glyph images.
    let scale: CGFloat
    /// Baseline offset from the node origin per vertical alignment, as SKLabelNode places it.
    private var baselines: [Int: CGFloat] = [:]
    /// SKLabelNode frame width ≈ widthBase + n × widthStep for n characters.
    let widthBase: CGFloat, widthStep: CGFloat
    private var glyphs: [Character: SKTexture] = [:]

    private static var cache: [String: GlyphAtlas] = [:]

    /// Shared atlas for `fontName` at `size` holding (at least) `charset`.
    static func shared(_ fontName: String, size: CGFloat, charset: String) -> GlyphAtlas {
        let key = "\(fontName)|\(size)|\(charset)"
        if let a = cache[key] { return a }
        let a = GlyphAtlas(fontName, size: size, charset: charset)
        cache[key] = a
        return a
    }

    private init(_ fontName: String, size: CGFloat, charset: String) {
        let f = Fonts.font(fontName, size)
        font = f
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: UIColor.white, .kern: CGFloat(0)]
        advance = NSAttributedString(string: "0", attributes: attrs).size().width
        pad = (size * 0.25).rounded(.up)
        let asc = f.ascender, desc = f.descender   // descender < 0
        cell = CGSize(width: (advance + 2 * pad).rounded(.up), height: (asc - desc + 2 * pad).rounded(.up))
        // the glyph is drawn from the cell's top (pad + ascender down to the baseline); the height's rounding lands
        // below the descender
        cellBaseline = cell.height - pad - asc
        lineHeight = f.lineHeight
        scale = UIScreen.main.nativeScale
        // calibration against SpriteKit's own label: where its baseline sits for each vertical alignment, and its width
        func frame(_ text: String, _ v: SKLabelVerticalAlignmentMode) -> CGRect {
            let l = SKLabelNode()
            l.horizontalAlignmentMode = .left
            l.verticalAlignmentMode = v
            l.attributedText = NSAttributedString(string: text, attributes: attrs)
            return l.frame
        }
        let base = frame("0", .baseline)
        for v in [SKLabelVerticalAlignmentMode.baseline, .center, .top, .bottom] {
            baselines[v.rawValue] = v == .baseline ? 0 : frame("0", v).minY - base.minY
        }
        let w2 = frame("00", .baseline).width
        widthStep = w2 - base.width > 0 ? w2 - base.width : advance
        widthBase = base.width - widthStep
        // the atlas: a grid of cells, 16 to a row
        let chars = Array(Set(charset)).filter { $0 != " " && $0 != "\n" }
        let cols = max(1, min(16, chars.count)), rows = max(1, (chars.count + cols - 1) / cols)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        let total = CGSize(width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))
        let cw = cell.width, ch = cell.height, p = pad
        let image = UIGraphicsImageRenderer(size: total, format: fmt).image { _ in
            for (k, c) in chars.enumerated() {
                // draw(at:) puts the line's top (ascender) at the point: the baseline lands at pad + ascender in the cell
                NSAttributedString(string: String(c), attributes: attrs)
                    .draw(at: CGPoint(x: CGFloat(k % cols) * cw + p, y: CGFloat(k / cols) * ch + p))
            }
        }
        let tex = SKTexture(image: image)
        for (k, c) in chars.enumerated() {
            // texture space has its origin at the bottom left
            let r = CGFloat(k / cols)
            glyphs[c] = SKTexture(rect: CGRect(x: CGFloat(k % cols) * cw / total.width, y: 1 - (r + 1) * ch / total.height,
                                               width: cw / total.width, height: ch / total.height), in: tex)
        }
    }

    func glyph(_ c: Character) -> SKTexture? { glyphs[c] }

    func baseline(_ v: SKLabelVerticalAlignmentMode) -> CGFloat { baselines[v.rawValue] ?? 0 }
}

/// Drop-in for `Label` (same `node` / `set` / `color` / `width`) for monospace text without letter spacing.
final class GlyphLabel {
    let node = SKNode()
    private let atlas: GlyphAtlas
    private let align: SKLabelHorizontalAlignmentMode
    private let valign: SKLabelVerticalAlignmentMode
    private var sprites: [SKSpriteNode] = []
    private(set) var text = ""
    var color: SKColor { didSet { if !color.isEqual(oldValue) { for s in sprites { s.color = color } } } }

    static let digits = "0123456789"
    /// The debug panel: ASCII and Cyrillic.
    static let debugCharset: String = {
        var s = ""
        for u in 33...126 { s.unicodeScalars.append(Unicode.Scalar(u)!) }
        for u in 0x410...0x44f { s.unicodeScalars.append(Unicode.Scalar(u)!) }
        return s + "ёЁ×·"
    }()

    init(_ text: String, font: String, size: CGFloat, color: SKColor, charset: String,
         align: SKLabelHorizontalAlignmentMode = .center, valign: SKLabelVerticalAlignmentMode = .center) {
        atlas = GlyphAtlas.shared(font, size: size, charset: charset)
        self.color = color
        self.align = align
        self.valign = valign
        set(text, force: true)
    }

    func set(_ t: String, force: Bool = false) {
        if t == text && !force { return }
        text = t
        layout()
    }

    /// What SKLabelNode.frame.width would be for this text (widest line).
    var width: CGFloat {
        var n = 0, cur = 0
        for c in text { if c == "\n" { cur = 0 } else { cur += 1; n = max(n, cur) } }
        return n == 0 ? 0 : atlas.widthBase + CGFloat(n) * atlas.widthStep
    }

    private func layout() {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let n = lines.count
        // the block's baseline for one line, then each further line one line height lower (top / centre / bottom
        // alignment move the whole block like a multi-line SKLabelNode)
        var y0 = atlas.baseline(valign)
        if n > 1 {
            let extra = CGFloat(n - 1) * atlas.lineHeight
            switch valign {
            case .bottom: y0 += extra
            case .center: y0 += extra / 2
            default: break
            }
        }
        var used = 0
        for (li, line) in lines.enumerated() {
            let count = CGFloat(line.count)
            let w = count * atlas.advance
            var x: CGFloat
            switch align {
            case .left: x = 0
            case .right: x = -w
            default: x = -w / 2
            }
            let y = y0 - CGFloat(li) * atlas.lineHeight
            for c in line {
                if let g = atlas.glyph(c) {
                    let s: SKSpriteNode
                    if used < sprites.count {
                        s = sprites[used]
                        s.texture = g
                        s.isHidden = false
                    } else {
                        s = SKSpriteNode(texture: g, size: atlas.cell)
                        s.anchorPoint = .zero
                        s.color = color
                        s.colorBlendFactor = 1
                        sprites.append(s)
                        node.addChild(s)
                    }
                    // on the pixel grid (the glyph images were rasterised on it)
                    s.position = CGPoint(x: ((x - atlas.pad) * atlas.scale).rounded() / atlas.scale,
                                         y: ((y - atlas.cellBaseline) * atlas.scale).rounded() / atlas.scale)
                    used += 1
                }
                x += atlas.advance
            }
        }
        for k in used..<sprites.count { sprites[k].isHidden = true }
    }
}
