import Darwin
import Foundation

/// Runs short-lived system tools (`lsof`, `ps`, `nettop`, `docker`) safely:
/// drains stdout and stderr concurrently to avoid pipe-buffer deadlocks, and
/// enforces a wall-clock timeout with `SIGTERM` -> `SIGKILL` escalation.
enum SubprocessRunner {
    struct Result: Sendable {
        let output: String
        let exitCode: Int32
        let timedOut: Bool

        var succeeded: Bool { !timedOut && exitCode == 0 }
    }

    static func run(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval = 8.0,
        forceCLocale: Bool = true
    ) -> Result {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        if forceCLocale {
            var env = ProcessInfo.processInfo.environment
            env["LC_ALL"] = "C"
            process.environment = env
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return Result(output: "", exitCode: -1, timedOut: false)
        }

        let group = DispatchGroup()
        var stdoutData = Data()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var didTimeOut = false
        if exited.wait(timeout: .now() + max(0.5, timeout)) == .timedOut {
            didTimeOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            AppLog.system.warning("subprocess timed out after \(timeout, privacy: .public)s: \(path, privacy: .public)")
        }

        process.waitUntilExit()
        group.wait()

        let outputText = String(decoding: stdoutData, as: UTF8.self)
        return Result(output: outputText, exitCode: process.terminationStatus, timedOut: didTimeOut)
    }
}
