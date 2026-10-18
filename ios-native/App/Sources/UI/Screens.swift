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

    init(_ text: String, style: Style, fontSize: CGFloat? = nil) {
        self.style = style
        let color: SKColor
        switch style {
        case .go: color = UIPalette.bg
        case .normal: color = UIPalette.ink
        case .ghost: color = UIPalette.inkDim
        case .danger: color = UIPalette.red
        }
        let size = fontSize ?? (style == .go ? 20 : 15)
        label = Label(text.uppercased(), font: style == .go ? Fonts.bold : Fonts.semibold, size: size, color: color, kern: style == .go ? 4 : 2)
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
        }
        panel = Shapes.panel(width: s.width, height: s.height, fill: fill, stroke: stroke)
        panel.position = CGPoint(x: -s.width / 2, y: s.height / 2)
        panel.zPosition = -1
        node.insertChild(panel, at: 0)
        node.position = c
        rect = CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
    }

    func hit(_ p: CGPoint) -> Bool { !node.isHidden && rect.insetBy(dx: -4, dy: -4).contains(p) }
}

/// Wrapped paragraph label.
private func paragraph(_ text: String, font: String, size: CGFloat, color: SKColor, width: CGFloat,
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
    return l
}

/// Paragraph with bold-ink runs (web `<b>` in .t-hint / .m-hint): parts alternate plain / bold, starting bold.
private func richParagraph(_ parts: [String], size: CGFloat, width: CGFloat, align: NSTextAlignment) -> SKLabelNode {
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
    return l
}

/// Touch control hint of the web title / pause screens (controlHint(), touch mode).
let touchHintParts = ["Левый палец", " — движение · ", "правый палец", " — прицел и автоогонь · кнопки справа — способность и рывок"]

/// Amber / black hazard band (web .hz: 8 px, right end cut at 45°), top-left anchored.
private func hazardBand(width: CGFloat, height: CGFloat) -> SKSpriteNode {
    let n = SKSpriteNode(texture: GeneratedTextures.hazard(width: width, height: height, cutRight: true))
    n.size = CGSize(width: width, height: height)
    n.anchorPoint = CGPoint(x: 0, y: 1)
    return n
}

// ================================================================
//  TITLE — the attract-mode station runs behind; class choice + «В бой»
// ================================================================
final class TitleScreen {
    enum Action: Equatable { case select(MarineClass), start, sound }
    let root = SKNode()
    private let shade = SKSpriteNode(color: UIPalette.rgba(5, 7, 10, 0.5), size: CGSize(width: 10, height: 10))
    private var content = SKNode()
    private var cards: [(MarineClass, CGRect, SKSpriteNode)] = []
    private let go = MenuButton("В бой", style: .go)
    private let sound = MenuButton("Звук: вкл", style: .ghost)
    private(set) var selected: MarineClass = .assault

    init() {
        root.zPosition = ZBand.hud + 200
        shade.zPosition = -2   // ignoresSiblingOrder: equal z draws in any order
        root.addChild(shade)
        root.addChild(content)
        root.addChild(go.node)
        root.addChild(sound.node)
    }

    /// `record`: the «Рекорд: …» line (nil = no record yet).
    func layout(size: CGSize, insets: UIEdgeInsets, selected cls: MarineClass, soundOn: Bool, record: String?) {
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
        var y = H / 2 - insets.top - (landscape ? 10 : 26)

        let hz = hazardBand(width: cw, height: landscape ? 6 : 8)
        hz.position = CGPoint(x: left, y: y)
        content.addChild(hz)
        y -= landscape ? 18 : 24
        let meta = Label("ОПЕРАЦИЯ «ХОЛОДНЫЙ СВЕТ»", font: Fonts.mono, size: 11, color: UIPalette.teal, kern: 1.3, align: .left)
        meta.node.position = CGPoint(x: left, y: y)
        content.addChild(meta.node)
        let meta2 = Label("КЕЛЬВИН-9 · −94 °C", font: Fonts.mono, size: 11, color: UIPalette.inkDim, kern: 1.3, align: .right)
        meta2.node.position = CGPoint(x: right, y: y)
        content.addChild(meta2.node)
        y -= landscape ? 36 : 50
        let ts = landscape ? min(52, H * 0.12) : max(46, min(72, W * 0.125))
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
                                font: Fonts.regular, size: landscape ? 13 : 14, color: UIPalette.inkDim, width: cw, align: .left)
        premise.horizontalAlignmentMode = .left
        premise.position = CGPoint(x: left, y: y)
        content.addChild(premise)
        y -= premise.frame.height + (landscape ? 8 : 16)
        let lab = Label("ВЫБЕРИТЕ КЛАСС", font: Fonts.medium, size: 12, color: UIPalette.amber, kern: 3.1, align: .left)
        lab.node.position = CGPoint(x: left, y: y - 6)
        content.addChild(lab.node)
        let line = SKSpriteNode(color: UIPalette.line, size: CGSize(width: max(1, cw - lab.width - 12), height: 1))
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.position = CGPoint(x: left + lab.width + 10, y: y - 6)
        content.addChild(line)
        y -= 18

