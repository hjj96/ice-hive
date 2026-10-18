import Metal
import SpriteKit
import UIKit

// ================================================================
//  GLYPH LABELS — the HUD's fast-changing numbers (kills, time, combo,
//  armour, level, marker distance, the debug panel) in JetBrains Mono
//  drawn from a glyph atlas rendered once. An SKLabelNode renders a
//  new text texture for every new string (the kill counter alone ten
//  times a second); a GlyphLabel only re-points a few sprites at atlas
//  cells. Same font, size, colour and placement as the SKLabelNode it
//  replaces: the vertical alignment and the width follow an SKLabelNode
//  with the same attributes, and where SpriteKit really draws its text
//  is measured once at launch (GlyphCalibration) and applied.
// ================================================================

/// One monospace font at one size: every glyph of `charset` rendered white at the screen scale into one texture.
final class GlyphAtlas {
    let font: UIFont
    let fontName: String, size: CGFloat, charset: String
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
        self.fontName = fontName
        self.size = size
        self.charset = charset
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
    let atlas: GlyphAtlas
    let align: SKLabelHorizontalAlignmentMode
    let valign: SKLabelVerticalAlignmentMode
    /// Shows two or more lines (calibrated as a multi-line SKLabelNode, numberOfLines = 0).
    let multiline: Bool
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
         align: SKLabelHorizontalAlignmentMode = .center, valign: SKLabelVerticalAlignmentMode = .center,
         multiline: Bool = false, register: Bool = true) {
        atlas = GlyphAtlas.shared(font, size: size, charset: charset)
        self.color = color
        self.align = align
        self.valign = valign
        self.multiline = multiline
        set(text, force: true)
        if register { GlyphCalibration.register(self) }
    }

    /// Calibration key: labels sharing it are placed alike.
    var config: GlyphCalibration.Config {
        GlyphCalibration.Config(atlas: ObjectIdentifier(atlas), align: align.rawValue, valign: valign.rawValue, multiline: multiline)
    }

    /// Lay the text out again (after the calibration).
    func relayout() { layout() }

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
        // where SpriteKit's own label would put the same text, relative to this layout (zero before / without calibration)
        let off = GlyphCalibration.offsets[config] ?? .zero
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
            x += off.x
            let y = y0 - CGFloat(li) * atlas.lineHeight + off.y
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

/// Where SpriteKit draws a label's text versus where a GlyphLabel draws the same text, measured once at launch: for
/// every label configuration in use (atlas, alignment, one or more lines) a reference SKLabelNode and a GlyphLabel with
/// the same sample text are rendered side by side offscreen through SKRenderer at the screen scale, read back, and the
/// difference of their ink boxes (whole pixels) becomes the label's offset. So the HUD numbers sit exactly where their
/// SKLabelNodes did, whatever SpriteKit's internal text padding is. Without a run (no Metal) the offsets stay zero.
enum GlyphCalibration {
    struct Config: Hashable {
        let atlas: ObjectIdentifier
        let align: Int
        let valign: Int
        let multiline: Bool
    }

    /// Offset (points) added to a GlyphLabel's layout, per configuration.
    private(set) static var offsets: [Config: CGPoint] = [:]

    private final class Weak { weak var label: GlyphLabel?; init(_ l: GlyphLabel) { label = l } }
    private static var labels: [Weak] = []

    static func register(_ l: GlyphLabel) {
        labels.removeAll { $0.label == nil }
        labels.append(Weak(l))
    }

