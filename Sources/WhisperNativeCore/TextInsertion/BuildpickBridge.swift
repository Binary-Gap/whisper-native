import Foundation

/// Sends dictations to a Buildpick session through the `cc-remote` command that
/// ships with the Buildpick server: `focused` names the session shown in the key
/// window of the Buildpick Mac app in front, `send` submits text to a session as
/// the user's prompt, `draft` appends it to that session's compose box unsent.
/// Any failure (no command installed, non-zero exit, timeout) returns nil/false,
/// so the caller falls back to pasting.
public struct BuildpickBridge: Sendable {

    /// Bundle ids of the Buildpick Mac apps (release, Staging, Beta).
    public static let bundleIdentifiers: Set<String> = [
        "io.binarygap.cc-remote",
        "io.binarygap.cc-remote.staging",
        "io.binarygap.cc-remote.beta",
    ]

    /// Installed `cc-remote` commands, most preferred first: Staging, Beta,
    /// then the older bare Staging binary.
    public static var installedCommandCandidates: [String] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/cc-remote/staging-server")
        return [
            support.appendingPathComponent("cc-remote-server.app/Contents/MacOS/cc-remote").path,
            "/Applications/Buildpick Beta.app/Contents/Resources/server/cc-remote",
            support.appendingPathComponent("cc-remote").path,
        ]
    }

    /// The first installed `cc-remote` command, resolved on each call so a
    /// Buildpick install or update needs no Whisper Native restart.
    public static var installed: BuildpickBridge {
        let command = installedCommandCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return BuildpickBridge(commandPath: command)
    }

    public let commandPath: String?
    let focusedTimeout: TimeInterval
    let sendTimeout: TimeInterval

    public init(commandPath: String?, focusedTimeout: TimeInterval = 3, sendTimeout: TimeInterval = 10) {
        self.commandPath = commandPath
        self.focusedTimeout = focusedTimeout
        self.sendTimeout = sendTimeout
    }

    /// The session focused in the Buildpick Mac app in front, nil when none
    /// answers. Never call it on the main thread: it waits up to 3 s.
    public func focusedSessionID() -> String? {
        guard let commandPath else {
            AppLogger.shared.log(.warning, "BuildpickBridge: no cc-remote command installed")
            return nil
        }
        guard let result = try? ProcessRunner.runSync(commandPath, arguments: ["focused"], timeout: focusedTimeout) else {
            AppLogger.shared.log(.error, "BuildpickBridge: failed to launch \(commandPath)")
            return nil
        }
        guard let output = Self.output(of: result, action: "focused"), !output.isEmpty else { return nil }
        return output
    }

    /// Submits the text as the user's prompt to the session.
    public func send(_ text: String, toSession sessionID: String) async -> Bool {
        await run(action: "send", text: text, sessionID: sessionID)
    }

    /// Appends the text to the session's compose box without sending it.
    public func draft(_ text: String, toSession sessionID: String) async -> Bool {
        await run(action: "draft", text: text, sessionID: sessionID)
    }

    // MARK: - Private

    private func run(action: String, text: String, sessionID: String) async -> Bool {
        guard let commandPath else {
            AppLogger.shared.log(.warning, "BuildpickBridge: no cc-remote command installed")
            return false
        }
        let textFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        do {
            try text.write(to: textFile, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.shared.log(.error, "BuildpickBridge: failed to write temp text file: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: textFile) }

        let arguments = [action, sessionID, "--text-file", textFile.path]
        guard let result = try? await ProcessRunner.run(commandPath, arguments: arguments, timeout: sendTimeout) else {
            AppLogger.shared.log(.error, "BuildpickBridge: failed to launch \(commandPath)")
            return false
        }
        return Self.output(of: result, action: action) != nil
    }

    /// The command's trimmed stdout, or nil when it failed or timed out.
    private static func output(of result: ProcessResult, action: String) -> String? {
        guard result.exitCode == 0, !result.timedOut else {
            let reason = result.timedOut ? "timed out" : "exited \(result.exitCode)"
            AppLogger.shared.log(.warning, "BuildpickBridge: \(action) \(reason): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
