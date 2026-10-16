import Foundation
import os

/// Logs to the unified log (visible with `log stream --predicate 'process == "IceHive"'`) and, in DEBUG builds or
/// when launched with diagnostics (`-demo …` / `-debugHUD`, the CI simulator runs), to stdout too (captured by
/// `xcrun simctl launch --stdout=…`). Every stdout line is prefixed with "[IceHive]".
enum AppLog {
    private static let logger = Logger(subsystem: "com.hjj96.icehive", category: "app")

    /// Diagnostics mode: per-second heartbeat, hitch and first-use lines, stdout echo. Off in a normal Release run.
    static let diagnostics: Bool = {
        #if DEBUG
        return true
        #else
        let o = LaunchOptions.current
        return o.demo != nil || o.debugHUD
        #endif
    }()

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        if diagnostics {
            print("[IceHive] \(message)")
            fflush(stdout)
        }
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        if diagnostics {
            print("[IceHive] ERROR \(message)")
            fflush(stdout)
        }
    }
}