    /// Measure every configuration in use, then lay every label out again. Synchronous (one small offscreen render);
    /// call once before the first frame. Returns a log line.
    static func run(device: MTLDevice, queue: MTLCommandQueue) -> String {
        let t0 = FrameTimer.now()
        var configs: [(Config, GlyphLabel)] = []
        for w in labels {
            guard let l = w.label, !configs.contains(where: { $0.0 == l.config }) else { continue }
            configs.append((l.config, l))
        }
        if configs.isEmpty { return "glyph calibration: no labels" }
        let scale = UIScreen.main.nativeScale
        // one slot per configuration (bottom to top), the SpriteKit label in the left column, the GlyphLabel right
        let colW: CGFloat = 180, slotH: CGFloat = 48
        let W = colW * 2, H = slotH * CGFloat(configs.count)
        let pw = Int((W * scale).rounded()), ph = Int((H * scale).rounded())
        let scene = SKScene(size: CGSize(width: W, height: H))
        scene.anchorPoint = .zero
        scene.scaleMode = .fill
        scene.backgroundColor = .clear
        for (k, (cfg, l)) in configs.enumerated() {
            let a = l.atlas
            let sample = cfg.multiline ? "0123 45\n6789" : GlyphLabel.digits
            let x: CGFloat = l.align == .left ? 12 : (l.align == .right ? colW - 12 : colW / 2)
            let y: CGFloat
            switch l.valign {
            case .bottom: y = CGFloat(k) * slotH + 8
            case .top: y = CGFloat(k + 1) * slotH - 8
            case .baseline: y = CGFloat(k) * slotH + 16
            default: y = CGFloat(k) * slotH + slotH / 2
            }
            let ref = SKLabelNode()
            ref.horizontalAlignmentMode = l.align
            ref.verticalAlignmentMode = l.valign
            if cfg.multiline { ref.numberOfLines = 0 }
            ref.attributedText = NSAttributedString(string: sample, attributes: [.font: a.font, .foregroundColor: UIColor.white, .kern: CGFloat(0)])
            ref.position = CGPoint(x: x, y: y)
            scene.addChild(ref)
            let twin = GlyphLabel(sample, font: a.fontName, size: a.size, color: .white, charset: a.charset, align: l.align,
                                  valign: l.valign, multiline: cfg.multiline, register: false)
            twin.node.position = CGPoint(x: colW + x, y: y)
            scene.addChild(twin.node)
        }
        // render, then copy to a buffer the CPU can read (the simulator has no shared-storage textures)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pw, height: ph, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .private
        let bpr = (pw * 4 + 255) & ~255
        guard let tex = device.makeTexture(descriptor: td), let buf = device.makeBuffer(length: bpr * ph, options: [.storageModeShared]),
              let cb = queue.makeCommandBuffer() else { return "glyph calibration: no texture / buffer" }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let r = SKRenderer(device: device)
        r.scene = scene
        r.update(atTime: CACurrentMediaTime())
        cb.label = "glyph calibration"
        r.render(withViewport: CGRect(x: 0, y: 0, width: pw, height: ph), commandBuffer: cb, renderPassDescriptor: pass)
        guard let blit = cb.makeBlitCommandEncoder() else { return "glyph calibration: no blit encoder" }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: pw, height: ph, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * ph)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if cb.status != .completed { return "glyph calibration: render failed" }
        let px = buf.contents().bindMemory(to: UInt8.self, capacity: bpr * ph)
        /// Ink box (pixels, top-left origin) of alpha >= 50 % in a rectangle.
        func ink(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (Int, Int, Int, Int)? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in max(0, y0)..<min(ph, y1) {
                let row = px + y * bpr
                for x in max(0, x0)..<min(pw, x1) where row[x * 4 + 3] >= 128 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return maxX < 0 ? nil : (minX, minY, maxX, maxY)
        }
        let colPx = Int((colW * scale).rounded())
        var notes: [String] = []
        var result: [Config: CGPoint] = [:]
        for (k, (cfg, l)) in configs.enumerated() {
            // slot k counts from the bottom of the scene; rows count from the top of the image
            let yTop = ph - Int((CGFloat(k + 1) * slotH * scale).rounded()), yBot = ph - Int((CGFloat(k) * slotH * scale).rounded())
            guard let a = ink(0, yTop, colPx, yBot), let b0 = ink(colPx, yTop, pw, yBot) else {
                notes.append("\(l.atlas.size)pt: no ink")
                continue
            }
            let b = (b0.0 - colPx, b0.1, b0.2 - colPx, b0.3)
            let dxPx: Int
            switch l.align {
            case .left: dxPx = a.0 - b.0
            case .right: dxPx = a.2 - b.2
            default: dxPx = ((a.0 + a.2) - (b.0 + b.2)) / 2
            }
            let dyPx = a.1 - b.1
            let spacing = (a.2 - a.0) - (b.2 - b.0)
            let off = CGPoint(x: CGFloat(dxPx) / scale, y: -CGFloat(dyPx) / scale)
            // a sane correction is a few points; anything larger means the measurement went wrong
            if abs(off.x) <= 6 && abs(off.y) <= 6 { result[cfg] = off }
            // (2 lines: the bottom edges agree too when the line spacing matches)
            notes.append(String(format: "%@ %.0fpt %d/%d%@ dx=%+dpx dy=%+dpx width%+dpx bottom%+dpx", l.atlas.fontName, l.atlas.size,
                                l.align.rawValue, l.valign.rawValue, cfg.multiline ? " 2 lines" : "", dxPx, -dyPx, spacing,
                                -((a.3 - b.3) - dyPx)))
        }
        offsets = result
        for w in labels { w.label?.relayout() }
        return String(format: "glyph calibration in %.0f ms: ", (FrameTimer.now() - t0) * 1000) + notes.joined(separator: "; ")
    }
}
