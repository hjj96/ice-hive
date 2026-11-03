import SpriteKit
import UIKit
import IceHiveCore

// ================================================================
//  PAUSE / END — boxes with buttons (web .m-box with the hazard band).
//  Pause (v1.1): «PAUSE · VETERAN» and «Tutorial» after «Graphics».
//  End (v1.1, web D report): the core's MissionReport laid out in two
//  columns — A: tag, title, the stage strip, the score with its
//  breakdown and the tier line, the mini numbers; B: the class rank card,
//  a new medal, tips (loss cause, «longer», promo), the «Try Recruit» chip,
//  the next goal and the buttons, side by side (landscape-only: LAND),
//  the buttons above the fold. When the screen is short the layout
//  tightens, then drops the second tip.
// ================================================================
final class MenuScreen {
    enum Action: Equatable { case resume, sound, volume, quality, brightness, tutorial, haptics, quit, again, newStation, changeClass, chip }
    struct PauseState {
        var soundOn: Bool
        var volume: Float
        var quality: String
        var hapticsOn: Bool
        /// Brightness gamma (SettingsStore.brightnessSteps).
        var brightness: Float = 1
        /// The mission's tier (index), its name shown after the title.
        var tier: Int = Difficulty.veteran.index
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
        endBuild = nil
        root.isHidden = false
        content.removeFromParent()
        content = SKNode()
        root.addChild(content)
        buttons.removeAll()
        shade.size = size
    }


    /// Web qualityLabel(): «Graphics: auto (medium)» / «Graphics: low» …
    static func qualityLabel(_ q: String) -> String {
        if q == "auto" { return L10n.ui(.menuGraphicsAuto, .str(L10n.name(.quality(.med)))) }
        return L10n.ui(.menuGraphics, .str(L10n.name(.quality(QualityTier(rawValue: q) ?? .med))))
    }

    /// «Brightness: normal / high / max».
    static func brightnessLabel(_ g: Float) -> String {
        L10n.ui(.menuBrightness, .str(L10n.ui(g >= 1.25 ? .menuBrightnessMax : (g > 1.05 ? .menuBrightnessHigh : .menuBrightnessNormal))))
    }

    /// «Sound: on» / «Vibration: off».
    static func onOff(_ k: UIText, _ on: Bool) -> String { L10n.ui(k, .str(L10n.ui(on ? .menuOn : .menuOff))) }

    /// Box background + hazard band, top-left at (x, top).
    private func box(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, edge: SKColor? = nil) {
        let p = Shapes.panelStretch(width: width, height: height, fill: UIPalette.panel2, stroke: edge ?? UIPalette.line)
        p.position = CGPoint(x: x, y: top)
        p.zPosition = -3
        content.addChild(p)
        let hz = hazardBand(width: width, height: 8)
        hz.position = CGPoint(x: x, y: top)
        hz.zPosition = -2.5
        content.addChild(hz)
    }