        // class cards (web .ccard): 2 × 2 in portrait, a row of 4 in landscape
        let perRow = landscape ? 4 : 2
        let gap: CGFloat = 8
        let cardW = (cw - gap * CGFloat(perRow - 1)) / CGFloat(perRow)
        let cardH: CGFloat = landscape ? 76 : 98
        for (k, c) in MarineClass.allCases.enumerated() {
            let col = k % perRow, row = k / perRow
            let x = left + CGFloat(col) * (cardW + gap)
            let top = y - CGFloat(row) * (cardH + gap)
            let sel = c == cls
            let cc = UIPalette.classColors[k]
            let panel = Shapes.panel(width: cardW, height: cardH, fill: sel ? UIPalette.rgba(20, 30, 40, 0.96) : UIPalette.panel,
                                     stroke: sel ? cc : UIPalette.line, lineWidth: sel ? 2 : 1)
            panel.position = CGPoint(x: x, y: top)
            panel.zPosition = -1
            content.addChild(panel)
            let chip = SKSpriteNode(color: cc, size: CGSize(width: 4, height: cardH - 8))
            chip.anchorPoint = CGPoint(x: 0, y: 1)
            chip.position = CGPoint(x: x, y: top)
            content.addChild(chip)
            let tx = x + (landscape ? 13 : 16)
            let idx = Label("0\(k + 1)", font: Fonts.mono, size: landscape ? 11 : 12, color: UIPalette.inkFaint, align: .left)
            idx.node.position = CGPoint(x: tx, y: top - (landscape ? 11 : 14))
            content.addChild(idx.node)
            let ln = SKSpriteNode(color: cc, size: CGSize(width: min(46, cardW * 0.3), height: 2))
            ln.anchorPoint = CGPoint(x: 1, y: 0.5)
            ln.position = CGPoint(x: x + cardW - 12, y: top - (landscape ? 11 : 14))
            content.addChild(ln)
            let name = Label(c.spec.name.uppercased(), font: Fonts.bold, size: landscape ? 15 : 18, color: sel ? UIPalette.white : UIPalette.ink, kern: 0.7, align: .left)
            name.node.position = CGPoint(x: tx, y: top - (landscape ? 28 : 35))
            content.addChild(name.node)
            let weapon = Label(c.spec.weapon, font: Fonts.regular, size: 12, color: UIPalette.inkDim, align: .left)
            weapon.node.position = CGPoint(x: tx, y: top - (landscape ? 45 : 56))
            content.addChild(weapon.node)
            let ab = Label("◆ " + c.spec.ability, font: Fonts.medium, size: 12, color: UIPalette.amber, kern: 0.3, align: .left)
            ab.node.position = CGPoint(x: tx, y: top - (landscape ? 62 : 77))
            content.addChild(ab.node)
            cards.append((c, CGRect(x: x, y: top - cardH, width: cardW, height: cardH), panel))
        }
        let rows = (MarineClass.allCases.count + perRow - 1) / perRow
        y -= CGFloat(rows) * (cardH + gap) + 6

