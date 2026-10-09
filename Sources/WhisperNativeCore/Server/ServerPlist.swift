import Foundation

// Generates and writes launchd plist XML for the whisper-server LaunchAgent.
public enum ServerPlist {

    // Full whisper-server argv. Single source of truth: both the plist XML and
    // the launch log are built from this, so they never drift.
    public static func arguments(
        binaryPath: String,
        modelPath: URL,
        vadModelPath: URL?,
        tmpDir: URL
    ) -> [String] {
        var args = [
            binaryPath,
            "-m", modelPath.path,
            "--host", Constants.serverHost,
            "--port", String(Constants.serverPort),
            "-t", "12",
            "-p", "1",
            "--convert",
            "--tmp-dir", tmpDir.path,
        ]

        if let vadPath = vadModelPath {
            args += [
                "--vad",
                "-vm", vadPath.path,
                "--vad-speech-pad-ms", "500",
            ]
        }

        return args
    }

    public static func generate(
        binaryPath: String,
        modelPath: URL,
        vadModelPath: URL?,
        tmpDir: URL,
        logDir: URL
    ) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let programArguments = arguments(
            binaryPath: binaryPath,
            modelPath: modelPath,
            vadModelPath: vadModelPath,
            tmpDir: tmpDir
        )
        .map { "                <string>\($0)</string>" }
        .joined(separator: "\n")

        let stdoutLog = logDir.appendingPathComponent("whisper-server-stdout.log").path
        let stderrLog = logDir.appendingPathComponent("whisper-server-stderr.log").path

        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>\(Constants.whisperServerLaunchdLabel)</string>
    <key>ProgramArguments</key>
    <array>
\(programArguments)
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>\(home)</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>\(stdoutLog)</string>
    <key>StandardErrorPath</key>
    <string>\(stderrLog)</string>
    <key>WorkingDirectory</key>
    <string>\(home)</string>
</dict>
</plist>
"""
    }
}