    // ---------------------------------------------------------------- pause
    /// The pause box for a landscape phone (LAND): «PAUSE · VETERAN» across the top, two columns of 44-pt buttons —
    /// left the mission (Resume, Tutorial, Abort) with the control hint under them, right the settings (Sound,
    /// Volume, Graphics, Brightness, Vibration). A short screen (< 390 pt) packs the rows 6 pt tighter.
    func showPause(size: CGSize, state: PauseState, layoutCheck: Bool = false, insets: UIEdgeInsets = .zero) {
        reset(size: size)
        let sl = max(16, insets.left), sr = max(16, insets.right)
        let short = size.height - insets.top - insets.bottom < 390
        let colGap: CGFloat = 16, padX: CGFloat = 22
        let colW = max(200, min(270, (size.width - sl - sr - 2 * padX - colGap) / 2))
        let w = 2 * colW + colGap
        let bh: CGFloat = 44, step: CGFloat = short ? 50 : 54
        let mission: [(String, MenuButton.Style, Action)] = [
            (L10n.ui(.pauseResume), .normal, .resume),
            (L10n.ui(.pauseTutorial), .ghost, .tutorial),
            (L10n.ui(.pauseQuit), .danger, .quit)]
        let settings: [(String, MenuButton.Style, Action)] = [
            (MenuScreen.onOff(.menuSound, state.soundOn), .ghost, .sound),
            (L10n.ui(.menuVolume, .int(Int((state.volume * 100).rounded()))), .ghost, .volume),
            (MenuScreen.qualityLabel(state.quality), .ghost, .quality),
            (MenuScreen.brightnessLabel(state.brightness), .ghost, .brightness),
            (MenuScreen.onOff(.menuHaptics, state.hapticsOn), .ghost, .haptics)]
        let titleH: CGFloat = short ? 48 : 56
        let rowsH = CGFloat(settings.count) * step - (step - bh)
        let boxH = 8 + titleH + rowsH + (short ? 16 : 20)
        let bw = w + 2 * padX
        // centred, never above the safe top or below the safe bottom
        var top = boxH / 2
        top = min(top, size.height / 2 - insets.top - 6)
        top = max(top, -size.height / 2 + insets.bottom + 6 + boxH)
        box(x: -bw / 2, top: top, width: bw, height: boxH)
        var check = LayoutCheck("pause")
        check.add("box", CGRect(x: -bw / 2, y: top - boxH, width: bw, height: boxH))
        // «PAUSE · VETERAN» (web .p-tier: half size, ink-dim)
        let ts: CGFloat = short ? 28 : 32
        let x0 = -w / 2
        let title = Label(L10n.upper(L10n.ui(.pauseTitle)), font: Fonts.bold, size: ts, color: UIPalette.ink, kern: 4, align: .left)
        title.node.position = CGPoint(x: x0, y: top - 8 - titleH / 2)
        content.addChild(title.node)
        check.add("title", node: title.node)
        let tier = Label("· " + L10n.upper(L10n.name(.tier(state.tier))), font: Fonts.semibold, size: ts * 0.5, color: UIPalette.inkDim,
                         kern: ts * 0.06, align: .left)
        tier.node.position = CGPoint(x: x0 + title.width + ts * 0.4, y: top - 8 - titleH / 2)
        content.addChild(tier.node)
        check.add("tier", node: tier.node)
        let y0 = top - 8 - titleH - bh / 2
        for (col, items) in [(0, mission), (1, settings)] {
            var y = y0
            let cx = x0 + colW / 2 + CGFloat(col) * (colW + colGap)
            for it in items {
                let b = MenuButton(it.0, style: it.1, fontSize: 15)
                MenuScreen.fit(b.label, colW - 16)
                check.text("text.btn." + String(describing: it.2), width: b.label.width, room: colW - 16)
                b.layout(center: CGPoint(x: cx, y: y), size: CGSize(width: colW, height: bh))
                content.addChild(b.node)
                buttons.append((b, it.2))
                check.add("btn." + String(describing: it.2), b.rect)
                check.tap("btn." + String(describing: it.2), b.hitRect)
                y -= step
            }
            // under the mission column: how the sticks work (the pause is where a player looks it up)
            if col == 0 {
                let hintTop = y + step - bh / 2 - 12
                let room = hintTop - (top - boxH + 12)
                if room >= 30 {
                    let hint = richParagraph(pauseHintParts, size: 12, width: colW, align: .left)
                    if hint.frame.height <= room {
                        hint.position = CGPoint(x: x0, y: hintTop)
                        content.addChild(hint)
                        check.add("hint", node: hint)
                    }
                }
            }
        }
        if layoutCheck { check.report(size: size, insets: insets) }
    }

    // ---------------------------------------------------------------- report
    /// One laid-out piece of a report column: `node` has its top-left corner at its origin (content grows downward).
    private struct Block {
        let name: String
        let node: SKNode
        let height: CGFloat
        /// Space above it (0 for the first block of a column).
        var gapAbove: CGFloat
        /// Rects of tappable children (relative to the block origin) and their actions.
        var taps: [(MenuButton, Action)] = []
        /// Texts in it that must fit their room (name, width as drawn, room): the layout check.
        var texts: [(String, CGFloat, CGFloat)] = []
    }

