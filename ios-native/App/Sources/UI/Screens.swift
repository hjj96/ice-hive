import SpriteKit
import UIKit
import IceHiveCore

/// Rectangular menu button (web .btn / .btn-go / .btn-ghost / .btn-danger).
final class MenuButton {
    enum Style { case go, normal, ghost, danger, chip }
    let node = SKNode()
    private var panel = SKSpriteNode(texture: nil)
    let label: Label
    private(set) var rect = CGRect.zero   // HUD coordinates
    let style: Style

    init(_ text: String, style: Style, fontSize: CGFloat? = nil) {
        self.style = style
        let color: SKColor
        switch style {
        case .go: color = UIPalette.bg
        case .normal: color = UIPalette.ink
        case .ghost: color = UIPalette.inkDim
        case .danger: color = UIPalette.red
        case .chip: color = UIPalette.amber
        }
        let size = fontSize ?? (style == .go ? 20 : (style == .chip ? 14 : 15))
        label = Label(text.uppercased(), font: style == .go ? Fonts.bold : Fonts.semibold, size: size, color: color,
                      kern: style == .go ? 4 : (style == .chip ? 1.4 : 2))
        node.addChild(panel)
        node.addChild(label.node)
        label.node.zPosition = 1
    }

    func setText(_ t: String) { label.set(t.uppercased()) }

    /// Centre + size in HUD coordinates.
    func layout(center c: CGPoint, size s: CGSize) {
        panel.removeFromParent()
        let fill: SKColor
        var stroke: SKColor? = nil
        switch style {
        case .go: fill = UIPalette.amber
        case .normal: fill = UIPalette.panel2; stroke = UIPalette.line
        case .ghost: fill = .clear; stroke = UIPalette.line
        case .danger: fill = .clear; stroke = UIPalette.rgba(255, 59, 59, 0.5)
        case .chip: fill = .clear; stroke = UIPalette.amber
        }
        panel = Shapes.panel(width: s.width, height: s.height, fill: fill, stroke: stroke)
        panel.position = CGPoint(x: -s.width / 2, y: s.height / 2)
        panel.zPosition = -1
        node.insertChild(panel, at: 0)
        node.position = c
        rect = CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
    }

    /// Tap area: the drawn rect + 4 pt, and at least 44 pt tall (compact landscape rows are drawn 34–38 pt high).
    var hitRect: CGRect { MenuButton.tapRect(rect, pad: 4) }
    func hit(_ p: CGPoint) -> Bool { !node.isHidden && hitRect.contains(p) }
    /// Distance from p to the drawn rect (0 inside): neighbours whose tap areas overlap resolve to the nearest one.
    func distance(to p: CGPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX), dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
    /// `r` grown by `pad` each way, then to at least 44 × 44 pt around its centre (Apple's minimum tap target).
    static func tapRect(_ r: CGRect, pad: CGFloat) -> CGRect {
        r.insetBy(dx: -max(pad, (44 - r.width) / 2), dy: -max(pad, (44 - r.height) / 2))
    }

    /// The button sits in a container moved by `d`: its hit rect follows.
    func offset(by d: CGPoint) { rect = rect.offsetBy(dx: d.x, dy: d.y) }
}

/// Wrapped paragraph label.
func paragraph(_ text: String, font: String, size: CGFloat, color: SKColor, width: CGFloat,
                       align: NSTextAlignment = .center) -> SKLabelNode {
    let l = SKLabelNode()
    l.numberOfLines = 0
    l.preferredMaxLayoutWidth = width
    l.horizontalAlignmentMode = align == .left ? .left : .center
    l.verticalAlignmentMode = .top
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineSpacing = 2
    l.attributedText = NSAttributedString(string: text, attributes: [.font: Fonts.font(font, size), .foregroundColor: color, .paragraphStyle: style])
    LabelStats.textsSet += 1
    return l
}

