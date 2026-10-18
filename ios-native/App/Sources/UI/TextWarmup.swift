import UIKit
import IceHiveCore

// ================================================================
//  TEXT WARM-UP — the first wrapped (multi-line) label of a process
//  can stall the main thread for seconds: CI saw 1.5 / 7.2 / 7.4 /
//  9.4 s on the first two-line toast («Плевун: плюётся кислотой —
//  уходите из кругов», 14 s into a mission) while single-line labels
//  and explicit line breaks never did — text layout loads its
//  line-breaking data on first use. At launch, behind the loading
//  cover, every wrapped string the HUD and the screens show is laid
//  out and drawn once on a background queue with the same fonts, so
//  that first use is paid there and never in a mission.
// ================================================================
enum TextWarmup {
    private static var started = false

    /// Main thread, once (from loadView).
    static func start() {
        guard !started else { return }
        started = true
        let scale = UIScreen.main.nativeScale
        DispatchQueue.global(qos: .utility).async {
            let t0 = FrameTimer.now()
            let n = run(scale: scale)
            AppLog.info(String(format: "text warm-up: %d wrapped strings in %.0f ms", n, (FrameTimer.now() - t0) * 1000))
        }
    }

    /// Lay out and draw each string wrapped at the widths the HUD uses (toasts are right-aligned with letter spacing,
    /// cards and paragraphs left / centred with line spacing).
    private static func run(scale: CGFloat) -> Int {
        var toasts: [String] = []
        for (k, spec) in BUG_SPECS.enumerated() where k < BUG_TIPS.count && !BUG_TIPS[k].isEmpty {
            toasts.append(spec.name + ": " + BUG_TIPS[k])
        }
        toasts += ["Вы ранены — ждите помощи", "Вы снова в строю", "Аптечка +40"]
        for n in BOT_NAMES { toasts += [n + " ранен", n + " в строю"] }
        toasts += UPGRADES.map { $0.name }
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let left = NSMutableParagraphStyle()
        left.alignment = .left
        left.lineSpacing = 2
        let centre = NSMutableParagraphStyle()
        centre.alignment = .center
        centre.lineSpacing = 2
        var items: [(NSAttributedString, CGFloat)] = []
        for t in toasts {
            let s = NSAttributedString(string: t.uppercased(), attributes: [
                .font: Fonts.font(Fonts.medium, 12), .foregroundColor: UIPalette.ink, .kern: CGFloat(1.0), .paragraphStyle: right])
            // portrait and landscape toast widths (HUD.toast: min(320, 0.6 × width) − 22)
            items.append((s, 219))
            items.append((s, 298))
        }
        for u in UPGRADES {
            items.append((NSAttributedString(string: u.desc, attributes: [
                .font: Fonts.font(Fonts.regular, 13), .foregroundColor: UIPalette.inkDim, .paragraphStyle: left]), 160))
        }
        for t in MenuScreen.endSubtitles {
            items.append((NSAttributedString(string: t, attributes: [.font: Fonts.font(Fonts.regular, 14), .paragraphStyle: centre]), 326))
        }
        for (font, style) in [(Fonts.regular, centre), (Fonts.semibold, left)] {
            items.append((NSAttributedString(string: "Станция замолчала шесть часов назад. Под решётками шевелится рой — запустите три маяка.",
                                             attributes: [.font: Fonts.font(font, 13), .kern: CGFloat(0.5), .paragraphStyle: style]), 300))
        }
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
