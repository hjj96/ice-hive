import Foundation
import UIKit
import SpriteKit
import IceHiveCore

enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var coreVersion: String { IceHiveCoreInfo.version }
}

enum Palette {
    /// #05070a — the game's background / launch screen colour.
    static let backgroundUI = UIColor(red: 5.0 / 255.0, green: 7.0 / 255.0, blue: 10.0 / 255.0, alpha: 1.0)
    static let background = SKColor(red: 5.0 / 255.0, green: 7.0 / 255.0, blue: 10.0 / 255.0, alpha: 1.0)
    static let ice = SKColor(red: 0.62, green: 0.86, blue: 1.0, alpha: 1.0)
    static let teal = SKColor(red: 0.25, green: 0.95, blue: 0.85, alpha: 1.0)
}
