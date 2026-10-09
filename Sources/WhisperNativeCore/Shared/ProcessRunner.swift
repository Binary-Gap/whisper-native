import Foundation

/// Output of a child process that exited or was killed at its timeout.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// True when the process outlived its timeout and was killed.
    public let timedOut: Bool
}

/// Runs a child process with a timeout. stdout and stderr are drained while it
/// runs, so a chatty process can't fill a pipe and block on it. A process still
/// running at the timeout gets SIGTERM, then SIGKILL one second later.
public enum ProcessRunner {

    public static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try ChildProcess.start(executable, arguments: arguments, timeout: timeout) { result in
                    continuation.resume(returning: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Blocking variant for synchronous callers. Never call it on the main thread.
    public static func runSync(_ executable: String, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let finished = DispatchSemaphore(value: 0)
        let box = ResultBox()
        try ChildProcess.start(executable, arguments: arguments, timeout: timeout) { result in
            box.result = result
            finished.signal()
        }
        finished.wait()
        return box.result!
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: ProcessResult?
}

private final class ChildProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var timedOut = false
    private let readers = DispatchGroup()

    static func start(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping @Sendable (ProcessResult) -> Void
    ) throws {
        try ChildProcess().start(executable, arguments: arguments, timeout: timeout, completion: completion)
    }

    private func start(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping @Sendable (ProcessResult) -> Void
    ) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [self] process in
            // The pipes reach EOF once the process exits; a grandchild still
            // holding one open must not hold the result back.
            _ = readers.wait(timeout: .now() + 1)
            lock.lock()
            let result = ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                timedOut: timedOut
            )
            lock.unlock()
            completion(result)
        }

        // Both readers count before launch, so a process that exits at once
        // still waits for its output.
        readers.enter()
        readers.enter()
        do {
            try process.run()
        } catch {
            readers.leave()
            readers.leave()
            throw error
        }

        drain(stdoutPipe) { [self] data in stdoutData.append(data) }
        drain(stderrPipe) { [self] data in stderrData.append(data) }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            guard process.isRunning else { return }
            lock.lock()
            timedOut = true
            lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func drain(_ pipe: Pipe, into append: @escaping @Sendable (Data) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let handle = pipe.fileHandleForReading
            while case let data = handle.availableData, !data.isEmpty {
                lock.lock()
                append(data)
                lock.unlock()
            }
            readers.leave()
        }
    }
}
