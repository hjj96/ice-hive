import SpriteKit
import UIKit
import IceHiveCore

/// Rectangular menu button (web .btn / .btn-go / .btn-ghost / .btn-danger).
final class MenuButton {
    enum Style { case go, normal, ghost, danger }
    let node = SKNode()
    private var panel = SKSpriteNode(texture: nil)
    let label: Label
    private(set) var rect = CGRect.zero   // HUD coordinates
    let style: Style

    init(_ text: String, style: Style) {
        self.style = style
        let color: SKColor
        switch style {
        case .go: color = UIPalette.bg
        case .normal: color = UIPalette.ink
        case .ghost: color = UIPalette.inkDim
        case .danger: color = UIPalette.red
        }
        label = Label(text.uppercased(), font: style == .go ? Fonts.bold : Fonts.semibold, size: style == .go ? 20 : 15, color: color, kern: style == .go ? 4 : 2)
        node.addChild(panel)
        node.addChild(label.node)
        label.node.zPosition = 1
    }

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
        }
        panel = Shapes.panel(width: s.width, height: s.height, fill: fill, stroke: stroke)
        panel.position = CGPoint(x: -s.width / 2, y: s.height / 2)
        node.insertChild(panel, at: 0)
        node.position = c
        rect = CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
    }

    func hit(_ p: CGPoint) -> Bool { !node.isHidden && rect.insetBy(dx: -4, dy: -4).contains(p) }
}

/// Wrapped paragraph label.
private func paragraph(_ text: String, font: String, size: CGFloat, color: SKColor, width: CGFloat) -> SKLabelNode {
    let l = SKLabelNode()
    l.numberOfLines = 0
    l.preferredMaxLayoutWidth = width
    l.horizontalAlignmentMode = .center
    l.verticalAlignmentMode = .top
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = 2
    l.attributedText = NSAttributedString(string: text, attributes: [.font: Fonts.font(font, size), .foregroundColor: color, .paragraphStyle: style])
    return l
}

// ================================================================
//  TITLE — the attract-mode station runs behind; class choice + «В бой»
// ================================================================
final class TitleScreen {
    enum Action { case select(MarineClass), start }
    let root = SKNode()
    private let shade = SKSpriteNode(color: UIPalette.rgba(5, 7, 10, 0.5), size: CGSize(width: 10, height: 10))
    private var content = SKNode()
    private var cards: [(MarineClass, CGRect, SKSpriteNode)] = []
    private let go = MenuButton("В бой", style: .go)
    private(set) var selected: MarineClass = .assault

    init() {
        root.zPosition = ZBand.hud + 200
        root.addChild(shade)
        root.addChild(content)
        root.addChild(go.node)
    }

