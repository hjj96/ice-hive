import SpriteKit
import UIKit
import IceHiveCore

// ================================================================
//  TITLE — the attract-mode station runs behind; class choice + «В бой».
//  v1.1 (web D layout): the fighter's profile line instead of the old
//  record, a rank chip «ЗВ. N» and Н·В·К medal pips on every class card
//  that has a run, and the one-tap tier row СЛОЖНОСТЬ (НОВОБРАНЕЦ ·
//  ВЕТЕРАН · КОШМАР, ≥ 44 pt) with the chosen tier's line under it. The
//  premise paragraph hides after the first mission. On a short screen
//  the layout drops the control hint, then the premise, then tightens.
// ================================================================
final class TitleScreen {
    enum Action: Equatable { case select(MarineClass), start, sound, tier(Int) }
    /// What the title shows of the player.
    struct Meta {
        let profile: Profile
        /// The tier the next mission plays (`effectiveTier`): the selected segment.
        let tier: Int
        let station: String
    }
    let root = SKNode()
    private let shade = SKSpriteNode(color: UIPalette.rgba(5, 7, 10, 0.5), size: CGSize(width: 10, height: 10))
    private var content = SKNode()
    private var cards: [(MarineClass, CGRect, SKSpriteNode)] = []
    private var tierRects: [CGRect] = []
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

    func layout(size: CGSize, insets: UIEdgeInsets, selected cls: MarineClass, soundOn: Bool, meta: Meta, layoutCheck: Bool = false) {
        selected = cls
        var check = LayoutCheck("title")
        for level in 0...3 {
            check = LayoutCheck("title")
            if build(size: size, insets: insets, soundOn: soundOn, meta: meta, level: level, check: &check) || level == 3 { break }
        }
        if layoutCheck { check.report(size: size, insets: insets) }
    }