    /// Fonts and spacing of one density step (web media queries for short / narrow screens).
    private struct Density {
        let title: CGFloat, total: CGFloat, line: CGFloat, lineH: CGFloat, tip: CGFloat, gap: CGFloat, strip: CGFloat
        let mini: CGFloat, miniH: CGFloat, btn: CGFloat, btn2: CGFloat, chipH: CGFloat
        static let landscape = Density(title: 24, total: 26, line: 12, lineH: 15, tip: 12, gap: 6, strip: 18, mini: 14, miniH: 34,
                                       btn: 44, btn2: 38, chipH: 38)
        static let landscapeTight = Density(title: 22, total: 22, line: 11, lineH: 13.5, tip: 11, gap: 5, strip: 16, mini: 13, miniH: 30,
                                            btn: 38, btn2: 34, chipH: 34)
    }

    /// The report built in one go (a rotation over the report, the warm-up behind the loading cover).
    func showEnd(size: CGSize, insets: UIEdgeInsets, report: MissionReport, layoutCheck: Bool = false) {
        beginEnd(size: size, insets: insets, report: report, layoutCheck: layoutCheck)
        while endBuild != nil { stepEnd() }
    }

    /// The mission-end report over a few frames (built in one frame it cost 63–74 ms on CI): column A, then column B
    /// with the fit check, per density, then the placement — the screen appears with that last step (stepEnd).
    private struct EndBuild {
        let report: MissionReport, size: CGSize, insets: UIEdgeInsets, layoutCheck: Bool
        var density = 0
        var columnA: [Block]? = nil
        var pick: ([Block], [Block], Density)? = nil
        var last: ([Block], [Block], Density)? = nil
    }
    private var endBuild: EndBuild? = nil
    /// A report is being built (hidden until its last step).
    var endPending: Bool { endBuild != nil }

    func beginEnd(size: CGSize, insets: UIEdgeInsets, report: MissionReport, layoutCheck: Bool = false) {
        reset(size: size)
        root.isHidden = true
        endBuild = EndBuild(report: report, size: size, insets: insets, layoutCheck: layoutCheck)
    }

    /// Box geometry of the report on this screen.
    private func endGeometry(_ size: CGSize, _ insets: UIEdgeInsets) -> (bw: CGFloat, padX: CGFloat, colW: CGFloat,
                                                                          availH: CGFloat, densities: [Density]) {
        let W = size.width, H = size.height
        let sl = max(12, insets.left), sr = max(12, insets.right)
        let availH = H - insets.top - insets.bottom - 16
        // box: two columns up to 860
        let bw = min(860, W - sl - sr)
        let padX: CGFloat = 16
        let colGap: CGFloat = 20
        let colW = (bw - 2 * padX - colGap) / 2
        return (bw, padX, colW, availH, [.landscape, .landscapeTight])
    }