/// Paragraph with bold-ink runs (web `<b>` in .t-hint / .m-hint): parts alternate plain / bold, starting bold.
func richParagraph(_ parts: [String], size: CGFloat, width: CGFloat, align: NSTextAlignment) -> SKLabelNode {
    let l = SKLabelNode()
    l.numberOfLines = 0
    l.preferredMaxLayoutWidth = width
    l.horizontalAlignmentMode = align == .left ? .left : .center
    l.verticalAlignmentMode = .top
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineSpacing = 2
    let s = NSMutableAttributedString(string: "")
    for (k, p) in parts.enumerated() {
        let bold = k % 2 == 0
        s.append(NSAttributedString(string: p, attributes: [
            .font: Fonts.font(bold ? Fonts.semibold : Fonts.regular, size),
            .foregroundColor: bold ? UIPalette.ink : UIPalette.inkDim,
            .kern: CGFloat(0.5), .paragraphStyle: style]))
    }
    l.attributedText = s
    LabelStats.textsSet += 1
    return l
}

/// Touch control hint of the web title / pause screens (controlHint(), touch mode).
let touchHintParts = ["Левый палец", " — движение · ", "правый палец", " — прицел и автоогонь · кнопки справа — способность и рывок"]
/// The same, shorter: two lines under the pause menu's mission column.
let pauseHintParts = ["Левый палец", " — бег · ", "правый", " — прицел и огонь · ", "справа", " — способность и рывок"]

/// Amber / black hazard band (web .hz: 8 px, right end cut at 45°), top-left anchored.
func hazardBand(width: CGFloat, height: CGFloat) -> SKSpriteNode {
    let n = SKSpriteNode(texture: GeneratedTextures.hazard(width: width, height: height, cutRight: true))
    n.size = CGSize(width: width, height: height)
    n.anchorPoint = CGPoint(x: 0, y: 1)
    return n
}

// ================================================================
//  LEVEL UP — three upgrade cards; the simulation waits. A card is
//  picked when the finger lifts over it (the scene tracks the touch),
//  and the cards stay locked for 0.65 s after they appear, so a thumb
//  already on the glass cannot pick one by accident (web renderCards).
// ================================================================
final class LevelUpScreen {
    let root = SKNode()
    private let shade = SKSpriteNode(color: UIPalette.rgba(5, 7, 10, 0.72), size: CGSize(width: 10, height: 10))
    private var content = SKNode()
    private var cardsNode = SKNode()
    private var rects: [CGRect] = []
    private var unlockAt: Double = 0
    static let lockTime: Double = 0.65

    init() {
        root.zPosition = ZBand.hud + 150
        shade.zPosition = -2   // ignoresSiblingOrder: equal z draws in any order
        root.addChild(shade)
        root.addChild(content)
        root.isHidden = true
    }