    /// One layout attempt; `level` 0 everything, 1 no control hint, 2 no premise either, 3 compact. True when the
    /// last element stays above the bottom safe edge.
    private func build(size: CGSize, insets: UIEdgeInsets, soundOn: Bool, meta: Meta, level: Int, check: inout LayoutCheck) -> Bool {
        content.removeFromParent()
        content = SKNode()
        root.addChild(content)
        cards.removeAll()
        tierRects.removeAll()
        let W = size.width, H = size.height
        let landscape = W > H
        let compact = level >= 3
        shade.size = size
        let pad: CGFloat = 20
        let left = -W / 2 + max(pad, insets.left + 8), right = W / 2 - max(pad, insets.right + 8)
        let cw = right - left
        var y = H / 2 - insets.top - (landscape ? 10 : (compact ? 14 : 26))
        let prof = meta.profile

        let hz = hazardBand(width: cw, height: landscape ? 6 : 8)
        hz.position = CGPoint(x: left, y: y)
        content.addChild(hz)
        check.add("hazard", CGRect(x: left, y: y - (landscape ? 6 : 8), width: cw, height: landscape ? 6 : 8))
        y -= landscape ? 18 : 24
        let opMeta = Label("ОПЕРАЦИЯ «ХОЛОДНЫЙ СВЕТ»", font: Fonts.mono, size: 11, color: UIPalette.teal, kern: 1.3, align: .left)
        opMeta.node.position = CGPoint(x: left, y: y)
        content.addChild(opMeta.node)
        check.add("meta.op", node: opMeta.node)
        let stMeta = Label(meta.station.uppercased() + " · −94 °C", font: Fonts.mono, size: 11, color: UIPalette.inkDim, kern: 1.3, align: .right)
        stMeta.node.position = CGPoint(x: right, y: y)
        content.addChild(stMeta.node)
        check.add("meta.station", node: stMeta.node)
        y -= landscape ? (compact ? 30 : 36) : (compact ? 42 : 50)
        var ts = landscape ? min(52, H * 0.12) : max(46, min(72, W * 0.125))
        if compact { ts *= 0.84 }
        let t1 = Label("ЛЕДЯНОЙ", font: Fonts.bold, size: ts, color: UIPalette.ink, kern: 1, align: .left)
        t1.node.position = CGPoint(x: left, y: y)
        content.addChild(t1.node)
        check.add("title1", node: t1.node)
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
        check.add("title2", node: t2.node)
        y -= ts * 0.55 + 6
        // the story paragraph: for a new player only (web: hidden on phones after the first run)
        if prof.runs == 0 && level < 2 {
            let premise = paragraph("Станция замолчала шесть часов назад. Под решётками шевелится рой. Запустите три маяка, вызовите грузовой лифт и продержитесь до эвакуации.",
                                    font: Fonts.regular, size: landscape ? 13 : 14, color: UIPalette.inkDim, width: cw, align: .left)
            premise.horizontalAlignmentMode = .left
            premise.position = CGPoint(x: left, y: y)
            content.addChild(premise)
            check.add("premise", node: premise)
            y -= premise.frame.height + (landscape ? 8 : 16)
        } else {
            y -= landscape ? 2 : 6
        }
        let lab = Label("ВЫБЕРИТЕ КЛАСС", font: Fonts.medium, size: 12, color: UIPalette.amber, kern: 3.1, align: .left)
        lab.node.position = CGPoint(x: left, y: y - 6)
        content.addChild(lab.node)
        check.add("classLabel", node: lab.node)
        let line = SKSpriteNode(color: UIPalette.line, size: CGSize(width: max(1, cw - lab.width - 12), height: 1))
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.position = CGPoint(x: left + lab.width + 10, y: y - 6)
        content.addChild(line)
        y -= 18

        // class cards (web .ccard): 2 × 2 in portrait, a row of 4 in landscape; v1.1 rank chip + medal pips
        let perRow = landscape ? 4 : 2
        let gap: CGFloat = 8
        let cardW = (cw - gap * CGFloat(perRow - 1)) / CGFloat(perRow)
        let cardH: CGFloat = landscape ? (compact ? 66 : 76) : (compact ? 86 : 98)
        let hideIdx = landscape || W <= 380
        for (k, c) in MarineClass.allCases.enumerated() {
            let col = k % perRow, row = k / perRow
            let x = left + CGFloat(col) * (cardW + gap)
            let top = y - CGFloat(row) * (cardH + gap)
            let sel = c == selected
            let cc = UIPalette.classColors[k]
            let panel = Shapes.panel(width: cardW, height: cardH, fill: sel ? UIPalette.cardSel : UIPalette.panel,
                                     stroke: sel ? cc : UIPalette.line, lineWidth: sel ? 2 : 1)
            panel.position = CGPoint(x: x, y: top)
            panel.zPosition = -1
            content.addChild(panel)
            let chipBar = SKSpriteNode(color: cc, size: CGSize(width: 4, height: cardH - 8))
            chipBar.anchorPoint = CGPoint(x: 0, y: 1)
            chipBar.position = CGPoint(x: x, y: top)
            content.addChild(chipBar)
            let tx = x + (landscape ? 13 : 16)
            let rowY = top - (landscape ? 11 : 14)
            let rec = prof.record(c)
            let hasMeta = rec.runs > 0
            var mx = tx
            if !(hasMeta && hideIdx) {
                let idx = Label("0\(k + 1)", font: Fonts.mono, size: landscape ? 11 : 12, color: UIPalette.inkFaint, align: .left)
                idx.node.position = CGPoint(x: tx, y: rowY)
                content.addChild(idx.node)
                mx = tx + idx.width + 6
            }
            if hasMeta, let rk = MetaText.rankChip(profile: prof, cls: c) {
                // «ЗВ. N»: teal, a thin teal-dim outline (web .cc-rk)
                let chipL = Label(rk, font: Fonts.monoBold, size: 11, color: UIPalette.teal, align: .left)
                let cwid = chipL.width + 8
                let box = Shapes.panel(width: cwid, height: 16, cut: 0, fill: .clear, stroke: UIPalette.tealDim)
                box.position = CGPoint(x: mx, y: rowY + 8)
                content.addChild(box)
                chipL.node.position = CGPoint(x: mx + 4, y: rowY)
                content.addChild(chipL.node)
                mx += cwid + 6
                // Н · В · К: amber when that tier was evacuated with this class (web .cc-ev)
                for i in 0..<3 {
                    let on = rec.ev[i] > 0
                    let pip = Shapes.panel(width: 13, height: 15, cut: 0, fill: on ? UIPalette.amber : .clear, stroke: on ? nil : UIPalette.line)
                    pip.position = CGPoint(x: mx, y: rowY + 7.5)
                    content.addChild(pip)
                    let pl = Label(MetaText.tierAbbr[i], font: Fonts.monoBold, size: 10, color: on ? UIPalette.bg : UIPalette.inkFaint)
                    pl.node.position = CGPoint(x: mx + 6.5, y: rowY)
                    content.addChild(pl.node)
                    mx += 15
                }
            }
            let lnW: CGFloat = hasMeta ? 28 : min(46, cardW * 0.3)
            let ln = SKSpriteNode(color: cc, size: CGSize(width: lnW, height: 2))
            ln.anchorPoint = CGPoint(x: 1, y: 0.5)
            ln.position = CGPoint(x: x + cardW - 12, y: rowY)
            content.addChild(ln)
            let name = Label(c.spec.name.uppercased(), font: Fonts.bold, size: landscape ? 15 : 18, color: sel ? UIPalette.white : UIPalette.ink, kern: 0.7, align: .left)
            name.node.position = CGPoint(x: tx, y: top - (landscape ? (compact ? 26 : 28) : (compact ? 32 : 35)))
            content.addChild(name.node)
            let weapon = Label(c.spec.weapon, font: Fonts.regular, size: 12, color: UIPalette.inkDim, align: .left)
            weapon.node.position = CGPoint(x: tx, y: top - (landscape ? (compact ? 41 : 45) : (compact ? 50 : 56)))
            content.addChild(weapon.node)
            let ab = Label("◆ " + c.spec.ability, font: Fonts.medium, size: 12, color: UIPalette.amber, kern: 0.3, align: .left)
            ab.node.position = CGPoint(x: tx, y: top - (landscape ? (compact ? 55 : 62) : (compact ? 69 : 77)))
            content.addChild(ab.node)
            let r = CGRect(x: x, y: top - cardH, width: cardW, height: cardH)
            cards.append((c, r, panel))
            check.add("card." + c.id, r)
        }
        let rows = (MarineClass.allCases.count + perRow - 1) / perRow
        y -= CGFloat(rows) * (cardH + gap) + 6

        // tier row (web .t-tier): СЛОЖНОСТЬ + rule, three segments, the chosen tier's line
        y = tierRow(left: left, cw: cw, y: y, landscape: landscape, compact: compact, tier: meta.tier, narrow: W <= 380, check: &check)

        // «В бой» + «Звук» (web .t-actions), then the control hint and the profile line
        sound.setText("Звук: " + (soundOn ? "вкл" : "выкл"))
        let profLine = MetaText.titleProfileLine(profile: prof, cls: selected)
        let bh: CGFloat = landscape ? (compact ? 44 : 48) : (compact ? 48 : 54)
        var bottom = y
        if landscape {
            let goW = min(240, cw * 0.3), sw: CGFloat = min(170, cw * 0.2)
            go.layout(center: CGPoint(x: right - goW / 2, y: y - bh / 2), size: CGSize(width: goW, height: bh))
            sound.layout(center: CGPoint(x: right - goW - 10 - sw / 2, y: y - bh / 2), size: CGSize(width: sw, height: bh - 6))
            bottom = y - bh
            let hw = cw - goW - sw - 34
            var ly = y - 2
            if level < 1 {
                let hint = richParagraph(touchHintParts, size: 12, width: hw, align: .left)
                hint.position = CGPoint(x: left, y: ly)
                content.addChild(hint)
                check.add("hint", node: hint)
                ly -= hint.frame.height + 6
            }
            if let p = profLine {
                let best = Label(p, font: Fonts.mono, size: 12, color: UIPalette.teal, kern: 0.7, align: .left)
                best.node.position = CGPoint(x: left, y: ly - 8)
                content.addChild(best.node)
                check.add("profile", node: best.node)
                bottom = min(bottom, ly - 16)
            }
        } else {
            let sw = min(150, cw * 0.36)
            let goW = cw - sw - 10
            go.layout(center: CGPoint(x: left + goW / 2, y: y - bh / 2), size: CGSize(width: goW, height: bh))
            sound.layout(center: CGPoint(x: right - sw / 2, y: y - bh / 2), size: CGSize(width: sw, height: bh - 8))
            y -= bh + 12
            bottom = y + 12
            if level < 1 {
                let hint = richParagraph(touchHintParts, size: 12, width: cw, align: .left)
                hint.position = CGPoint(x: left, y: y)
                content.addChild(hint)
                check.add("hint", node: hint)
                y -= hint.frame.height + 12
                bottom = y + 12
            }
            if let p = profLine {
                let best = Label(p, font: Fonts.mono, size: prof.runs > 0 ? 13 : 12, color: UIPalette.teal, kern: 0.7, align: .left)
                best.node.position = CGPoint(x: left, y: y - 4)
                content.addChild(best.node)
                check.add("profile", node: best.node)
                bottom = y - 12
            }
        }
        check.add("go", go.rect)
        check.add("sound", sound.rect)
        return bottom >= -H / 2 + insets.bottom + 6
    }

