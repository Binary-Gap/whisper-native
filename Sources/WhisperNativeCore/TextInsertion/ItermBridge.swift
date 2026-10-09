import Foundation

/// Bridges to iTerm2's Python API via the bundled `iterm_helper.py` script.
/// Requires `pip3 install iterm2` on the resolved Python interpreter and iTerm2's
/// Python API enabled (Preferences > General > Magic > Enable Python API).
public enum ItermBridge {

    public static let bundleIdentifier = "com.googlecode.iterm2"

    /// Returns the session ID of the currently focused iTerm2 session, or nil on failure.
    /// Synchronous, ~200ms (spawns a Python process).
    public static func currentSessionID() -> String? {
        runHelper(arguments: ["get-session"])
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
        return runHelper(arguments: arguments) != nil
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: mise)
            process.arguments = ["which", "python3"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty, process.terminationStatus == 0 {
                    return path
                }
            } catch {
                continue
            }
        }
        return "/usr/bin/python3"
    }()

    @discardableResult
    private static func runHelper(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [helperScriptURL.path] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLogger.shared.log(.error, "ItermBridge: failed to launch helper: \(error)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            AppLogger.shared.log(.warning, "ItermBridge: helper exited \(process.terminationStatus): \(errText)")
            return nil
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (output?.isEmpty == false) ? output : ""
    }
}
