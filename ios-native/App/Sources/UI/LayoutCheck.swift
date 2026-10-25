import SpriteKit
import UIKit

// ================================================================
//  LAYOUT CHECK — `-layoutCheck` (v1.1 spec §2.11): every element of a
//  screen (title, HUD, pause, level-up, report) is logged with its rect, then any two
//  that overlap (one inside the other is a container, not an overlap),
//  any two side by side closer than 4 pt, any that leave the safe
//  area, and any tap area under 44 × 44 pt. CI greps «layout ok».
//  Rects are HUD coordinates (origin at the view centre, y up).
// ================================================================
struct LayoutCheck {
    /// Appended to the size in the result line (`-demo layout`: the phone and the case); `quiet` logs the element rects
    /// only when the check fails. Totals of every report so far.
    static var context = ""
    static var quiet = false
    static var results = (ok: 0, fail: 0)

    let screen: String
    private(set) var items: [(String, CGRect)] = []
    /// Tap areas (drawn rect + hit inset), checked only for Apple's 44 pt minimum.
    private(set) var taps: [(String, CGRect)] = []

    init(_ screen: String) { self.screen = screen }

    mutating func add(_ name: String, _ r: CGRect) {
        guard r.width > 0.5, r.height > 0.5, r.minX.isFinite, r.minY.isFinite else { return }
        items.append((name, r))
    }

    mutating func tap(_ name: String, _ r: CGRect) { taps.append((name, r)) }

    /// A node's frame in HUD coordinates (its parent is a direct child of the screen root at the origin).
    mutating func add(_ name: String, node: SKNode, offset: CGPoint = .zero) {
        let f = node.calculateAccumulatedFrame()
        add(name, f.offsetBy(dx: offset.x, dy: offset.y))
    }

    /// Log every rect, the overlaps (more than 1 pt each way) and anything outside `safe`; «layout ok» when clean.
    func report(size: CGSize, insets: UIEdgeInsets) {
        let safe = CGRect(x: -size.width / 2 + insets.left, y: -size.height / 2 + insets.bottom,
                          width: size.width - insets.left - insets.right, height: size.height - insets.top - insets.bottom)
        var problems: [String] = []
        for (n, r) in items where !safe.insetBy(dx: -1, dy: -1).contains(r) { problems.append("off-screen " + n) }
        for i in 0..<items.count {
            for j in (i + 1)..<max(i + 1, items.count) {
                let (na, ra) = items[i], (nb, rb) = items[j]
                // parts of one element («title#1», «title#2») may overlap each other
                if let ga = na.firstIndex(of: "#"), let gb = nb.firstIndex(of: "#"), na[..<ga] == nb[..<gb] { continue }
                let a = ra.insetBy(dx: 1, dy: 1), b = rb.insetBy(dx: 1, dy: 1)
                // a container (the pause box around its buttons) is not an overlap
                if a.contains(b) || b.contains(a) { continue }
                if a.intersects(b) { problems.append("overlap " + na + " / " + nb); continue }
                // side by side on one row: at least 4 pt apart (labels that touch read as one word)
                let vOverlap = min(ra.maxY, rb.maxY) - max(ra.minY, rb.minY)
                let hGap = max(ra.minX, rb.minX) - min(ra.maxX, rb.maxX)
                if vOverlap > 2 && hGap < 4 { problems.append("touching " + na + " / " + nb) }
            }
        }
        for (n, r) in taps where r.width < 43.5 || r.height < 43.5 {
            problems.append(String(format: "small tap %@ %.0fx%.0f", n, r.width, r.height))
        }
        if !LayoutCheck.quiet || !problems.isEmpty {
            for (n, r) in items {
                AppLog.info(String(format: "layout %@ %@ x=%.0f y=%.0f w=%.0f h=%.0f", screen, n, r.minX, r.minY, r.width, r.height))
            }
        }
        let ctx = LayoutCheck.context.isEmpty ? "" : " " + LayoutCheck.context
        let tag = String(format: "%@ %.0fx%.0f", screen, size.width, size.height) + ctx
            + String(format: " safe %.0f|%.0f|%.0f|%.0f", insets.left, insets.right, insets.top, insets.bottom)
        if problems.isEmpty {
            LayoutCheck.results.ok += 1
            AppLog.info("layout ok " + tag + " (\(items.count) elements)")
        } else {
            LayoutCheck.results.fail += 1
            AppLog.info("layout FAIL " + tag + ": " + problems.prefix(12).joined(separator: "; "))
        }
    }
}