    /// One piece of the pending report per call (the scene calls it once a frame); true once it is on screen.
    @discardableResult
    func stepEnd() -> Bool {
        guard var e = endBuild else { return true }
        let gm = endGeometry(e.size, e.insets)
        let colW = gm.colW
        if e.pick == nil && e.density < gm.densities.count {
            let d = gm.densities[e.density]
            guard let a0 = e.columnA else {
                e.columnA = columnA(report: e.report, d: d, colW: colW)   // web: no subtitle on landscape phones
                endBuild = e
                return false
            }
            // the second tip is dropped by filtering the blocks (each density is built once)
            let b0 = columnB(report: e.report, d: d, colW: colW)
            for tips2 in [true, false] {
                let a = a0
                let b = tips2 ? b0 : b0.filter { $0.name != "tip1" }
                e.last = (a, b, d)
                if boxHeight(a, b, d) <= gm.availH { e.pick = (a, b, d); break }
            }
            e.density += 1
            e.columnA = nil
            if e.pick != nil || e.density < gm.densities.count { endBuild = e; return false }
        }
        endBuild = nil
        guard let (a, b, d) = e.pick ?? e.last else { return true }
        let size = e.size, insets = e.insets, report = e.report
        let H = size.height, bw = gm.bw, padX = gm.padX, colGap: CGFloat = 20
        let availH = gm.availH
        if e.pick == nil { AppLog.info("report: tightest layout \(Int(boxHeight(a, b, d))) pt for \(Int(availH)) pt") }
        let hA = stackHeight(a), hB = stackHeight(b)
        let topPad: CGFloat = 8 + 10, botPad: CGFloat = 14
        let boxH = topPad + max(hA, hB) + botPad
        // centred, never above the safe top or below the safe bottom
        var top = boxH / 2
        top = min(top, H / 2 - insets.top - 8)
        top = max(top, -H / 2 + insets.bottom + 8 + boxH)
        let x0 = -bw / 2
        box(x: x0, top: top, width: bw, height: boxH, edge: report.won ? UIPalette.rgba(63, 227, 210, 0.45) : UIPalette.rgba(255, 59, 59, 0.45))
        var check = LayoutCheck("report")
        let ax = x0 + padX, bx = x0 + padX + colW + colGap
        let yA = top - topPad
        place(a, x: ax, top: yA, check: &check)
        place(b, x: bx, top: yA, check: &check)
        if e.layoutCheck { check.report(size: size, insets: insets) }
        root.isHidden = false
        return true
    }

    private func stackHeight(_ blocks: [Block]) -> CGFloat {
        var h: CGFloat = 0
        for b in blocks { h += b.gapAbove + b.height }
        return h
    }

    private func place(_ blocks: [Block], x: CGFloat, top: CGFloat, check: inout LayoutCheck) {
        var y = top
        for b in blocks {
            y -= b.gapAbove
            b.node.position = CGPoint(x: x, y: y)
            content.addChild(b.node)
            check.add(b.name, CGRect(x: x, y: y - b.height, width: b.node.calculateAccumulatedFrame().width, height: b.height))
            for (n, w, room) in b.texts { check.text(n, width: w, room: room) }
            for (btn, act) in b.taps {
                // the button rects become screen rects (block origin + the button's own rect)
                btn.offset(by: CGPoint(x: x, y: y))
                buttons.append((btn, act))
                check.tap(b.name + "." + String(describing: act), btn.hitRect)
            }
            y -= b.height
        }
    }

    private func boxHeight(_ a: [Block], _ b: [Block], _ d: Density) -> CGFloat {
        let topPad: CGFloat = 8 + 10, botPad: CGFloat = 14
        return topPad + max(stackHeight(a), stackHeight(b)) + botPad
    }

