import Foundation
import os

/// Central `os.Logger` registry.
///
/// Why not `print`/`NSLog`: unified logging keeps entries in a ring buffer that
/// `log show` / Console.app can read *after* the fact, and — critically — lets us
/// mark user data as `privacy: .private` so file paths, SSIDs and session titles
/// are redacted in logs that other tooling can read.
///
/// Categories mirror the app's modules so `log stream --predicate
/// 'subsystem == "com.tienyeung.Pinner" AND category == "traffic"'` is enough to
/// isolate a subsystem.
enum AppLog {
    static let subsystem = "com.tienyeung.Pinner"

    /// Network counters, sampling pipeline, ledger persistence.
    static let traffic = Logger(subsystem: subsystem, category: "traffic")
    /// TOTP / OTP vault.
    static let otp = Logger(subsystem: subsystem, category: "otp")
    /// Agent dashboards, snapshot builds, CSV export.
    static let stats = Logger(subsystem: subsystem, category: "stats")
    /// Remote model calls (Jev routing, weekly insight).
    static let llm = Logger(subsystem: subsystem, category: "llm")
    /// Keystroke / mouse aggregates.
    static let input = Logger(subsystem: subsystem, category: "input")
    /// Process and port management.
    static let system = Logger(subsystem: subsystem, category: "system")
    /// App lifecycle, permissions, window plumbing.
    static let app = Logger(subsystem: subsystem, category: "app")
}
