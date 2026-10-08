import Foundation

/// Single-flight gate for expensive, synchronous scans.
///
/// The stats services each cache their last result, but the original code used a
/// check-then-act pattern: two threads (the Dashboard's full reload and an agent
/// panel opening at the same moment) could both miss the cache and both run the
/// full scan. For WorkBuddy that meant walking ~270 MB of session files twice;
/// for DSH it meant decompressing every `.zstd` twice.
///
/// The gate is keyed by the requested window: concurrent callers asking for the
/// *same* window share one scan, callers asking for different windows stay
/// independent (a narrow-window scan must not be served to a full-history
/// caller). Results are memoized so a later call for the same window reuses the
/// work just done.
///
/// Everything runs on a background thread — the services scan off the main actor
/// — so waiting here introduces no main-thread stall.
final class ScanGate {
    private let condition = NSCondition()
    private var inFlightKey: String?
    private var completed: [String: Any] = [:]

    /// Runs `scan` unless an equivalent call is already in flight, in which case
    /// it waits and reuses that call's value. `scan` must be safe to call on a
    /// background thread.
    func run<T>(key: String, _ scan: () -> T) -> T {
        condition.lock()
        while inFlightKey == key {
            condition.wait()
        }
        if let memo = completed[key] as? T {
            condition.unlock()
            return memo
        }
        inFlightKey = key
        condition.unlock()

        // Scan outside the lock: CPU/IO heavy, must not serialize other windows.
        let value = scan()

        condition.lock()
        completed[key] = value
        inFlightKey = nil
        condition.broadcast()
        condition.unlock()
        return value
    }

    /// Drops memoized results so the next `run` actually rescans. Used by force
    /// refresh paths and by tests.
    func reset() {
        condition.lock()
        completed.removeAll()
        condition.unlock()
    }
}