    /// Column A: tag, title, strip, score, breakdown + tier line, mini numbers (no subtitle: web landscape phones).
    private func columnA(report r: MissionReport, d: Density, colW: CGFloat) -> [Block] {
        var out: [Block] = []
        var texts: [(String, CGFloat, CGFloat)] = []
        func push(_ b0: Block) { var b = b0; b.texts = texts; texts = []; out.append(b) }
        let tagN = SKNode()
        let tag = Label(L10n.upper(L10n.string(r.tag)), font: Fonts.mono, size: 12, color: UIPalette.inkDim, kern: 2.4, align: .left)
        MenuScreen.fit(tag, colW, minSize: 7)
        texts.append(("text.tag", tag.width, colW))
        tag.node.position = CGPoint(x: 0, y: -6)
        tagN.addChild(tag.node)
        push(Block(name: "tag", node: tagN, height: 12, gapAbove: 0))
        let tN = SKNode()
        let title = Label(L10n.upper(L10n.string(r.title)), font: Fonts.bold, size: d.title, color: r.won ? UIPalette.teal : UIPalette.red,
                          kern: d.title * 0.1, align: .left)
        MenuScreen.fit(title, colW)
        texts.append(("text.title", title.width, colW))
        title.node.position = CGPoint(x: 0, y: -d.title * 0.5)
        tN.addChild(title.node)
        push(Block(name: "title", node: tN, height: d.title, gapAbove: 6))
        // the stage strip (web .r-strip: 4 × 1fr, 1.2fr, 1.75fr; 3 pt top border; teal on a win, amber on a loss)
        let stN = SKNode()
        let fr: [CGFloat] = [1, 1, 1, 1, 1.2, 1.75]
        let unit = (colW - 15) / fr.reduce(0, +)
        var x: CGFloat = 0
        let onColor = r.won ? UIPalette.teal : UIPalette.amber
        for (k, it) in r.strip.enumerated() {
            let w = unit * fr[k]
            let bar = SKSpriteNode(color: it.on ? onColor : UIPalette.line, size: CGSize(width: w, height: 3))
            bar.anchorPoint = CGPoint(x: 0, y: 1)
            bar.position = CGPoint(x: x, y: 0)
            stN.addChild(bar)
            let l = Label(L10n.upper(L10n.string(it.label)), font: Fonts.medium, size: d.strip < 18 ? 9 : 10, color: it.on ? onColor : UIPalette.inkFaint,
                          kern: 0.6, valign: .baseline)
            // (a stage name wider than its segment shrinks: SE's segments are ~35 pt)
            MenuScreen.fit(l, w - 2, minSize: 5.5)
            texts.append(("text.strip\(k)", l.width, w - 2))
            // one baseline for the row, caps centred in the slot (Oswald cap height 0.81 em): «QUEEN»'s Q tail no
            // longer lifts it above its neighbours as glyph-box centring did
            l.node.position = CGPoint(x: x + w / 2, y: -3 - (d.strip - 3) / 2 - l.size * 0.405)
            stN.addChild(l.node)
            x += w + 3
        }
        push(Block(name: "strip", node: stN, height: d.strip, gapAbove: d.gap))
        // SCORE 6,228 + «NEW RECORD» / «best N»
        let scN = SKNode()
        let base = -d.total * 0.86
        let lab = Label(L10n.upper(L10n.string(r.scoreLabel)), font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 2.4, align: .left, valign: .baseline)
        lab.node.position = CGPoint(x: 0, y: base)
        scN.addChild(lab.node)
        let tot = Label(L10n.num(r.scoreTotal), font: Fonts.monoBold, size: d.total, color: UIPalette.ink, align: .left, valign: .baseline)
        tot.node.position = CGPoint(x: lab.width + 10, y: base)
        scN.addChild(tot.node)
        if let noteText = r.scoreNote {
            let note = L10n.string(noteText)
            let nx = lab.width + 10 + tot.width + 10
            if r.record {
                let nl = Label(L10n.upper(note), font: Fonts.bold, size: 11, color: UIPalette.bg, kern: 1.5, align: .left)
                MenuScreen.fit(nl, max(20, colW - nx - 14), minSize: 7)
                texts.append(("text.record", nl.width + 14, colW - nx))
                let bwid = nl.width + 14
                let chip = Shapes.panel(width: bwid, height: 21, cut: 0, fill: UIPalette.amber)
                chip.position = CGPoint(x: nx, y: -d.total * 0.5 + 10.5)
                scN.addChild(chip)
                nl.node.position = CGPoint(x: nx + 7, y: -d.total * 0.5)
                nl.node.zPosition = 1
                scN.addChild(nl.node)
            } else {
                let nl = Label(note, font: Fonts.mono, size: 12, color: UIPalette.inkFaint, align: .left, valign: .baseline)
                MenuScreen.fit(nl, max(20, colW - nx), minSize: 7)
                texts.append(("text.best", nl.width, colW - nx))
                nl.node.position = CGPoint(x: nx, y: base)
                scN.addChild(nl.node)
            }
        }
        push(Block(name: "score", node: scN, height: d.total, gapAbove: d.gap - 1))
        // breakdown (web .r-lines): 2 pt rule on the left, label left, «+N» right; the tier line in amber
        let lnN = SKNode()
        var ly: CGFloat = 0
        let rows = r.parts.map { (L10n.string($0.label), L10n.string($0.value), false) }
            + [(L10n.string(r.tierLine), r.tierDelta.map { L10n.string($0) } ?? "", true)]
        for (lbl, val, amber) in rows {
            let cy = ly - d.lineH / 2
            let a = Label(lbl, font: Fonts.regular, size: d.line, color: amber ? UIPalette.amber : UIPalette.inkDim, kern: 0.2, align: .left)
            MenuScreen.fit(a, colW - 12 - 70, minSize: 7)
            texts.append(("text.line." + String(lbl.prefix(12)), a.width, colW - 12 - 70))
            a.node.position = CGPoint(x: 12, y: cy)
            lnN.addChild(a.node)
            if !val.isEmpty {
                let v = Label(val, font: Fonts.monoBold, size: d.line, color: amber ? UIPalette.amber : UIPalette.ink, align: .right)
                v.node.position = CGPoint(x: colW, y: cy)
                lnN.addChild(v.node)
            }
            ly -= d.lineH + 1
        }
        let rule = SKSpriteNode(color: UIPalette.line, size: CGSize(width: 2, height: -ly - 1))
        rule.anchorPoint = CGPoint(x: 0, y: 1)
        lnN.addChild(rule)
        push(Block(name: "lines", node: lnN, height: -ly - 1, gapAbove: d.gap - 1))
        // mini numbers (web .stats.mini): Time / Combo / Accuracy / Level
        let mN = SKNode()
        let cellW = colW / 4
        for (k, m) in r.mini.enumerated() {
            let cx = CGFloat(k) * cellW
            let cell = Shapes.panel(width: cellW - 1, height: d.miniH, cut: 0, fill: UIPalette.panel, stroke: UIPalette.line)
            cell.position = CGPoint(x: cx, y: 0)
            cell.zPosition = -1
            mN.addChild(cell)
            let a = Label(L10n.upper(L10n.string(m.label)), font: Fonts.medium, size: 10, color: UIPalette.inkDim, kern: 0.6, align: .left)
            MenuScreen.fit(a, cellW - 14, minSize: 6)
            texts.append(("text.mini\(k)", a.width, cellW - 14))
            a.node.position = CGPoint(x: cx + 8, y: -d.miniH * 0.3)
            mN.addChild(a.node)
            let v = Label(L10n.string(m.value), font: Fonts.monoBold, size: d.mini, color: UIPalette.ink, align: .left)
            v.node.position = CGPoint(x: cx + 8, y: -d.miniH * 0.68)
            mN.addChild(v.node)
        }
        push(Block(name: "mini", node: mN, height: d.miniH, gapAbove: d.gap))
        return out
    }

