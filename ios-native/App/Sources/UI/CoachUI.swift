import SpriteKit
import UIKit
import IceHiveCore

// ================================================================
//  COACH UI — «Учебная высадка» (v1.1, web #coach / #ghost of
//  11b-coach.js): one card under the objective box («1/5  ЛЕВЫЙ ПАЛЕЦ —
//  БЕГ  ПРОПУСТИТЬ») and a ghost thumb on the real control (drag loop on
//  a stick, tap loop on the ability / dash button, whose amber ring
//  pulses; on the beacon step a ring around the objective marker).
//  Everything animates on wall time with transforms / alpha only; a
//  step change re-lays the card once (text textures only then).
// ================================================================

/// The card. HUD coordinates (origin at the view centre, y up); `top` is the card's top edge.
final class CoachCard {
    let node = SKNode()
    private var panel = SKSpriteNode(texture: nil)
    private let counter = Label("1/5", font: Fonts.monoBold, size: 12, color: UIPalette.amber)
    private let line1 = Label("", font: Fonts.semibold, size: 15, color: UIPalette.ink, kern: 0.75, align: .left)
    private let line2 = Label("", font: Fonts.semibold, size: 15, color: UIPalette.ink, kern: 0.75, align: .left)
    private let skip = Label(CoachText.skip.uppercased(), font: Fonts.medium, size: 11, color: UIPalette.inkFaint, kern: 1.1)
    /// «Пропустить» hit area (HUD coordinates, ≥ 44 × 44: the card's full height at its right end).
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

    /// Lay the card out for `text` (as given: the HUD passes it uppercased), centred at `centerX`, top edge at `top`.
    /// Too long for one line → split after « — » (or the middle space) into two single-line labels: no wrapped label
    /// (the first wrapped text layout of a process can stall, TextWarmup).
    func show(step: Int, text: String, centerX: CGFloat, top: CGFloat, maxWidth: CGFloat) {
        let k = "\(step)|" + text + "|\(Int(centerX))|\(Int(top))|\(Int(maxWidth))"
        if k == key && visible { return }
        let fresh = !visible || !key.hasPrefix("\(step)|" + text + "|")
        key = k
        node.isHidden = false
        counter.set(CoachText.counter(step: step))
        let skipW = max(44, skip.width + 16)
        let fixed: CGFloat = 12 + counter.width + 10 + 10 + skipW + 4
        let avail = max(80, maxWidth - fixed)
        line1.set(text)
        var lines = 1
        if line1.width > avail {
            let parts = CoachCard.split(text)
            line1.set(parts.0)
            line2.set(parts.1)
            lines = 2
        }
        line2.node.isHidden = lines < 2
        let textW = lines == 2 ? max(line1.width, line2.width) : line1.width
        let w = min(maxWidth, fixed + min(textW, avail))
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

    /// «ПРАВЫЙ ПАЛЕЦ — ПРИЦЕЛ, ОГОНЬ САМ» → («ПРАВЫЙ ПАЛЕЦ —», «ПРИЦЕЛ, ОГОНЬ САМ»).
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
