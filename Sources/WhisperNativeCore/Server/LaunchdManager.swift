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
        // bootout fails on a service that isn't loaded, so it only runs on a
        // loaded one; a failure there is logged and the disable still runs.
        if await isLoaded() {
            try? await launchctl("bootout", target, plistPath.path)
        }
        try await launchctl("disable", "\(target)/\(label)")
    }

    /// Returns true if the service is currently loaded (running or failed).
    public func isLoaded() async -> Bool {
        let result = try? await shell("/bin/launchctl", "list", label)
        return result?.exitCode == 0
    }

    // MARK: - Helpers

    @discardableResult
    private func launchctl(_ args: String...) async throws -> ProcessResult {
        let result = try await shell("/bin/launchctl", args: args)
        if result.exitCode != 0 {
            let stderr = result.stderr.isEmpty ? result.stdout : result.stderr
            AppLogger.shared.log(.warning, "launchctl \(args.joined(separator: " ")) exited \(result.exitCode): \(stderr)")
        }
        return result
    }

    private func shell(_ executable: String, _ args: String...) async throws -> ProcessResult {
        try await shell(executable, args: args)
    }

    // launchctl answers in milliseconds; a stuck one is killed so callers
    // (engine switches, quit) never wait on it forever.
    private func shell(_ executable: String, args: [String]) async throws -> ProcessResult {
        let result = try await ProcessRunner.run(executable, arguments: args, timeout: 10)
        if result.timedOut {
            AppLogger.shared.log(.warning, "\(executable) \(args.joined(separator: " ")) timed out and was killed")
        }
        return result
    }
}