    func layout(size: CGSize, insets: UIEdgeInsets, selected cls: MarineClass) {
        selected = cls
        content.removeFromParent()
        content = SKNode()
        root.addChild(content)
        cards.removeAll()
        let W = size.width, H = size.height
        let landscape = W > H
        shade.size = size
        let pad: CGFloat = 20
        let left = -W / 2 + max(pad, insets.left + 8), right = W / 2 - max(pad, insets.right + 8)
        let cw = right - left
        var y = H / 2 - insets.top - (landscape ? 14 : 30)

        let meta = Label("ОПЕРАЦИЯ «ХОЛОДНЫЙ СВЕТ»", font: Fonts.mono, size: 11, color: UIPalette.teal, kern: 1.3, align: .left)
        meta.node.position = CGPoint(x: left, y: y)
        content.addChild(meta.node)
        let meta2 = Label("КЕЛЬВИН-9 · −94 °C", font: Fonts.mono, size: 11, color: UIPalette.inkDim, kern: 1.3, align: .right)
        meta2.node.position = CGPoint(x: right, y: y)
        content.addChild(meta2.node)
        y -= landscape ? 40 : 54
        let ts = landscape ? min(56, H * 0.13) : max(46, min(72, W * 0.125))
        let t1 = Label("ЛЕДЯНОЙ", font: Fonts.bold, size: ts, color: UIPalette.ink, kern: 1, align: .left)
        t1.node.position = CGPoint(x: left, y: y)
        content.addChild(t1.node)
        let t2 = Label("УЛЕЙ", font: Fonts.bold, size: ts, color: UIPalette.amber, kern: 1, align: .left)
        t2.stroke = UIPalette.amber
        t2.set("УЛЕЙ", force: true)
        if landscape {
            t2.node.position = CGPoint(x: left + t1.width + ts * 0.25, y: y)
        } else {
            y -= ts * 0.95
            t2.node.position = CGPoint(x: left, y: y)
        }
        content.addChild(t2.node)
        y -= ts * 0.55 + 6
        let premise = paragraph("Станция замолчала шесть часов назад. Под решётками шевелится рой. Запустите три маяка, вызовите грузовой лифт и продержитесь до эвакуации.",
                                font: Fonts.regular, size: landscape ? 13 : 14, color: UIPalette.inkDim, width: cw)
        premise.horizontalAlignmentMode = .left
        premise.position = CGPoint(x: left, y: y)
        content.addChild(premise)
        y -= premise.frame.height + (landscape ? 10 : 18)
        let lab = Label("ВЫБЕРИТЕ КЛАСС", font: Fonts.medium, size: 12, color: UIPalette.amber, kern: 3.1, align: .left)
        lab.node.position = CGPoint(x: left, y: y - 6)
        content.addChild(lab.node)
        let line = SKSpriteNode(color: UIPalette.line, size: CGSize(width: max(1, cw - lab.width - 12), height: 1))
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.position = CGPoint(x: left + lab.width + 10, y: y - 6)
        content.addChild(line)
        y -= 18

        // class cards: 2 × 2 in portrait, a row of 4 in landscape
        let perRow = landscape ? 4 : 2
        let gap: CGFloat = 8
        let cardW = (cw - gap * CGFloat(perRow - 1)) / CGFloat(perRow)
        let cardH: CGFloat = landscape ? 74 : 92
        for (k, c) in MarineClass.allCases.enumerated() {
            let col = k % perRow, row = k / perRow
            let x = left + CGFloat(col) * (cardW + gap)
            let top = y - CGFloat(row) * (cardH + gap)
            let sel = c == cls
            let panel = Shapes.panel(width: cardW, height: cardH, fill: sel ? UIPalette.rgba(20, 30, 40, 0.96) : UIPalette.panel,
                                     stroke: sel ? UIPalette.amber : UIPalette.line, lineWidth: sel ? 2 : 1)
            panel.position = CGPoint(x: x, y: top)
            content.addChild(panel)
            let chip = SKSpriteNode(color: UIPalette.classColors[k], size: CGSize(width: 4, height: cardH - 16))
            chip.anchorPoint = CGPoint(x: 0, y: 1)
            chip.position = CGPoint(x: x + 8, y: top - 8)
            content.addChild(chip)
            let name = Label(c.spec.name.uppercased(), font: Fonts.bold, size: landscape ? 15 : 18, color: UIPalette.ink, kern: 0.7, align: .left)
            name.node.position = CGPoint(x: x + 20, y: top - 18)
            content.addChild(name.node)
            let weapon = Label(c.spec.weapon, font: Fonts.regular, size: 12, color: UIPalette.inkDim, align: .left)
            weapon.node.position = CGPoint(x: x + 20, y: top - (landscape ? 38 : 42))
            content.addChild(weapon.node)
            let ab = Label(c.spec.ability.uppercased(), font: Fonts.medium, size: 11, color: sel ? UIPalette.amber : UIPalette.teal, kern: 1.2, align: .left)
            ab.node.position = CGPoint(x: x + 20, y: top - (landscape ? 58 : 66))
            content.addChild(ab.node)
            cards.append((c, CGRect(x: x, y: top - cardH, width: cardW, height: cardH), panel))
        }
        let rows = (MarineClass.allCases.count + perRow - 1) / perRow
        y -= CGFloat(rows) * (cardH + gap) + 8
        let goW = landscape ? min(260, cw) : cw
        go.layout(center: CGPoint(x: landscape ? right - goW / 2 : 0, y: y - 28), size: CGSize(width: goW, height: 54))
        let hint = Label("Левый палец — бег · правый — прицел и огонь", font: Fonts.regular, size: 12, color: UIPalette.inkDim, align: .center)
        hint.node.position = CGPoint(x: landscape ? left + (cw - goW) / 2 : 0, y: landscape ? y - 28 : y - 78)
        content.addChild(hint.node)
    }

    func hit(_ p: CGPoint) -> Action? {
        if go.hit(p) { return .start }
        for (c, r, _) in cards where r.contains(p) { return .select(c) }
        return nil
    }
}

