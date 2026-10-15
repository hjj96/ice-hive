import Foundation
import os

/// Logs both to the unified log (visible with `log stream --predicate 'process == "IceHive"'`)
/// and to stdout (captured by `xcrun simctl launch --stdout=…`). Every line is prefixed with "[IceHive]".
enum AppLog {
    private static let logger = Logger(subsystem: "com.hjj96.icehive", category: "app")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[IceHive] \(message)")
        fflush(stdout)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        print("[IceHive] ERROR \(message)")
        fflush(stdout)
    }
}
