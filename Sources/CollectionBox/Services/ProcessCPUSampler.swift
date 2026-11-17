import Foundation

/// Conversion for `proc_taskinfo`'s CPU-time fields.
///
/// `pti_total_user` / `pti_total_system` are counted in **mach absolute time
/// ticks**, not nanoseconds: on Apple Silicon the timebase is 125/3 (≈41.7ns per
/// tick), so dividing the raw value by 1e9 under-reports CPU by ~24×. On Intel the
/// timebase is 1/1, which is why the shortcut looks correct there and silently
/// wrong on every M-series machine.
enum MachTimeBase {
    static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        UInt64(Double(ticks) * nanosPerTick)
    }
}

/// Instantaneous per-process CPU usage, computed the way Activity Monitor does:
/// the delta of a process's cumulative CPU time divided by the wall-clock time
/// between two samples.
///
/// Why not `ps -o %cpu`: that field is the process's **lifetime average**
/// (cumulative CPU time ÷ elapsed time), not what it is doing now. A process that
/// burned a core for a minute hours ago keeps reading high while idle, and a
/// daemon that just woke up reads low while pegging a core. Neither number can be
/// summed into a meaningful "how much CPU are these services using" figure.
///
/// Why the caller supplies the cumulative time instead of this type reading
/// `proc_taskinfo` itself: `PROC_PIDTASKINFO` returns EPERM for processes owned by
/// other users (every root daemon, `WindowServer` included), and those are exactly
/// the ones with the largest CPU figures. `ps -o time=` needs no privileges, so one
/// source covers everything.
///
/// Values are percentages **relative to one core** — the same convention as
/// `ps`/`top`/Activity Monitor — so a process using two cores reports ~200%.
final class ProcessCPUSampler: @unchecked Sendable {
    private struct Sample {
        let seconds: Double
        let at: TimeInterval
    }

    private let lock = NSLock()
    private var previous: [pid_t: Sample] = [:]

    /// CPU percentage relative to one core, or nil when there is no usable
    /// baseline yet (first sighting of the process, or a sample window too short
    /// to mean anything).
    func percent(for pid: pid_t, cumulativeSeconds: Double, at now: TimeInterval) -> Double? {
        lock.lock()
        let previousSample = previous[pid]
        previous[pid] = Sample(seconds: cumulativeSeconds, at: now)
        lock.unlock()

        guard let previousSample, cumulativeSeconds >= previousSample.seconds else { return nil }
        let elapsed = now - previousSample.at
        // Below ~0.2s the denominator amplifies scheduler jitter into wild values.
        guard elapsed > 0.2 else { return nil }
        return (cumulativeSeconds - previousSample.seconds) / elapsed * 100.0
    }

    /// Drops baselines for processes that disappeared, so the map does not grow
    /// with every short-lived dev server.
    func retainOnly(_ pids: Set<pid_t>) {
        lock.lock()
        previous = previous.filter { pids.contains($0.key) }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        previous.removeAll()
        lock.unlock()
    }

    /// Parses `ps -o time=`, which on macOS is always `MM:SS.cc` — the minute field
    /// keeps counting past 59 instead of rolling into an hours field, so a process
    /// with 7.8 CPU-hours reads `468:38.57`.
    static func parseCumulativeSeconds(_ raw: String) -> Double? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