// ================================================================
//  LEVEL UP — three upgrade cards; the simulation waits
// ================================================================
final class LevelUpScreen {
    let root = SKNode()
    private let shade = SKSpriteNode(color: UIPalette.rgba(5, 7, 10, 0.72), size: CGSize(width: 10, height: 10))
    private var content = SKNode()
    private var rects: [CGRect] = []

    init() {
        root.zPosition = ZBand.hud + 150
        root.addChild(shade)
        root.addChild(content)
        root.isHidden = true
    }

    func show(level: Int, offer: [Upgrade], cls: MarineClass, size: CGSize, insets: UIEdgeInsets) {
        root.isHidden = false
        content.removeFromParent()
        content = SKNode()
        root.addChild(content)
        rects.removeAll()
        shade.size = size
        let W = size.width, H = size.height
        let landscape = W > H
        let cw = min(W - 40, landscape ? 900 : 420)
        var y = landscape ? H / 2 - insets.top - 34 : H * 0.28
        let tag = Label("НОВЫЙ УРОВЕНЬ  \(level)", font: Fonts.bold, size: 30, color: UIPalette.amber, kern: 3.5)
        tag.node.position = CGPoint(x: 0, y: y)
        content.addChild(tag.node)
        y -= 30
        let sub = Label("ВЫБЕРИТЕ УЛУЧШЕНИЕ", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 3.6)
        sub.node.position = CGPoint(x: 0, y: y)
        content.addChild(sub.node)
        y -= 22
        let n = offer.count
        let gap: CGFloat = landscape ? 12 : 8
        let cardW = landscape ? (cw - gap * CGFloat(max(0, n - 1))) / CGFloat(max(1, n)) : cw
        let cardH: CGFloat = landscape ? 150 : 96
        for (k, u) in offer.enumerated() {
            let x = landscape ? -cw / 2 + CGFloat(k) * (cardW + gap) : -cw / 2
            let top = landscape ? y : y - CGFloat(k) * (cardH + gap)
            let classCard = u.classes != nil
            let panel = Shapes.panel(width: cardW, height: cardH, fill: UIPalette.panel2, stroke: classCard ? UIPalette.amberDim : UIPalette.line)
            panel.position = CGPoint(x: x, y: top)
            content.addChild(panel)
            let t = Label(classCard ? "СПЕЦИАЛИЗАЦИЯ" : "УЛУЧШЕНИЕ", font: Fonts.medium, size: 11, color: classCard ? UIPalette.amber : UIPalette.teal, kern: 2, align: .left)
            t.node.position = CGPoint(x: x + 14, y: top - 16)
            content.addChild(t.node)
            let key = Label("\(k + 1)", font: Fonts.monoBold, size: 12, color: UIPalette.inkFaint, align: .right)
            key.node.position = CGPoint(x: x + cardW - 12, y: top - 16)
            content.addChild(key.node)
            let name = Label(u.name.uppercased(), font: Fonts.bold, size: 19, color: UIPalette.ink, kern: 0.8, align: .left)
            name.node.position = CGPoint(x: x + 14, y: top - 38)
            content.addChild(name.node)
            let d = SKLabelNode()
            d.numberOfLines = 0
            d.preferredMaxLayoutWidth = cardW - 28
            d.horizontalAlignmentMode = .left
            d.verticalAlignmentMode = .top
            d.attributedText = NSAttributedString(string: u.desc, attributes: [.font: Fonts.font(Fonts.regular, 13), .foregroundColor: UIPalette.inkDim])
            d.position = CGPoint(x: x + 14, y: top - 52)
            content.addChild(d)
            rects.append(CGRect(x: x, y: top - cardH, width: cardW, height: cardH))
        }
    }

    func hide() { root.isHidden = true }

    func hit(_ p: CGPoint) -> Int? {
        if root.isHidden { return nil }
        for (k, r) in rects.enumerated() where r.contains(p) { return k }
        return nil
    }
}

// ================================================================
//  PAUSE / END — small boxes with buttons
// ================================================================
final class MenuScreen {
    enum Action { case resume, sound, quit, again, changeClass }
    let root = SKNode()
    private let shade = SKSpriteNode(color: UIPalette.rgba(5, 7, 10, 0.7), size: CGSize(width: 10, height: 10))
    private var content = SKNode()
    private var buttons: [(MenuButton, Action)] = []

    init() {
        root.zPosition = ZBand.hud + 180
        root.addChild(shade)
        root.addChild(content)
        root.isHidden = true
    }

    private func reset(size: CGSize) {
        root.isHidden = false
        content.removeFromParent()
        content = SKNode()
        root.addChild(content)
        buttons.removeAll()
        shade.size = size
    }

