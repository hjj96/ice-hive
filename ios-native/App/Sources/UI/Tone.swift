import SpriteKit

// ================================================================
//  Z BAND / TONE — the HUD's depth band (ignoresSiblingOrder: every
//  leaf node carries an absolute zPosition) and sRGB hex colours.
// ================================================================
enum ZBand {
    /// HUD, menus and the loading cover (camera children); the world is drawn by Metal underneath.
    static let hud: CGFloat = 5000
}

enum Tone {
    /// sRGB hex (0xRRGGBB) → SKColor.
    static func hex(_ v: UInt32, alpha: CGFloat = 1) -> SKColor {
        SKColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                blue: CGFloat(v & 255) / 255, alpha: alpha)
    }
}
