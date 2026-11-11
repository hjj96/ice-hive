import UIKit
import IceHiveCore

// ================================================================
//  TEXT WARM-UP — the first wrapped (multi-line) label of a process
//  can stall the main thread for seconds: CI saw 1.5 / 7.2 / 7.4 /
//  9.4 s on the first two-line toast (a first-sighting bug tip, 14 s
//  into a mission) while single-line labels and explicit line breaks
//  never did — text layout loads its line-breaking data on first use.
//  At launch, behind the loading cover, every wrapped string the HUD
//  and the screens show is laid out and drawn once on a background
//  queue with the same fonts, so that first use is paid there and never
//  in a mission. The strings come from the catalog (the same GameText
//  the game and the screens resolve), not from hand-written samples.
// ================================================================
enum TextWarmup {
    private static var started = false

    /// Main thread, once (from loadView): the strings are resolved here (L10n is main-thread only), the layout and
    /// drawing — the part that stalls — run on a background queue.
    static func start() {
        guard !started else { return }
        started = true
        let scale = UIScreen.main.nativeScale
        let items = build()
        DispatchQueue.global(qos: .utility).async {
            let t0 = FrameTimer.now()
            let n = draw(items, scale: scale)
            AppLog.info(String(format: "text warm-up: %d wrapped strings in %.0f ms", n, (FrameTimer.now() - t0) * 1000))
        }
    }

    /// Every toast a mission can raise that may wrap (bug tips, the squad's down / up lines by call-sign, the
    /// medkit, the upgrade names): the warm-up's and the HUD's toast-label cache's list.
    static func toastTexts() -> [GameText] {
        var out: [GameText] = BugType.allCases.compactMap { GameText.bugTip($0) }
        out += [GameText.downToast(.player), GameText.upToast(.player), GameText.medkitToast(40)]
        for c in MarineClass.allCases { out += [GameText.downToast(.callsign(c)), GameText.upToast(.callsign(c))] }
        // Stage 1 R4: the overhead's tips and the pin's radio lines
        out += [GameText.perchTip, GameText.ductTip]
        for c in MarineClass.allCases { out += [GameText.matePinned(.callsign(c)), GameText.pinFreed(.callsign(c))] }
        // Stage 1 R6: the interactive props' barks and first-sighting tips
        out += [GameText(.toastLightsCut), GameText(.toastLightsUp), GameText(.toastLocker), GameText(.toastTipValve),
                GameText(.toastTipBreaker), GameText(.toastTipLocker)]
        return out
    }

    /// Lay out and draw each string wrapped at the widths the HUD uses (toasts are right-aligned with letter spacing,
    /// cards and paragraphs left / centred with line spacing).
    private static func build() -> [(NSAttributedString, CGFloat)] {
        var toasts = toastTexts().map { L10n.string($0) }
        toasts += UPGRADES.map { L10n.string(GameText(.toastUpgrade, [.name($0.name)])) }
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let left = NSMutableParagraphStyle()
        left.alignment = .left
        left.lineSpacing = 2
        let centre = NSMutableParagraphStyle()
        centre.alignment = .center
        centre.lineSpacing = 2
        // the toast width of this screen in landscape (HUD.toast: min(320, 0.6 × width) − 22)
        let b = UIScreen.main.bounds
        let toastW = min(320, 0.6 * max(b.width, b.height)) - 22
        var items: [(NSAttributedString, CGFloat)] = []
        for t in toasts {
            let s = NSAttributedString(string: L10n.upper(t), attributes: [
                .font: Fonts.font(Fonts.medium, 12), .foregroundColor: UIPalette.ink, .kern: CGFloat(1.0), .paragraphStyle: right])
            items.append((s, toastW))
        }
        for u in UPGRADES {
            items.append((NSAttributedString(string: L10n.string(u.desc), attributes: [
                .font: Fonts.font(Fonts.regular, 13), .foregroundColor: UIPalette.inkDim, .paragraphStyle: left]), 160))
        }
        // v1.1: the tier lines of the title row, the report's tips (loss causes, pressure, promo, «longer»), the goal
        // patterns and the coach / revive lines, at the title / report column widths of the landscape phones
        for d in Difficulty.tiers {
            for w in [362, 335, 360] as [CGFloat] {
                items.append((NSAttributedString(string: L10n.name(.tierLine(d.index)), attributes: [.font: Fonts.font(Fonts.regular, 12), .paragraphStyle: left]), w))
            }
        }
        var tips: [GameText] = MetaText.lossTips + [MetaText.pressTip, MetaText.promo, GameText(.tipLonger, [.clock(62)])]
        for c in MarineClass.allCases {
            tips.append(GameText(MetaText.firstWinGoal(c), [.num(1500)]))
            tips.append(GameText(MetaText.medalGoal(c), [.name(.tier(0))]))
        }
        tips += [GameText(.goalRank, [.name(.rank(2)), .num(1234)]), GameText(.goalBest, [.num(12_345)])]
        for t in tips.map({ L10n.string($0) }) {
            for (w, sz) in [(324, 13), (313, 12.5), (331, 12)] as [(CGFloat, CGFloat)] {
                items.append((NSAttributedString(string: t, attributes: [.font: Fonts.font(Fonts.regular, sz), .paragraphStyle: left]), w))
            }
            let g = NSMutableAttributedString(string: Glyphs.pointer + " ", attributes: [.font: Fonts.font(Fonts.monoBold, 13), .paragraphStyle: left])
            g.append(NSAttributedString(string: t, attributes: [.font: Fonts.font(Fonts.medium, 13), .paragraphStyle: left]))
            items.append((g, 342))
        }
        for (font, style) in [(Fonts.regular, centre), (Fonts.semibold, left)] {
            items.append((NSAttributedString(string: L10n.ui(.titlePremise), attributes: [.font: Fonts.font(font, 13), .kern: CGFloat(0.5), .paragraphStyle: style]), 300))
        }
        return items
    }

    private static func draw(_ items: [(NSAttributedString, CGFloat)], scale: CGFloat) -> Int {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 120), format: fmt)
        _ = renderer.image { ctx in
            for (s, w) in items {
                let r = s.boundingRect(with: CGSize(width: w, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                s.draw(with: CGRect(x: 0, y: 0, width: w, height: ceil(r.height)), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                ctx.cgContext.clear(CGRect(x: 0, y: 0, width: 320, height: 120))
            }
        }
        return items.count
    }
}