    /// Column B: rank card, medal, tips, chip, goal, buttons.
    private func columnB(report r: MissionReport, d: Density, colW: CGFloat) -> [Block] {
        var out: [Block] = []
        var texts: [(String, CGFloat, CGFloat)] = []
        func push(_ b0: Block) { var b = b0; b.texts = texts; texts = []; out.append(b) }
        // rank card (web .r-rank): «ASSAULT · SERGEANT» + «+623 service XP», teal bar, «NEW RANK: …»
        let rkN = SKNode()
        let padT: CGFloat = d.gap >= 9 ? 9 : 7
        let rt = Label(L10n.upper(L10n.string(r.rankTitle)), font: Fonts.semibold, size: d.line, color: UIPalette.ink, kern: 1, align: .left)
        rt.node.position = CGPoint(x: 10, y: -padT - 7)
        rkN.addChild(rt.node)
        let xp = Label(L10n.string(r.xpLine), font: Fonts.mono, size: 12, color: UIPalette.teal, align: .right)
        MenuScreen.fit(xp, colW * 0.4, minSize: 8)
        xp.node.position = CGPoint(x: colW - 10, y: -padT - 7)
        rkN.addChild(xp.node)
        MenuScreen.fit(rt, colW - 20 - xp.width - 10, minSize: 6)
        texts.append(("text.rank", rt.width, colW - 20 - xp.width - 10))
        var ry = -padT - 14 - (d.gap >= 9 ? 8 : 6)
        let bar = Bar(width: colW - 20, height: 6, fill: UIPalette.teal, track: UIPalette.tealTrack)
        bar.set(CGFloat(r.rankFill))
        bar.node.position = CGPoint(x: 10, y: ry - 3)
        rkN.addChild(bar.node)
        ry -= 6
        if let up = r.rankUp {
            ry -= d.gap >= 9 ? 7 : 5
            let u = Label(L10n.upper(L10n.string(up)), font: Fonts.bold, size: d.line, color: UIPalette.amber, kern: 1.5, align: .left)
            MenuScreen.fit(u, colW - 20, minSize: 7)
            texts.append(("text.rankUp", u.width, colW - 20))
            u.node.position = CGPoint(x: 10, y: ry - d.line * 0.5)
            rkN.addChild(u.node)
            ry -= d.line
        }
        let rkH = -ry + padT
        let card = Shapes.panel(width: colW, height: rkH, cut: 0, fill: UIPalette.panel, stroke: UIPalette.line)
        card.zPosition = -1
        rkN.addChild(card)
        push(Block(name: "rank", node: rkN, height: rkH, gapAbove: 0))
        if let m = r.medal {
            let mN = SKNode()
            // the diamond comes from JetBrains Mono (Oswald has no ◆: no system-font fallback)
            let dia = Label(Glyphs.diamond, font: Fonts.monoBold, size: d.line, color: UIPalette.amber, align: .left)
            dia.node.position = CGPoint(x: 0, y: -d.line * 0.6)
            mN.addChild(dia.node)
            let lx = dia.width + d.line * 0.4
            let l = Label(L10n.upper(L10n.string(m)), font: Fonts.semibold, size: d.line, color: UIPalette.amber, kern: 0.8, align: .left)
            MenuScreen.fit(l, colW - lx, minSize: 7)
            texts.append(("text.medal", l.width, colW - lx))
            l.node.position = CGPoint(x: lx, y: -d.line * 0.6)
            mN.addChild(l.node)
            push(Block(name: "medal", node: mN, height: d.line * 1.25, gapAbove: d.gap))
        }
        // tips: the loss cause on red-dim, «longer» / promo on teal-dim (wrapped; TextWarmup lays them out at launch)
        for (k, t) in r.tips.enumerated() {
            let tN = SKNode()
            let padY: CGFloat = d.gap >= 9 ? 7 : 5
            let p = paragraph(L10n.string(t.text), font: Fonts.regular, size: d.tip, color: UIPalette.ink, width: colW - 18, align: .left)
            p.horizontalAlignmentMode = .left
            p.position = CGPoint(x: 9, y: -padY)
            tN.addChild(p)
            let h = p.frame.height + 2 * padY
            let bg = SKSpriteNode(color: t.good ? UIPalette.tealDim : UIPalette.redDim, size: CGSize(width: colW, height: h))
            bg.anchorPoint = CGPoint(x: 0, y: 1)
            bg.zPosition = -1
            tN.addChild(bg)
            push(Block(name: "tip\(k)", node: tN, height: h, gapAbove: d.gap))
        }
        if let c = r.chip {
            let cN = SKNode()
            let b = MenuButton(L10n.string(c), style: .chip, fontSize: 14)
            MenuScreen.fit(b.label, colW - 28, minSize: 8)
            texts.append(("text.chip", b.label.width, colW - 28))
            let w = b.label.width + 28
            b.layout(center: CGPoint(x: w / 2, y: -d.chipH / 2), size: CGSize(width: w, height: d.chipH))
            cN.addChild(b.node)
            push(Block(name: "chip", node: cN, height: d.chipH, gapAbove: d.gap, taps: [(b, .chip)]))
        }
        // the next goal: «▸ » amber (JetBrains Mono: Oswald has no ▸) + the goal in teal (one paragraph, may wrap)
        let gN = SKNode()
        let g = goalParagraph(L10n.string(r.goal), size: d.line, width: colW)
        gN.addChild(g)
        push(Block(name: "goal", node: gN, height: g.frame.height, gapAbove: d.gap))
        // buttons: the primary one full width, the others side by side under it
        let bN = SKNode()
        var taps: [(MenuButton, Action)] = []
        let prim = MenuButton(L10n.string(r.primary.title), style: .go, fontSize: d.btn >= 50 ? 20 : 17)
        MenuScreen.fit(prim.label, colW - 16, minSize: 9)
        texts.append(("text.btn.primary", prim.label.width, colW - 16))
        prim.layout(center: CGPoint(x: colW / 2, y: -d.btn / 2), size: CGSize(width: colW, height: d.btn))
        bN.addChild(prim.node)
        taps.append((prim, MenuScreen.action(r.primary)))
        let others = r.buttons.filter { $0 != r.primary }
        let ow = (colW - CGFloat(max(0, others.count - 1)) * 8) / CGFloat(max(1, others.count))
        for (k, o) in others.enumerated() {
            let b = MenuButton(L10n.string(o.title), style: .ghost, fontSize: d.btn >= 50 ? 14 : 13)
            MenuScreen.fit(b.label, ow - 16, minSize: 8)
            texts.append(("text.btn.\(k)", b.label.width, ow - 16))
            b.layout(center: CGPoint(x: CGFloat(k) * (ow + 8) + ow / 2, y: -d.btn - 8 - d.btn2 / 2), size: CGSize(width: ow, height: d.btn2))
            bN.addChild(b.node)
            taps.append((b, MenuScreen.action(o)))
        }
        let bh = d.btn + (others.isEmpty ? 0 : 8 + d.btn2)
        push(Block(name: "buttons", node: bN, height: bh, gapAbove: d.gap + 2, taps: taps))
        return out
    }

