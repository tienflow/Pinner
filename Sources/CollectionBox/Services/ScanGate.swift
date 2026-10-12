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
final class ScanGate: @unchecked Sendable {
    private final class Call {
        let condition = NSCondition()
        var isDone = false
        var value: Any?
    }

    private let lock = NSLock()
    private var inFlight: [String: Call] = [:]

    /// Runs `scan` unless an equivalent call is already in flight, in which case
    /// it waits and reuses that call's value. Once the leader finishes and
    /// distributes the result to concurrent waiters, the key is removed so
    /// subsequent calls perform a fresh scan.
    func run<T>(key: String, _ scan: () -> T) -> T {
        lock.lock()
        if let call = inFlight[key] {
            lock.unlock()
            call.condition.lock()
            while !call.isDone {
                call.condition.wait()
            }
            let result = call.value as! T
            call.condition.unlock()
            return result
        }

        let call = Call()
        inFlight[key] = call
        lock.unlock()

        let value = scan()

        call.condition.lock()
        call.value = value
        call.isDone = true
        call.condition.broadcast()
        call.condition.unlock()

        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()

        return value
    }

    /// Drops any active in-flight calls state. Used by tests or reset paths.
    func reset() {
        lock.lock()
        inFlight.removeAll()
        lock.unlock()
    }
}
