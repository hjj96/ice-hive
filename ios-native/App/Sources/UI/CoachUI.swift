import SpriteKit
import UIKit
import IceHiveCore

// ================================================================
//  COACH UI — the first-run tutorial (v1.1, web #coach / #ghost of
//  11b-coach.js): one card under the objective box («1/5  LEFT THUMB —
//  MOVE  SKIP») and a ghost thumb on the real control (drag loop on
//  a stick, tap loop on the ability / dash button, whose amber ring
//  pulses; on the beacon step a ring around the objective marker).
//  Everything animates on wall time with transforms / alpha only; a
//  step change re-lays the card once (text textures only then).
// ================================================================

/// The card. HUD coordinates (origin at the view centre, y up); `top` is the card's top edge.
final class CoachCard {
    let node = SKNode()
    private var panel = SKSpriteNode(texture: nil)
    private let counter = Label(L10n.string(CoachText.counter(step: 0)), font: Fonts.monoBold, size: 12, color: UIPalette.amber)
    private let line1 = Label("", font: Fonts.semibold, size: 15, color: UIPalette.ink, kern: 0.75, align: .left)
    private let line2 = Label("", font: Fonts.semibold, size: 15, color: UIPalette.ink, kern: 0.75, align: .left)
    private let skip = Label(L10n.upper(L10n.string(CoachText.skip)), font: Fonts.medium, size: 11, color: UIPalette.inkFaint, kern: 1.1)
    /// Skip hit area (HUD coordinates, ≥ 44 × 44: the card's full height at its right end).
    private(set) var skipRect = CGRect.zero
    private(set) var height: CGFloat = 44
    private(set) var width: CGFloat = 0
    /// What the card shows (step + text): re-laid only when it changes.
    private(set) var key = ""
    private var appearT: Double = -1
    var reducedMotion = false

    init() {
        node.addChild(panel)
        for l in [counter, line1, line2, skip] { node.addChild(l.node); l.node.zPosition = 1 }
        node.isHidden = true
    }

    var visible: Bool { !node.isHidden }

    func hide() {
        node.isHidden = true
        key = ""
        skipRect = .zero
    }

    /// How the card sets `text`: one line, or two split after « — » (or at the middle space) when one is wider than
    /// the room the counter and skip leave; lines still too wide shrink (down to 0.6). Show and the layout check share it.
    struct Lines {
        let l1: String, l2: String
        let avail: CGFloat
        /// Widest line at full size and the scale it is drawn at.
        let widest: CGFloat, scale: CGFloat
    }
    static let lineMinScale: CGFloat = 0.6
    static func lines(_ text: String, maxWidth: CGFloat, counterW: CGFloat, skipW: CGFloat) -> Lines {
        let fixed: CGFloat = 12 + counterW + 10 + 10 + skipW + 4
        let avail = max(80, maxWidth - fixed)
        func w(_ s: String) -> CGFloat { TextFit.width(s, font: Fonts.semibold, size: 15, kern: 0.75) }
        var l1 = text, l2 = ""
        var widest = w(text)
        if widest > avail {
            (l1, l2) = CoachCard.split(text)
            widest = max(w(l1), w(l2))
        }
        return Lines(l1: l1, l2: l2, avail: avail, widest: widest, scale: TextFit.fitted(widest, avail, minScale: lineMinScale).scale)
    }

    /// The skip label's width and its tap column (≥ 44 pt).
    var skipWidth: CGFloat { max(44, skip.width + 16) }
    var counterWidth: CGFloat { counter.width }

    /// Lay the card out for `text` (as given: the HUD passes it uppercased), centred at `centerX`, top edge at `top`.
    /// Too long for one line → two single-line labels (`lines`): no wrapped label (the first wrapped text layout of a
    /// process can stall, TextWarmup).
    func show(step: Int, text: String, centerX: CGFloat, top: CGFloat, maxWidth: CGFloat) {
        let k = "\(step)|" + text + "|\(Int(centerX))|\(Int(top))|\(Int(maxWidth))"
        if k == key && visible { return }
        let fresh = !visible || !key.hasPrefix("\(step)|" + text + "|")
        key = k
        node.isHidden = false
        counter.set(L10n.string(CoachText.counter(step: step)))
        let skipW = skipWidth
        let fixed: CGFloat = 12 + counter.width + 10 + 10 + skipW + 4
        let L = CoachCard.lines(text, maxWidth: maxWidth, counterW: counter.width, skipW: skipW)
        line1.set(L.l1)
        line2.set(L.l2)
        line1.node.setScale(L.scale)
        line2.node.setScale(L.scale)
        let lines = L.l2.isEmpty ? 1 : 2
        line2.node.isHidden = lines < 2
        let textW = L.widest * L.scale
        let w = min(maxWidth, fixed + min(textW, L.avail))
        let h: CGFloat = 44
        width = w
        height = h
        panel.removeFromParent()
        panel = Shapes.stretchedPanel(width: w, height: h, baseWidth: 120, cut: 5, fill: UIPalette.panel2, stroke: UIPalette.lineStrong)
        panel.position = CGPoint(x: -w / 2, y: 0)
        panel.zPosition = 0
        node.insertChild(panel, at: 0)
        let x0 = -w / 2
        counter.node.position = CGPoint(x: x0 + 12 + counter.width / 2, y: -h / 2)
        let tx = x0 + 12 + counter.width + 10
        if lines == 2 {
            line1.node.position = CGPoint(x: tx, y: -h / 2 + 8.6)
            line2.node.position = CGPoint(x: tx, y: -h / 2 - 8.6)
        } else {
            line1.node.position = CGPoint(x: tx, y: -h / 2)
        }
        skip.node.position = CGPoint(x: w / 2 - 4 - skipW / 2, y: -h / 2)
        node.position = CGPoint(x: centerX, y: top)
        skipRect = CGRect(x: centerX + w / 2 - 4 - skipW, y: top - h, width: skipW, height: h)
        if fresh { appearT = FrameTimer.now() }
    }