    /// A one-line label wider than `w` gets a smaller font (the same font; the tightest phones, longer languages), not
    /// below `minSize`. Letter spacing does not shrink with the font, so the size is solved for the glyphs alone and
    /// checked again; a label still too wide at `minSize` loses its letter spacing.
    static func fit(_ l: Label, _ w: CGFloat, minSize: CGFloat = 9) {
        guard w > 20 else { return }
        var lw = l.width
        var tries = 0
        while lw > w + 0.25 && tries < 4 {
            tries += 1
            if l.size > minSize {
                let k = l.kern * CGFloat(l.text.count)
                let glyphs = max(1, lw - k)
                let target = (l.size * max(1, w - k) / glyphs * 10).rounded(.down) / 10
                l.size = max(minSize, min(l.size - 0.1, target))
            } else if l.kern > 0 {
                l.kern = 0
                l.set(l.text, force: true)
            } else {
                break
            }
            lw = l.width
        }
    }

    private static func action(_ b: ReportButton) -> Action {
        switch b {
        case .again: return .again
        case .newStation: return .newStation
        case .changeClass: return .changeClass
        }
    }

    /// «▸ » in amber, then the goal in teal (web .r-goal), left-aligned, wrapping at `width`.
    private func goalParagraph(_ text: String, size: CGFloat, width: CGFloat) -> SKLabelNode {
        let l = SKLabelNode()
        l.numberOfLines = 0
        l.preferredMaxLayoutWidth = width
        l.horizontalAlignmentMode = .left
        l.verticalAlignmentMode = .top
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineSpacing = 2
        let s = NSMutableAttributedString(string: Glyphs.pointer + " ", attributes: [
            .font: Fonts.font(Fonts.monoBold, size), .foregroundColor: UIPalette.amber, .paragraphStyle: style])
        s.append(NSAttributedString(string: text, attributes: [.font: Fonts.font(Fonts.medium, size), .foregroundColor: UIPalette.teal,
                                                              .paragraphStyle: style]))
        l.attributedText = s
        LabelStats.textsSet += 1
        return l
    }

    func hide() { root.isHidden = true; endBuild = nil }

    func hit(_ p: CGPoint) -> Action? {
        if root.isHidden { return nil }
        // compact rows sit 5 pt apart, so the 44-pt tap areas of neighbours overlap: the nearest drawn button wins
        var best: (CGFloat, Action)? = nil
        for (b, a) in buttons where b.hit(p) {
            let d = b.distance(to: p)
            if best == nil || d < best!.0 { best = (d, a) }
        }
        return best?.1
    }
}
