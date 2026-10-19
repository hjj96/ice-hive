import SpriteKit
import UIKit

// ================================================================
//  LAYOUT CHECK — `-layoutCheck` (v1.1 spec §2.11): every element of a
//  screen (title, report, pause) is logged with its rect, then any two
//  that overlap (one inside the other is a container, not an overlap)
//  and any that leave the safe area. CI greps «layout ok».
//  Rects are HUD coordinates (origin at the view centre, y up).
// ================================================================
struct LayoutCheck {
    let screen: String
    private(set) var items: [(String, CGRect)] = []

    init(_ screen: String) { self.screen = screen }

    mutating func add(_ name: String, _ r: CGRect) {
        guard r.width > 0.5, r.height > 0.5, r.minX.isFinite, r.minY.isFinite else { return }
        items.append((name, r))
    }

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
        for (n, r) in items {
            AppLog.info(String(format: "layout %@ %@ x=%.0f y=%.0f w=%.0f h=%.0f", screen, n, r.minX, r.minY, r.width, r.height))
            if !safe.insetBy(dx: -1, dy: -1).contains(r) { problems.append("off-screen " + n) }
        }
        for i in 0..<items.count {
            for j in (i + 1)..<max(i + 1, items.count) {
                let a = items[i].1.insetBy(dx: 1, dy: 1), b = items[j].1.insetBy(dx: 1, dy: 1)
                // a container (the pause box around its buttons) is not an overlap
                if a.intersects(b) && !a.contains(b) && !b.contains(a) { problems.append("overlap " + items[i].0 + " / " + items[j].0) }
            }
        }
        let tag = String(format: "%@ %.0fx%.0f", screen, size.width, size.height)
        if problems.isEmpty {
            AppLog.info("layout ok " + tag + " (\(items.count) elements)")
        } else {
            AppLog.info("layout FAIL " + tag + ": " + problems.prefix(12).joined(separator: "; "))
        }
    }
}