        // «В бой» + «Звук» (web .t-actions), then the control hint and the record line
        sound.setText("Звук: " + (soundOn ? "вкл" : "выкл"))
        let bh: CGFloat = landscape ? 48 : 54
        if landscape {
            let goW = min(240, cw * 0.3), sw: CGFloat = min(170, cw * 0.2)
            go.layout(center: CGPoint(x: right - goW / 2, y: y - bh / 2), size: CGSize(width: goW, height: bh))
            sound.layout(center: CGPoint(x: right - goW - 10 - sw / 2, y: y - bh / 2), size: CGSize(width: sw, height: bh - 6))
            let hw = cw - goW - sw - 34
            let hint = richParagraph(touchHintParts, size: 12, width: hw, align: .left)
            hint.position = CGPoint(x: left, y: y - 2)
            content.addChild(hint)
            if let r = record {
                let best = Label(r, font: Fonts.mono, size: 11, color: UIPalette.teal, kern: 0.7, align: .left)
                best.node.position = CGPoint(x: left, y: y - 6 - hint.frame.height - 10)
                content.addChild(best.node)
            }
        } else {
            let sw = min(150, cw * 0.36)
            let goW = cw - sw - 10
            go.layout(center: CGPoint(x: left + goW / 2, y: y - bh / 2), size: CGSize(width: goW, height: bh))
            sound.layout(center: CGPoint(x: right - sw / 2, y: y - bh / 2), size: CGSize(width: sw, height: bh - 8))
            y -= bh + 12
            let hint = richParagraph(touchHintParts, size: 12, width: cw, align: .left)
            hint.position = CGPoint(x: left, y: y)
            content.addChild(hint)
            y -= hint.frame.height + 12
            if let r = record {
                let best = Label(r, font: Fonts.mono, size: 12, color: UIPalette.teal, kern: 0.7, align: .left)
                best.node.position = CGPoint(x: left, y: y)
                content.addChild(best.node)
            }
        }
    }

    func hit(_ p: CGPoint) -> Action? {
        if go.hit(p) { return .start }
        if sound.hit(p) { return .sound }
        for (c, r, _) in cards where r.contains(p) { return .select(c) }
        return nil
    }
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

    /// `level` = the level these cards are for (web: GS.level − pendingLevels + 1).
    func show(level: Int, offer: [Upgrade], counts: [UpgradeID: Int], cls: MarineClass, size: CGSize, insets: UIEdgeInsets) {
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
        let landscape = W > H
        let cw = min(W - 40 - insets.left - insets.right, landscape ? 900 : 420)
        var y = landscape ? H / 2 - insets.top - 34 : H * 0.28
        // web .lv-head: «НОВЫЙ УРОВЕНЬ» + the number, centred together (clamp(26px, 7vw, 40px))
        let hs = max(24, min(40, W * 0.07))
        let tag = Label("НОВЫЙ УРОВЕНЬ", font: Fonts.bold, size: hs, color: UIPalette.amber, kern: hs * 0.12, align: .left)
        let num = Label("\(level)", font: Fonts.monoBold, size: hs, color: UIPalette.ink, align: .left)
        let x0 = -(tag.width + 12 + num.width) / 2
        tag.node.position = CGPoint(x: x0, y: y)
        num.node.position = CGPoint(x: x0 + tag.width + 12, y: y)
        content.addChild(tag.node)
        content.addChild(num.node)
        y -= 30
        let sub = Label("ВЫБЕРИТЕ УЛУЧШЕНИЕ", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 3.6)
        sub.node.position = CGPoint(x: 0, y: y)
        content.addChild(sub.node)
        y -= 22
        let n = offer.count
        let gap: CGFloat = landscape ? 12 : 8
        let cardW = landscape ? (cw - gap * CGFloat(max(0, n - 1))) / CGFloat(max(1, n)) : cw
        let cardH: CGFloat = landscape ? 160 : 112
        for (k, u) in offer.enumerated() {
            let x = landscape ? -cw / 2 + CGFloat(k) * (cardW + gap) : -cw / 2
            let top = landscape ? y : y - CGFloat(k) * (cardH + gap)
            let classCard = u.classes != nil
            let panel = Shapes.panel(width: cardW, height: cardH, fill: UIPalette.panel2, stroke: classCard ? UIPalette.amberDim : UIPalette.line)
            panel.position = CGPoint(x: x, y: top)
            panel.zPosition = -1
            cardsNode.addChild(panel)
            let t = Label((classCard ? "Класс · " + cls.spec.name : "Снаряжение").uppercased(), font: Fonts.medium, size: 11,
                          color: classCard ? UIPalette.amber : UIPalette.teal, kern: 2, align: .left)
            t.node.position = CGPoint(x: x + 14, y: top - 16)
            cardsNode.addChild(t.node)
            let name = Label(u.name.uppercased(), font: Fonts.bold, size: 19, color: UIPalette.ink, kern: 0.8, align: .left)
            name.node.position = CGPoint(x: x + 14, y: top - 38)
            cardsNode.addChild(name.node)
            let d = SKLabelNode()
            d.numberOfLines = 0
            d.preferredMaxLayoutWidth = cardW - 28
            d.horizontalAlignmentMode = .left
            d.verticalAlignmentMode = .top
            d.attributedText = NSAttributedString(string: u.desc, attributes: [.font: Fonts.font(Fonts.regular, 13), .foregroundColor: UIPalette.inkDim])
            d.position = CGPoint(x: x + 14, y: top - 52)
            cardsNode.addChild(d)
            let taken = counts[u.id] ?? 0
            let st = Label(taken > 0 ? "Взято: \(taken)" : "Новое", font: Fonts.monoBold, size: 12, color: UIPalette.ink, align: .left)
            st.node.position = CGPoint(x: x + 14, y: top - cardH + 14)
            cardsNode.addChild(st.node)
            rects.append(CGRect(x: x, y: top - cardH, width: cardW, height: cardH))
        }
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

// ================================================================
//  PAUSE / END — boxes with buttons (web .m-box with the hazard band)
// ================================================================
final class MenuScreen {
    enum Action: Equatable { case resume, sound, volume, quality, haptics, quit, again, changeClass }
    struct PauseState {
        var soundOn: Bool
        var volume: Float
        var quality: String
        var hapticsOn: Bool
    }
    let root = SKNode()
    private let shade = SKSpriteNode(color: UIPalette.rgba(5, 7, 10, 0.7), size: CGSize(width: 10, height: 10))
    private var content = SKNode()
    private var buttons: [(MenuButton, Action)] = []

    init() {
        root.zPosition = ZBand.hud + 180
        shade.zPosition = -2   // ignoresSiblingOrder: equal z draws in any order
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

    /// The report's line under the title: won / surrendered / lost (TextWarmup lays them out at launch).
    static let endSubtitles = ["Отряд поднялся над бездной. Кельвин-9 остаётся рою — но вы живы.",
                               "Отряд отозван. Маяки погасли один за другим.", "Последний фонарь погас. Связь с отрядом потеряна."]

    /// Web qualityLabel(): «Графика: авто (средняя)» / «Графика: низкая» …
    static func qualityLabel(_ q: String) -> String {
        if q == "auto" { return "Графика: авто (" + QualityTier.med.label.lowercased() + ")" }
        return "Графика: " + (QualityTier(rawValue: q) ?? .med).label.lowercased()
    }

    /// Box background + hazard band, top-left at (x, top).
    private func box(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, edge: SKColor? = nil) {
        let p = Shapes.panel(width: width, height: height, fill: UIPalette.panel2, stroke: edge ?? UIPalette.line)
        p.position = CGPoint(x: x, y: top)
        p.zPosition = -3
        content.addChild(p)
        let hz = hazardBand(width: width, height: 8)
        hz.position = CGPoint(x: x, y: top)
        hz.zPosition = -2.5
        content.addChild(hz)
    }

    func showPause(size: CGSize, state: PauseState) {
        reset(size: size)
        let compact = size.height < 520
        let w = min(320, size.width - 84)
        let bh: CGFloat = compact ? 34 : 44, step: CGFloat = compact ? 39 : 52
        let items: [(String, MenuButton.Style, Action)] = [
            ("Продолжить", .normal, .resume),
            ("Звук: " + (state.soundOn ? "вкл" : "выкл"), .ghost, .sound),
            ("Громкость: \(Int((state.volume * 100).rounded()))%", .ghost, .volume),
            (MenuScreen.qualityLabel(state.quality), .ghost, .quality),
            ("Вибрация: " + (state.hapticsOn ? "вкл" : "выкл"), .ghost, .haptics),
            ("Сдаться", .danger, .quit)]
        let titleH: CGFloat = compact ? 44 : 64
        let boxH = 8 + titleH + CGFloat(items.count) * step + (compact ? 6 : 14)
        let top = boxH / 2
        box(x: -(w + 44) / 2, top: top, width: w + 44, height: boxH)
        let title = Label("ПАУЗА", font: Fonts.bold, size: compact ? 24 : 34, color: UIPalette.ink, kern: 4, align: .left)
        title.node.position = CGPoint(x: -w / 2, y: top - 8 - titleH / 2)
        content.addChild(title.node)
        var y = top - 8 - titleH - bh / 2
        for it in items {
            let b = MenuButton(it.0, style: it.1, fontSize: compact ? 13 : 15)
            b.layout(center: CGPoint(x: 0, y: y), size: CGSize(width: w, height: bh))
            content.addChild(b.node)
            buttons.append((b, it.2))
            y -= step
        }
    }

    func showEnd(size: CGSize, stats: MissionStats, surrendered: Bool, newRecord: Bool) {
        reset(size: size)
        let W = size.width, H = size.height
        let compact = H < 520
        let w = min(420, W - 76)
        let won = stats.won
        let cellH: CGFloat = compact ? 44 : 54
        let rows: [(String, String)] = [("Время", formatTime(stats.time)), ("Убито отрядом", "\(stats.kills)"), ("Ваши убийства", "\(stats.playerKills)"),
                                        ("Точность", "\(stats.accuracy)%"), ("Лучшее комбо", "×\(stats.bestCombo)"), ("Уровень", "\(stats.level)")]
        let cols = 3
        let subText = MenuScreen.endSubtitles[won ? 0 : (surrendered ? 1 : 2)]
        let sub = paragraph(subText, font: Fonts.regular, size: compact ? 13 : 14, color: UIPalette.inkDim, width: w)
        let gridH = CGFloat((rows.count + cols - 1) / cols) * cellH
        let btnH: CGFloat = compact ? 40 : 52, btn2H: CGFloat = compact ? 34 : 46
        let boxH = 8 + (compact ? 22 : 30) + (compact ? 30 : 40) + sub.frame.height + 14 + gridH + 18 + btnH + 8 + btn2H + 18
        let top = min(boxH / 2, H / 2 - 12)
        box(x: -(w + 44) / 2, top: top, width: w + 44, height: boxH, edge: won ? UIPalette.rgba(63, 227, 210, 0.45) : UIPalette.rgba(255, 59, 59, 0.45))
        var y = top - 8 - (compact ? 14 : 20)
        let tag = Label("ОТЧЁТ МИССИИ · КЕЛЬВИН-9", font: Fonts.mono, size: 12, color: UIPalette.inkDim, kern: 2.4)
        tag.node.position = CGPoint(x: 0, y: y)
        content.addChild(tag.node)
        y -= compact ? 26 : 36
        let title = Label(won ? "ЭВАКУАЦИЯ УСПЕШНА" : "РОЙ ПОБЕДИЛ", font: Fonts.bold, size: min(compact ? 26 : 34, W * 0.075), color: won ? UIPalette.teal : UIPalette.red, kern: 3)
        title.node.position = CGPoint(x: 0, y: y)
        content.addChild(title.node)
        y -= compact ? 20 : 26
        sub.position = CGPoint(x: 0, y: y)
        content.addChild(sub)
        y -= sub.frame.height + 14
        let cellW = w / CGFloat(cols)
        for (k, r) in rows.enumerated() {
            let cx = -w / 2 + CGFloat(k % cols) * cellW, cy = y - CGFloat(k / cols) * cellH
            let cell = Shapes.panel(width: cellW - 2, height: cellH - 2, cut: 0, fill: UIPalette.panel)
            cell.position = CGPoint(x: cx + 1, y: cy)
            cell.zPosition = -1
            content.addChild(cell)
            let a = Label(r.0.uppercased(), font: Fonts.medium, size: 10, color: UIPalette.inkDim, kern: 1.2, align: .left)
            a.node.position = CGPoint(x: cx + 10, y: cy - (compact ? 11 : 14))
            content.addChild(a.node)
            let rec = newRecord && k == 1
            let b = Label(r.1, font: Fonts.monoBold, size: compact ? 16 : 18, color: rec ? UIPalette.amber : UIPalette.ink, align: .left)
            b.node.position = CGPoint(x: cx + 10, y: cy - (compact ? 29 : 36))
            content.addChild(b.node)
            if rec {
                let star = Label("РЕКОРД", font: Fonts.medium, size: 10, color: UIPalette.amber, kern: 1.2, align: .left)
                star.node.position = CGPoint(x: cx + 10 + b.width + 6, y: cy - (compact ? 29 : 36))
                content.addChild(star.node)
            }
        }
        y -= gridH + 18
        let again = MenuButton("Ещё раз", style: .go, fontSize: compact ? 17 : 20)
        again.layout(center: CGPoint(x: 0, y: y - btnH / 2), size: CGSize(width: w, height: btnH))
        content.addChild(again.node)
        buttons.append((again, .again))
        y -= btnH + 8
        let menu = MenuButton("Сменить класс", style: .ghost, fontSize: compact ? 13 : 15)
        menu.layout(center: CGPoint(x: 0, y: y - btn2H / 2), size: CGSize(width: w, height: btn2H))
        content.addChild(menu.node)
        buttons.append((menu, .changeClass))
    }

    func hide() { root.isHidden = true }

    func hit(_ p: CGPoint) -> Action? {
        if root.isHidden { return nil }
        for (b, a) in buttons where b.hit(p) { return a }
        return nil
    }
}