    /// «RIGHT THUMB — AIM, IT FIRES ITSELF» → («RIGHT THUMB —», «AIM, IT FIRES ITSELF»).
    static func split(_ t: String) -> (String, String) {
        if let r = t.range(of: " — ") {
            return (String(t[t.startIndex..<r.lowerBound]) + " —", String(t[r.upperBound...]))
        }
        let chars = Array(t)
        var best = -1
        for (i, c) in chars.enumerated() where c == " " { if best < 0 || abs(i - chars.count / 2) < abs(best - chars.count / 2) { best = i } }
        if best < 0 { return (t, "") }
        return (String(chars[0..<best]), String(chars[(best + 1)...]))
    }

    /// Per frame: the 0.35 s entrance (fade + 10 pt rise; none with Reduce Motion).
    func update(top: CGFloat) {
        guard visible, appearT >= 0 else { return }
        let u = CGFloat(min(1, (FrameTimer.now() - appearT) / 0.35))
        if reducedMotion || u >= 1 {
            appearT = -1
            node.alpha = 1
            node.position.y = top
            return
        }
        let e = 1 - (1 - u) * (1 - u)
        node.alpha = e
        node.position.y = top - 10 * (1 - e)
    }

    func contains(_ p: CGPoint) -> Bool { visible && skipRect.insetBy(dx: -4, dy: -4).contains(p) }
}

/// The ghost thumb and the target pulses.
final class CoachGhost {
    let thumb = SKSpriteNode(texture: Shapes.ghostThumb())
    enum Motion { case none, drag, tap }
    private(set) var motion: Motion = .none
    private var anchor = CGPoint.zero
    var reducedMotion = false

    init() {
        thumb.size = CGSize(width: 80, height: 80)
        thumb.isHidden = true
    }

    func set(_ m: Motion, at p: CGPoint) {
        motion = m
        anchor = p
        thumb.position = p
        thumb.isHidden = m == .none
        if m == .none { thumb.setScale(1); thumb.alpha = 1 }
    }

    /// ease-in-out (CSS ease-in-out ≈ smoothstep) between keyframes.
    @inline(__always) static func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }

    /// 0…1 phase of a loop of `period` s (3 s with Reduce Motion), wall time.
    func phase(_ period: Double) -> CGFloat {
        let p = reducedMotion ? 3 : period
        return CGFloat(FrameTimer.now().truncatingRemainder(dividingBy: p) / p)
    }

    /// Triangle 0 → 1 → 0 over the loop, eased (the pulses).
    func pulse(_ period: Double) -> CGFloat {
        let u = phase(period)
        return CoachGhost.ease(u < 0.5 ? u * 2 : (1 - u) * 2)
    }

    func update() {
        switch motion {
        case .none:
            return
        case .drag:
            // web ghDrag 1.6 s: (0, 0) → 30 % (0, −34) → 60 % (30, −10) → (0, 0) (CSS y down; HUD y up)
            let u = phase(1.6)
            var x: CGFloat = 0, y: CGFloat = 0
            if u < 0.3 {
                let e = CoachGhost.ease(u / 0.3); y = 34 * e
            } else if u < 0.6 {
                let e = CoachGhost.ease((u - 0.3) / 0.3); x = 30 * e; y = 34 + (10 - 34) * e
            } else {
                let e = CoachGhost.ease((u - 0.6) / 0.4); x = 30 * (1 - e); y = 10 * (1 - e)
            }
            thumb.position = CGPoint(x: anchor.x + x, y: anchor.y + y)
            thumb.setScale(1)
            thumb.alpha = 1
        case .tap:
            // web ghTap 1.1 s: scale 1 ↔ 0.7, opacity 0.9 ↔ 0.5
            let p = pulse(1.1)
            thumb.position = anchor
            thumb.setScale(1 - 0.3 * p)
            thumb.alpha = 0.9 - 0.4 * p
        }
    }
}
