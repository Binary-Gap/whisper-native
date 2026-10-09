import Foundation

/// Bridges to iTerm2's Python API via the bundled `iterm_helper.py` script.
/// Requires `pip3 install iterm2` on the resolved Python interpreter and iTerm2's
/// Python API enabled (Preferences > General > Magic > Enable Python API).
public enum ItermBridge {

    public static let bundleIdentifier = "com.googlecode.iterm2"

    /// Returns the session ID of the currently focused iTerm2 session, or nil on failure.
    /// Synchronous, ~200ms (spawns a Python process), at most 3 s. Never call it on
    /// the main thread.
    public static func currentSessionID() -> String? {
        guard let result = try? ProcessRunner.runSync(pythonPath, arguments: helperArguments(["get-session"]), timeout: 3) else {
            AppLogger.shared.log(.error, "ItermBridge: failed to launch helper")
            return nil
        }
        return helperOutput(result)
    }

    /// Sends text to the given iTerm2 session via the Python API. If `submitWithEnter`
    /// is true, a standalone Enter keypress follows after a short delay (a CR glued onto
    /// the text makes TUIs like Claude Code treat it as a soft newline instead of submit).
    public static func sendText(_ text: String, toSession sessionID: String, submitWithEnter: Bool) async -> Bool {
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        do {
            try text.write(to: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.shared.log(.error, "ItermBridge: failed to write temp text file: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        var arguments = ["send", "--session-id", sessionID, "--text-file", tmpFile.path]
        if submitWithEnter {
            arguments.append("--newline")
        }
        // A stuck helper (e.g. waiting on iTerm2's API consent) is killed, so the
        // caller falls back to pasting instead of waiting forever.
        guard let result = try? await ProcessRunner.run(pythonPath, arguments: helperArguments(arguments), timeout: 10) else {
            AppLogger.shared.log(.error, "ItermBridge: failed to launch helper")
            return false
        }
        return helperOutput(result) != nil
    }

    // MARK: - Private

    private static let helperScriptURL: URL = {
        Bundle.main.url(forResource: "iterm_helper", withExtension: "py")
            ?? Bundle.main.resourceURL!.appendingPathComponent("iterm/iterm_helper.py")
    }()

    /// Resolves a python3 with the `iterm2` package installed via `mise which python3`,
    /// matching the lookup the Hammerspoon iTerm helper performs. Falls back to /usr/bin/python3.
    private static let pythonPath: String = {
        let miseLocations = [
            "/opt/homebrew/bin/mise",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/mise").path,
            "/usr/local/bin/mise",
        ]
        for mise in miseLocations {
            guard FileManager.default.isExecutableFile(atPath: mise) else { continue }
            guard let result = try? ProcessRunner.runSync(mise, arguments: ["which", "python3"], timeout: 5),
                  result.exitCode == 0 else { continue }
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return "/usr/bin/python3"
    }()

    private static func helperArguments(_ arguments: [String]) -> [String] {
        [helperScriptURL.path] + arguments
    }

    /// The helper's trimmed stdout, or nil when it failed or timed out.
    private static func helperOutput(_ result: ProcessResult) -> String? {
        guard result.exitCode == 0 else {
            let reason = result.timedOut ? "timed out" : "exited \(result.exitCode)"
            AppLogger.shared.log(.warning, "ItermBridge: helper \(reason): \(result.stderr)")
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