    func showPause(size: CGSize, soundOn: Bool) {
        reset(size: size)
        let w = min(320, size.width - 40)
        let title = Label("ПАУЗА", font: Fonts.bold, size: 34, color: UIPalette.ink, kern: 4)
        title.node.position = CGPoint(x: 0, y: 120)
        content.addChild(title.node)
        let items: [(String, MenuButton.Style, Action)] = [("Продолжить", .normal, .resume), ("Звук: " + (soundOn ? "вкл" : "выкл"), .ghost, .sound), ("Сдаться", .danger, .quit)]
        for (k, it) in items.enumerated() {
            let b = MenuButton(it.0, style: it.1)
            b.layout(center: CGPoint(x: 0, y: 60 - CGFloat(k) * 56), size: CGSize(width: w, height: 46))
            content.addChild(b.node)
            buttons.append((b, it.2))
        }
    }

    func showEnd(size: CGSize, stats: MissionStats, surrendered: Bool) {
        reset(size: size)
        let W = size.width
        let w = min(420, W - 32)
        let won = stats.won
        var y: CGFloat = min(220, size.height / 2 - 60)
        let tag = Label("ОТЧЁТ МИССИИ · КЕЛЬВИН-9", font: Fonts.mono, size: 12, color: UIPalette.inkDim, kern: 2.4)
        tag.node.position = CGPoint(x: 0, y: y)
        content.addChild(tag.node)
        y -= 40
        let title = Label(won ? "ЭВАКУАЦИЯ УСПЕШНА" : "РОЙ ПОБЕДИЛ", font: Fonts.bold, size: min(34, W * 0.075), color: won ? UIPalette.teal : UIPalette.red, kern: 3)
        title.node.position = CGPoint(x: 0, y: y)
        content.addChild(title.node)
        y -= 26
        let subText = won ? "Отряд поднялся над бездной. Кельвин-9 остаётся рою — но вы живы."
            : (surrendered ? "Отряд отозван. Маяки погасли один за другим." : "Последний фонарь погас. Связь с отрядом потеряна.")
        let sub = paragraph(subText, font: Fonts.regular, size: 14, color: UIPalette.inkDim, width: w)
        sub.position = CGPoint(x: 0, y: y)
        content.addChild(sub)
        y -= sub.frame.height + 18
        let rows: [(String, String)] = [("Время", formatTime(stats.time)), ("Убито отрядом", "\(stats.kills)"), ("Ваши убийства", "\(stats.playerKills)"),
                                        ("Точность", "\(stats.accuracy)%"), ("Лучшее комбо", "×\(stats.bestCombo)"), ("Уровень", "\(stats.level)")]
        let cols = 3
        let cellW = w / CGFloat(cols), cellH: CGFloat = 54
        for (k, r) in rows.enumerated() {
            let cx = -w / 2 + CGFloat(k % cols) * cellW, cy = y - CGFloat(k / cols) * cellH
            let cell = Shapes.panel(width: cellW - 2, height: cellH - 2, cut: 0, fill: UIPalette.panel2)
            cell.position = CGPoint(x: cx + 1, y: cy)
            content.addChild(cell)
            let a = Label(r.0.uppercased(), font: Fonts.medium, size: 10, color: UIPalette.inkDim, kern: 1.2, align: .left)
            a.node.position = CGPoint(x: cx + 10, y: cy - 14)
            content.addChild(a.node)
            let b = Label(r.1, font: Fonts.monoBold, size: 18, color: UIPalette.ink, align: .left)
            b.node.position = CGPoint(x: cx + 10, y: cy - 36)
            content.addChild(b.node)
        }
        y -= CGFloat((rows.count + cols - 1) / cols) * cellH + 34
        let again = MenuButton("Ещё раз", style: .go)
        again.layout(center: CGPoint(x: 0, y: y), size: CGSize(width: w, height: 52))
        content.addChild(again.node)
        buttons.append((again, .again))
        let menu = MenuButton("Сменить класс", style: .ghost)
        menu.layout(center: CGPoint(x: 0, y: y - 60), size: CGSize(width: w, height: 46))
        content.addChild(menu.node)
        buttons.append((menu, .changeClass))
    }

    func hide() { root.isHidden = true }
    var isShown: Bool { !root.isHidden }

    func hit(_ p: CGPoint) -> Action? {
        if root.isHidden { return nil }
        for (b, a) in buttons where b.hit(p) { return a }
        return nil
    }
}
