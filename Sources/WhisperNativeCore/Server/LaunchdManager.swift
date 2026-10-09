import Foundation

// Thin wrapper around launchctl for managing the whisper-server LaunchAgent.
// All operations are async shell-outs; launchctl is not async-aware itself.
public actor LaunchdManager {

    private let label: String
    private let plistPath: URL

    public init(label: String = Constants.whisperServerLaunchdLabel,
                plistPath: URL = Constants.whisperServerPlistPath) {
        self.label = label
        self.plistPath = plistPath
    }

    // MARK: - Service state

    /// Returns the uid for the current user's gui session (e.g. "501").
    private nonisolated func guiTarget() -> String {
        "gui/\(getuid())"
    }

    // MARK: - Public interface

    /// Enables + bootstraps the service. Idempotent if already running.
    public func bootstrap() async throws {
        let target = guiTarget()
        // enable clears any "disabled" flag so KeepAlive/RunAtLoad apply after login
        try await launchctl("enable", "\(target)/\(label)")
        try await launchctl("bootstrap", target, plistPath.path)
    }

    /// Bootouts + disables the service. Idempotent if already stopped.
    public func bootout() async throws {
        let target = guiTarget()
        // bootout errors if already not loaded — ignore that specific error
        try? await launchctl("bootout", target, plistPath.path)
        try await launchctl("disable", "\(target)/\(label)")
    }

    /// Returns true if the service is currently loaded (running or failed).
    public func isLoaded() async -> Bool {
        let result = try? await shell("/bin/launchctl", "list", label)
        return result?.exitCode == 0
    }

    // MARK: - Helpers

    @discardableResult
    private func launchctl(_ args: String...) async throws -> ShellResult {
        let result = try await shell("/bin/launchctl", args: args)
        if result.exitCode != 0 {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            AppLogger.shared.log(.warning, "launchctl \(args.joined(separator: " ")) exited \(result.exitCode): \(stderr)")
        }
        return result
    }

    private func shell(_ executable: String, _ args: String...) async throws -> ShellResult {
        try await shell(executable, args: args)
    }

    private func shell(_ executable: String, args: [String]) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            process.waitUntilExit()

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            continuation.resume(returning: ShellResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            ))
        }
    }
}

struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