    /// The tier selector. Portrait: head + rule, the three segments across the width, the line under them. Landscape
    /// (web max-height 500): head, segments sized to their text and the line in one row. Returns the next y.
    private func tierRow(left: CGFloat, cw: CGFloat, y y0: CGFloat, landscape: Bool, compact: Bool, tier: Int, narrow: Bool,
                         check: inout LayoutCheck) -> CGFloat {
        var y = y0 - (landscape ? 0 : 6)
        let head = Label("СЛОЖНОСТЬ", font: Fonts.medium, size: compact ? 11 : 12, color: UIPalette.amber, kern: compact ? 2.2 : 3.1, align: .left)
        let segH: CGFloat = compact && landscape ? 40 : 44
        let fs: CGFloat = narrow ? 12 : 13
        let names = Difficulty.tiers.map { $0.name.uppercased() }
        let line = Difficulty.tier(tier).line
        if landscape {
            let mid = y - segH / 2
            head.node.position = CGPoint(x: left, y: mid)
            content.addChild(head.node)
            check.add("tier.head", node: head.node)
            var x = left + head.width + 12
            for (i, n) in names.enumerated() {
                let l = Label(n, font: Fonts.semibold, size: fs, color: i == tier ? UIPalette.white : UIPalette.inkDim, kern: 0.8)
                let w = l.width + 24
                segment(x: x, top: y, w: w, h: segH, label: l, on: i == tier, red: i == 2)
                tierRects.append(CGRect(x: x, y: y - segH, width: w, height: segH))
                check.add("tier.\(i)", CGRect(x: x, y: y - segH, width: w, height: segH))
                x += w + 6
            }
            x += 6
            let lw = min(360, left + cw - x)
            if lw > 80 {
                let p = paragraph(line, font: Fonts.regular, size: compact ? 11 : 12, color: UIPalette.inkDim, width: lw, align: .left)
                p.horizontalAlignmentMode = .left
                p.position = CGPoint(x: x, y: mid + p.frame.height / 2)
                content.addChild(p)
                check.add("tier.line", node: p)
            }
            return y - segH - 8
        }
        head.node.position = CGPoint(x: left, y: y - 6)
        content.addChild(head.node)
        check.add("tier.head", node: head.node)
        let rule = SKSpriteNode(color: UIPalette.line, size: CGSize(width: max(1, cw - head.width - 12), height: 1))
        rule.anchorPoint = CGPoint(x: 0, y: 0.5)
        rule.position = CGPoint(x: left + head.width + 10, y: y - 6)
        content.addChild(rule)
        y -= compact ? 16 : 20
        let w = (cw - 12) / 3
        for (i, n) in names.enumerated() {
            let x = left + CGFloat(i) * (w + 6)
            let l = Label(n, font: Fonts.semibold, size: fs, color: i == tier ? UIPalette.white : UIPalette.inkDim, kern: narrow ? 0.4 : 0.65)
            segment(x: x, top: y, w: w, h: segH, label: l, on: i == tier, red: i == 2)
            tierRects.append(CGRect(x: x, y: y - segH, width: w, height: segH))
            check.add("tier.\(i)", CGRect(x: x, y: y - segH, width: w, height: segH))
        }
        y -= segH + 6
        let p = paragraph(line, font: Fonts.regular, size: 12, color: UIPalette.inkDim, width: cw, align: .left)
        p.horizontalAlignmentMode = .left
        p.position = CGPoint(x: left, y: y)
        content.addChild(p)
        check.add("tier.line", node: p)
        return y - p.frame.height - (compact ? 8 : 12)
    }

    /// One segment (web .tt-b): panel, 1 pt line; the chosen one card-sel with a 2 pt teal ring (red for Кошмар).
    private func segment(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat, label: Label, on: Bool, red: Bool) {
        let p = Shapes.panel(width: w, height: h, cut: 5, fill: on ? UIPalette.cardSel : UIPalette.panel,
                             stroke: on ? (red ? UIPalette.red : UIPalette.teal) : UIPalette.line, lineWidth: on ? 2 : 1)
        p.position = CGPoint(x: x, y: top)
        p.zPosition = -1
        content.addChild(p)
        label.node.position = CGPoint(x: x + w / 2, y: top - h / 2)
        content.addChild(label.node)
    }

    func hit(_ p: CGPoint) -> Action? {
        if go.hit(p) { return .start }
        if sound.hit(p) { return .sound }
        for (i, r) in tierRects.enumerated() where r.contains(p) { return .tier(i) }
        for (c, r, _) in cards where r.contains(p) { return .select(c) }
        return nil
    }
}