    /// `level` = the level these cards are for (web: GS.level − pendingLevels + 1). Landscape (LAND): the head and the
    /// three cards in a row, the block centred in the safe area; a card is as tall as its longest description needs.
    func show(level: Int, offer: [Upgrade], counts: [UpgradeID: Int], cls: MarineClass, size: CGSize, insets: UIEdgeInsets,
              layoutCheck: Bool = false) {
        root.isHidden = false
        content.removeFromParent()
        content = SKNode()
        root.addChild(content)
        cardsNode = SKNode()
        content.addChild(cardsNode)
        rects.removeAll()
        shade.size = size
        unlockAt = FrameTimer.now() + LevelUpScreen.lockTime
        let W = size.width, H = size.height
        let sl = max(20, insets.left), sr = max(20, insets.right)
        let cw = min(W - sl - sr, 860)
        let n = offer.count
        let gap: CGFloat = 12
        let cardW = (cw - gap * CGFloat(max(0, n - 1))) / CGFloat(max(1, n))
        // descriptions first: the cards take the height of the longest one
        var descs: [SKLabelNode] = []
        var descH: CGFloat = 0
        for u in offer {
            let d = SKLabelNode()
            d.numberOfLines = 0
            d.preferredMaxLayoutWidth = cardW - 28
            d.horizontalAlignmentMode = .left
            d.verticalAlignmentMode = .top
            d.attributedText = NSAttributedString(string: u.desc, attributes: [.font: Fonts.font(Fonts.regular, 13), .foregroundColor: UIPalette.inkDim])
            LabelStats.textsSet += 1
            descs.append(d)
            descH = max(descH, d.frame.height)
        }
        let cardH = max(128, 52 + descH + 34)
        // web .lv-head: «НОВЫЙ УРОВЕНЬ» + the number, centred together
        let hs = max(26, min(36, H * 0.085))
        let blockH = hs + 22 + 24 + cardH
        let safeTop = H / 2 - insets.top - 10, safeBottom = -H / 2 + insets.bottom + 10
        var top = (safeTop + safeBottom) / 2 + blockH / 2
        top = min(top, safeTop)
        var check = LayoutCheck("levelup")
        var y = top - hs / 2
        let tag = Label("НОВЫЙ УРОВЕНЬ", font: Fonts.bold, size: hs, color: UIPalette.amber, kern: hs * 0.12, align: .left)
        let num = Label("\(level)", font: Fonts.monoBold, size: hs, color: UIPalette.ink, align: .left)
        let x0 = -(tag.width + 12 + num.width) / 2
        tag.node.position = CGPoint(x: x0, y: y)
        num.node.position = CGPoint(x: x0 + tag.width + 12, y: y)
        content.addChild(tag.node)
        content.addChild(num.node)
        check.add("head#1", node: tag.node)
        check.add("head#2", node: num.node)
        y -= hs / 2 + 22
        let sub = Label("ВЫБЕРИТЕ УЛУЧШЕНИЕ", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 3.6)
        sub.node.position = CGPoint(x: 0, y: y)
        content.addChild(sub.node)
        check.add("sub", node: sub.node)
        y -= 24
        for (k, u) in offer.enumerated() {
            let x = -cw / 2 + CGFloat(k) * (cardW + gap)
            let top = y
            let classCard = u.classes != nil
            let panel = Shapes.panel(width: cardW, height: cardH, fill: UIPalette.panel2, stroke: classCard ? UIPalette.amberDim : UIPalette.line)
            panel.position = CGPoint(x: x, y: top)
            panel.zPosition = -1
            cardsNode.addChild(panel)
            let t = Label((classCard ? "Класс · " + cls.spec.name : "Снаряжение").uppercased(), font: Fonts.medium, size: 11,
                          color: classCard ? UIPalette.amber : UIPalette.teal, kern: 2, align: .left)
            MenuScreen.fit(t, cardW - 28)
            t.node.position = CGPoint(x: x + 14, y: top - 16)
            cardsNode.addChild(t.node)
            let name = Label(u.name.uppercased(), font: Fonts.bold, size: 19, color: UIPalette.ink, kern: 0.8, align: .left)
            MenuScreen.fit(name, cardW - 28)
            name.node.position = CGPoint(x: x + 14, y: top - 38)
            cardsNode.addChild(name.node)
            let d = descs[k]
            d.position = CGPoint(x: x + 14, y: top - 52)
            cardsNode.addChild(d)
            let taken = counts[u.id] ?? 0
            let st = Label(taken > 0 ? "Взято: \(taken)" : "Новое", font: Fonts.monoBold, size: 12, color: UIPalette.ink, align: .left)
            st.node.position = CGPoint(x: x + 14, y: top - cardH + 14)
            cardsNode.addChild(st.node)
            let r = CGRect(x: x, y: top - cardH, width: cardW, height: cardH)
            rects.append(r)
            check.add("card\(k)", r)
            check.tap("card\(k)", r)
        }
        if layoutCheck { check.report(size: size, insets: insets) }
        // web .cards.lock .card { opacity: .55 } while locked
        cardsNode.alpha = 0.55
        cardsNode.run(SKAction.sequence([SKAction.wait(forDuration: LevelUpScreen.lockTime), SKAction.fadeAlpha(to: 1, duration: 0.08)]))
    }

    func hide() { root.isHidden = true }

    var locked: Bool { FrameTimer.now() < unlockAt }

    /// Card under `p` (nil while hidden or locked).
    func hit(_ p: CGPoint) -> Int? {
        if root.isHidden || locked { return nil }
        for (k, r) in rects.enumerated() where r.contains(p) { return k }
        return nil
    }
}

